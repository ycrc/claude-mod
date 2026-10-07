#!/usr/bin/env python3
"""Per-netid usage collector for the local-coding-agents module.

Runs on the vLLM server node, alongside the inference service. The
coding-agents wrapper POSTs one small JSON record per agent session; this
service folds those into monotonic Prometheus counters and exposes them for
YCRC's Prometheus to scrape.

    POST /ingest    <- coding-agents wrapper, one session record
    GET  /metrics   -> Prometheus exposition (the scrape target)
    GET  /health    -> liveness probe

Why this exists: vLLM's own /metrics has no per-user dimension and never
will, so identity has to be injected by the wrapper, which is the only
component that knows the netid. This service is where that identity lands.

Counter state is persisted to disk and reloaded on startup, so counters stay
monotonic across restarts and across reschedules of the serving job.

stdlib only -- no third-party dependencies, so it runs under any python3.
"""

import json
import os
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration (environment-overridable)
# ---------------------------------------------------------------------------
# Default layout: this script lives in <service>/bin, state beside it in
# <service>/state, which is group-restricted because it holds per-netid data.
BASE = Path(os.environ.get("COLLECTOR_BASE", Path(__file__).resolve().parent.parent / "state"))
STATE_PATH = Path(os.environ.get("COLLECTOR_STATE", BASE / "state.json"))
AUDIT_PATH = Path(os.environ.get("COLLECTOR_AUDIT", BASE / "sessions.jsonl"))
PORT = int(os.environ.get("COLLECTOR_PORT", "9103"))
BIND = os.environ.get("COLLECTOR_BIND", "0.0.0.0")
CLUSTER = os.environ.get("COLLECTOR_CLUSTER", "bouchet")

# Shared secret. If set, /ingest requires a matching X-Usage-Token header.
# This deters casual misuse only; it is not an authentication boundary, and
# the records it guards remain self-reported.
TOKEN = os.environ.get("COLLECTOR_TOKEN", "")

# Optionally append vLLM's own aggregate metrics to our /metrics output, so
# Prometheus needs exactly one scrape target for this node. Set to 0 to keep
# the two independent (then scrape vLLM's :8008/metrics separately), which
# avoids this process becoming a single point of failure for both.
FEDERATE = os.environ.get("COLLECTOR_FEDERATE_VLLM", "1") not in ("0", "false", "no")
VLLM_METRICS_URL = os.environ.get("COLLECTOR_VLLM_METRICS", "http://127.0.0.1:8008/metrics")
VLLM_TIMEOUT = float(os.environ.get("COLLECTOR_VLLM_TIMEOUT", "3"))

STATE_FLUSH_INTERVAL = int(os.environ.get("COLLECTOR_FLUSH_INTERVAL", "30"))
MAX_BODY = 8192                 # a session record is ~300 bytes
MAX_SERIES = 20000              # cardinality guard: netid x agent pairs
VALID_AGENTS = frozenset(("claude", "codex", "copilot", "pi"))
NETID_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$", re.IGNORECASE)
MAX_DURATION = 60 * 60 * 24 * 31   # clamp clock skew / bad records

_lock = threading.Lock()
_dirty = False
_state = {
    "series": {},        # "netid\x1fagent" -> {sessions, seconds, failed, last}
    "tokens": {},        # "netid\x1fagent\x1fmodel" -> {prompt, completion, requests}
    "latency": {},       # "netid\x1fagent" -> {ttft:{b,sum,count}, dur:{b,sum,count}}
    "ingested": 0,
    "rejected": 0,
    "token_ingested": 0,
    "token_rejected": 0,
    "started": time.time(),
}

# A single request cannot legitimately exceed the served context window by
# much; anything larger is a malformed or hostile report and is dropped.
MAX_TOKENS_PER_REQUEST = 1_000_000
MODEL_RE = re.compile(r"^[A-Za-z0-9._/-]{1,64}$")

# Latency histograms, measured at the gateway so they reflect what the client
# experienced. Histograms rather than plain averages: for "is this netid seeing
# slow responses", the tail is the answer and a mean hides it.
#
# Buckets are chosen for this workload, where agent prompts run to ~200k tokens
# and prefill dominates: first-token times cluster around 5s rather than the
# sub-second typical of chat. Latency is labelled by netid and agent only --
# adding model would multiply series by bucket count for no insight, since one
# model is served.
TTFT_BUCKETS = (0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 20.0, 45.0, 90.0)
DURATION_BUCKETS = (1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0)
MAX_LATENCY = 86400  # a sample beyond a day is a clock artefact, not a request


def log(msg):
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------
def load_state():
    global _state
    try:
        with STATE_PATH.open() as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict) and isinstance(loaded.get("series"), dict):
            loaded["started"] = time.time()
            # Backfill keys added after this state file was first written, so
            # an older state survives an upgrade without losing its counters.
            for key, default in (("tokens", {}), ("latency", {}),
                                 ("token_ingested", 0),
                                 ("token_rejected", 0), ("rejected", 0)):
                loaded.setdefault(key, default)
            _state = loaded
            log(f"loaded state: {len(_state['series'])} series, "
                f"{_state.get('ingested', 0)} records ingested")
            return
    except FileNotFoundError:
        pass
    except Exception as exc:
        log(f"WARNING: could not load state ({exc}); starting fresh")
    log("starting with empty state")


def save_state():
    """Atomically persist counters so they survive a restart."""
    global _dirty
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    try:
        with tmp.open("w") as fh:
            json.dump(_state, fh)
        tmp.replace(STATE_PATH)
        _dirty = False
    except Exception as exc:
        log(f"WARNING: could not save state ({exc})")


# ---------------------------------------------------------------------------
# Ingestion
# ---------------------------------------------------------------------------
def fold(rec):
    """Validate one session record and fold it into the counters.

    Returns (ok, reason). Records arrive from user-run processes, so every
    field is treated as untrusted: the netid is charset-checked (it reaches a
    Prometheus label, where a stray quote would corrupt the exposition), the
    agent name is whitelisted, and the duration is clamped.
    """
    global _dirty
    if not isinstance(rec, dict):
        return False, "not an object"

    netid = str(rec.get("netid", "")).strip()
    agent = str(rec.get("agent", "")).strip()
    if not NETID_RE.match(netid):
        return False, "bad netid"
    if agent not in VALID_AGENTS:
        return False, "bad agent"

    key = f"{netid}\x1f{agent}"
    if key not in _state["series"] and len(_state["series"]) >= MAX_SERIES:
        return False, "series cap reached"

    s = _state["series"].setdefault(
        key, {"sessions": 0, "seconds": 0.0, "failed": 0, "last": 0.0}
    )
    s["sessions"] += 1

    try:
        dur = float(rec.get("duration_s", 0))
        if 0 <= dur <= MAX_DURATION:
            s["seconds"] += dur
    except (TypeError, ValueError):
        pass

    try:
        if int(rec.get("exit", 0)) != 0:
            s["failed"] += 1
    except (TypeError, ValueError):
        pass

    try:
        s["last"] = max(s["last"], float(rec.get("end_epoch", 0)))
    except (TypeError, ValueError):
        pass

    _state["ingested"] += 1
    _dirty = True
    return True, "ok"


def fold_tokens(rec):
    """Validate and fold one per-request token report from the proxy.

    Reports describe traffic the proxy observed, so the netid may legitimately
    be the sentinel "unattributed" (a client that presented no identity) and
    the agent may be "unknown" (identity present but harness not encoded).
    Both are recorded rather than discarded, so the totals stay honest about
    what could not be attributed.
    """
    global _dirty
    if not isinstance(rec, dict):
        return False, "not an object"

    netid = str(rec.get("netid", "")).strip()
    agent = str(rec.get("agent", "")).strip()
    model = str(rec.get("model", "unknown")).strip() or "unknown"

    if netid != "unattributed" and not NETID_RE.match(netid):
        return False, "bad netid"
    if agent != "unknown" and agent not in VALID_AGENTS:
        return False, "bad agent"
    if not MODEL_RE.match(model):
        return False, "bad model"

    try:
        prompt = int(rec.get("prompt_tokens", 0))
        completion = int(rec.get("completion_tokens", 0))
    except (TypeError, ValueError):
        return False, "bad token counts"
    if prompt < 0 or completion < 0:
        return False, "negative tokens"
    if prompt > MAX_TOKENS_PER_REQUEST or completion > MAX_TOKENS_PER_REQUEST:
        return False, "implausible token count"
    if prompt == 0 and completion == 0:
        return False, "empty report"

    key = f"{netid}\x1f{agent}\x1f{model}"
    if key not in _state["tokens"] and len(_state["tokens"]) >= MAX_SERIES:
        return False, "series cap reached"

    t = _state["tokens"].setdefault(key, {"prompt": 0, "completion": 0, "requests": 0})
    t["prompt"] += prompt
    t["completion"] += completion
    t["requests"] += 1

    # Latency is optional: a request that never produced a first byte reports
    # no ttft, and an aborted one reports no duration. Record whatever is
    # present rather than discarding the whole report.
    lat = None
    for field, slot, buckets in (("ttft_s", "ttft", TTFT_BUCKETS),
                                 ("duration_s", "dur", DURATION_BUCKETS)):
        if field not in rec:
            continue
        try:
            v = float(rec[field])
        except (TypeError, ValueError):
            continue
        if not (0 <= v <= MAX_LATENCY):
            continue
        if lat is None:
            lkey = f"{netid}\x1f{agent}"
            lat = _state["latency"].setdefault(lkey, {})
        h = lat.setdefault(slot, {"b": [0] * len(buckets), "sum": 0.0, "count": 0})
        # Prometheus histogram buckets are cumulative, so increment every
        # bucket whose upper bound this sample falls within.
        for i, edge in enumerate(buckets):
            if v <= edge:
                h["b"][i] += 1
        h["sum"] += v
        h["count"] += 1

    _state["token_ingested"] += 1
    _dirty = True
    return True, "ok"


def audit(rec, source):
    """Append the raw record to a JSONL trail, independent of the counters."""
    try:
        AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
        rec = dict(rec)
        rec["_received"] = time.time()
        rec["_source"] = source
        with AUDIT_PATH.open("a") as fh:
            fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except Exception as exc:
        log(f"WARNING: audit append failed ({exc})")


# ---------------------------------------------------------------------------
# Exposition
# ---------------------------------------------------------------------------
def fetch_vllm():
    """Pull vLLM's own aggregate metrics so one scrape covers the node."""
    try:
        with urllib.request.urlopen(VLLM_METRICS_URL, timeout=VLLM_TIMEOUT) as resp:
            return resp.read().decode("utf-8", errors="replace"), True
    except (urllib.error.URLError, OSError, ValueError):
        return "", False


def render():
    out = []
    a = out.append
    series = sorted(_state["series"].items())

    def emit(name, help_text, mtype, value_of, fmt="{}"):
        a(f"# HELP {name} {help_text}")
        a(f"# TYPE {name} {mtype}")
        for key, s in series:
            netid, agent = key.split("\x1f", 1)
            val = fmt.format(value_of(s))
            a(f'{name}{{cluster="{CLUSTER}",netid="{netid}",agent="{agent}"}} {val}')

    emit("coding_agents_sessions_total",
         "Coding-agent sessions recorded, by netid and harness.",
         "counter", lambda s: s["sessions"])
    emit("coding_agents_session_seconds_total",
         "Wall-clock seconds spent inside coding-agent sessions.",
         "counter", lambda s: s["seconds"], "{:.1f}")
    emit("coding_agents_sessions_failed_total",
         "Coding-agent sessions that exited non-zero.",
         "counter", lambda s: s["failed"])
    emit("coding_agents_last_session_timestamp_seconds",
         "Unix time at which this netid's most recent session ended.",
         "gauge", lambda s: s["last"], "{:.0f}")

    # Per-netid token usage, reported by the proxy in front of vLLM. Absent
    # when the proxy is not deployed; vLLM's own metrics cannot be attributed.
    tok = sorted(_state.get("tokens", {}).items())

    def emit_tokens(name, help_text, field):
        a(f"# HELP {name} {help_text}")
        a(f"# TYPE {name} counter")
        for key, t in tok:
            netid, agent, model = key.split("\x1f", 2)
            a(f'{name}{{cluster="{CLUSTER}",netid="{netid}",agent="{agent}",'
              f'model="{model}"}} {t[field]}')

    emit_tokens("coding_agents_prompt_tokens_total",
                "Prompt (input) tokens attributed to a netid.", "prompt")
    emit_tokens("coding_agents_completion_tokens_total",
                "Completion (output) tokens attributed to a netid.", "completion")
    emit_tokens("coding_agents_model_requests_total",
                "Inference requests attributed to a netid.", "requests")

    # Latency histograms, measured at the gateway (queueing, prefill and decode
    # all included), so percentiles reflect what the netid actually waited.
    lat = sorted(_state.get("latency", {}).items())

    def emit_hist(name, help_text, slot, buckets):
        rows = [(k, v[slot]) for k, v in lat if slot in v]
        if not rows:
            return
        a(f"# HELP {name}_seconds {help_text}")
        a(f"# TYPE {name}_seconds histogram")
        for key, h in rows:
            netid, agent = key.split("\x1f", 1)
            lbl = f'cluster="{CLUSTER}",netid="{netid}",agent="{agent}"'
            for i, edge in enumerate(buckets):
                a(f'{name}_seconds_bucket{{{lbl},le="{edge}"}} {h["b"][i]}')
            a(f'{name}_seconds_bucket{{{lbl},le="+Inf"}} {h["count"]}')
            a(f'{name}_seconds_sum{{{lbl}}} {h["sum"]:.4f}')
            a(f'{name}_seconds_count{{{lbl}}} {h["count"]}')

    emit_hist("coding_agents_ttft",
              "Time to first byte of the response, per netid, as seen at the gateway.",
              "ttft", TTFT_BUCKETS)
    emit_hist("coding_agents_request_duration",
              "Full request duration, per netid, as seen at the gateway.",
              "dur", DURATION_BUCKETS)

    # Union of the session and token series. Session records are only written
    # when a session exits, so a netid currently mid-session has token usage
    # but no session series yet; counting only sessions undercounts live users.
    netids = {k.split("\x1f", 1)[0] for k in _state["series"]}
    netids |= {k.split("\x1f", 1)[0] for k in _state.get("tokens", {})}
    netids.discard("unattributed")
    a("# HELP coding_agents_distinct_netids Distinct netids seen since accounting began.")
    a("# TYPE coding_agents_distinct_netids gauge")
    a(f'coding_agents_distinct_netids{{cluster="{CLUSTER}"}} {len(netids)}')

    a("# HELP coding_agents_records_ingested_total Session records accepted.")
    a("# TYPE coding_agents_records_ingested_total counter")
    a(f'coding_agents_records_ingested_total{{cluster="{CLUSTER}"}} {_state["ingested"]}')

    a("# HELP coding_agents_records_rejected_total Session records rejected as invalid.")
    a("# TYPE coding_agents_records_rejected_total counter")
    a(f'coding_agents_records_rejected_total{{cluster="{CLUSTER}"}} {_state["rejected"]}')

    a("# HELP coding_agents_token_reports_total Per-request token reports accepted from the proxy.")
    a("# TYPE coding_agents_token_reports_total counter")
    a(f'coding_agents_token_reports_total{{cluster="{CLUSTER}"}} {_state.get("token_ingested", 0)}')

    a("# HELP coding_agents_token_reports_rejected_total Token reports rejected as invalid.")
    a("# TYPE coding_agents_token_reports_rejected_total counter")
    a(f'coding_agents_token_reports_rejected_total{{cluster="{CLUSTER}"}} {_state.get("token_rejected", 0)}')

    a("# HELP coding_agents_collector_uptime_seconds Collector uptime.")
    a("# TYPE coding_agents_collector_uptime_seconds gauge")
    a(f'coding_agents_collector_uptime_seconds{{cluster="{CLUSTER}"}} '
      f'{time.time() - _state["started"]:.0f}')

    body = "\n".join(out) + "\n"

    if FEDERATE:
        vllm_text, ok = fetch_vllm()
        body += ("# HELP coding_agents_vllm_scrape_up vLLM metrics reachable from the collector.\n"
                 "# TYPE coding_agents_vllm_scrape_up gauge\n"
                 f'coding_agents_vllm_scrape_up{{cluster="{CLUSTER}"}} {1 if ok else 0}\n')
        if ok:
            body += vllm_text if vllm_text.endswith("\n") else vllm_text + "\n"
    return body


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "coding-agents-collector/1.0"

    def _reply(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/metrics":
            with _lock:
                body = render().encode()
            self._reply(200, body)
        elif path in ("/health", "/"):
            with _lock:
                n = len(_state["series"])
                ing = _state["ingested"]
            self._reply(200, json.dumps(
                {"status": "ok", "series": n, "ingested": ing}).encode(),
                "application/json")
        else:
            self._reply(404, b"not found\n")

    def do_POST(self):
        route = self.path.split("?", 1)[0]
        if route not in ("/ingest", "/ingest-tokens"):
            self._reply(404, b"not found\n")
            return

        if TOKEN and self.headers.get("X-Usage-Token", "") != TOKEN:
            self._reply(403, b"forbidden\n")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._reply(400, b"bad length\n")
            return
        if length <= 0 or length > MAX_BODY:
            self._reply(413, b"bad body size\n")
            return

        try:
            raw = self.rfile.read(length)
            rec = json.loads(raw.decode("utf-8", errors="replace"))
        except Exception:
            with _lock:
                _state["rejected" if route == "/ingest" else "token_rejected"] += 1
            self._reply(400, b"bad json\n")
            return

        if route == "/ingest-tokens":
            with _lock:
                ok, reason = fold_tokens(rec)
                if not ok:
                    _state["token_rejected"] += 1
            # Token reports are high-volume and carry no per-session detail
            # worth keeping raw, so they are counted but not written to the
            # session audit trail.
            self._reply(204 if ok else 400,
                        b"" if ok else f"rejected: {reason}\n".encode())
            return

        with _lock:
            ok, reason = fold(rec)
            if not ok:
                _state["rejected"] += 1
        if ok:
            audit(rec, self.client_address[0])
            self._reply(204)
        else:
            self._reply(400, f"rejected: {reason}\n".encode())

    def log_message(self, *args):
        pass  # Prometheus scrapes constantly; keep the service log readable


def flusher():
    while True:
        time.sleep(STATE_FLUSH_INTERVAL)
        with _lock:
            if _dirty:
                save_state()


def main():
    # State and audit files carry per-netid data: keep them group-readable at
    # most, rather than relying only on the enclosing directory's permissions.
    os.umask(0o027)
    BASE.mkdir(parents=True, exist_ok=True)
    load_state()

    def shutdown(signum, _frame):
        with _lock:
            save_state()
        log(f"signal {signum}: state saved, exiting")
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    threading.Thread(target=flusher, daemon=True).start()
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    log(f"listening on {BIND}:{PORT} "
        f"(federate_vllm={'on' if FEDERATE else 'off'}, "
        f"token={'set' if TOKEN else 'unset'}, state={STATE_PATH})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
