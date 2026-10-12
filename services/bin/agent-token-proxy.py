#!/usr/bin/env python3
"""Identity-attributing reverse proxy for the Bouchet vLLM server.

Sits in front of vLLM so that token usage can be attributed to a netid.
vLLM's own metrics are aggregate-only and carry no user dimension, and the
coding-agents launcher is the only component that knows who is running, so
identity is carried in the API key and recovered here.

    client -> :8008 (this proxy) -> 127.0.0.1:8010 (vLLM)

The launcher sends "<netid>.<agent>" as the API key. This proxy splits it,
substitutes the real upstream key, forwards the request untouched otherwise,
and streams the response straight back while watching it for a usage report.

Design constraints, in priority order:

1. Never break or delay inference. Response bytes are forwarded as they
   arrive, never buffered to completion. Every accounting step is wrapped so
   that a failure cannot propagate into the proxied response.
2. Accounting is pushed to the collector fire-and-forget on a short timeout.
   If the collector is down, inference is unaffected and only the usage
   record is lost.
3. Requests that carry no recognisable identity are still served normally and
   recorded as "unattributed" rather than rejected, so a future OOD-launched
   open-webui can start attributing itself by setting a token, with no change
   here.

Usage is reported differently by each wire format vLLM serves (all three are
confirmed present on this deployment):

    /v1/messages          Anthropic   streams usage unprompted; input_tokens in
                                      message_start, output_tokens in
                                      message_delta
    /v1/responses         Responses   streams usage unprompted
    /v1/chat/completions  OpenAI      streams usage ONLY when the request sets
                                      stream_options.include_usage, so this
                                      proxy injects it

Requires aiohttp (present in the serving conda env alongside vLLM).
"""

import asyncio
import collections
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

from aiohttp import ClientSession, ClientTimeout, web

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LISTEN_HOST = os.environ.get("PROXY_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("PROXY_LISTEN_PORT", "8008"))
UPSTREAM = os.environ.get("PROXY_UPSTREAM", "http://127.0.0.1:8010").rstrip("/")
UPSTREAM_KEY = os.environ.get("PROXY_UPSTREAM_KEY", "dummy-key")
COLLECTOR_URL = os.environ.get("PROXY_COLLECTOR_URL", "http://127.0.0.1:9103/ingest-tokens")
COLLECTOR_TIMEOUT = float(os.environ.get("PROXY_COLLECTOR_TIMEOUT", "2"))
CLUSTER = os.environ.get("PROXY_CLUSTER", "bouchet")

# Virtual "thinking" model. A request for "<real-model><suffix>" is served by
# the real model with extended reasoning switched on. This exists because the
# launcher cannot add headers to the harnesses' own HTTP calls, but every
# harness lets the model be chosen -- so the model name is the one channel
# that reaches here from all four. Set empty to disable the feature.
THINK_SUFFIX = os.environ.get("PROXY_THINK_SUFFIX", "-think")

# Reasoning-effort normalisation. The Qwen3.8 chat templates (27B and
# Flash-Next alike) accept only low / medium / xhigh and reject anything else
# with HTTP 400 -- 3 user-facing failures on 2026-10-09 from Claude Code, whose
# default effort is "high". Harnesses send other vocabularies (Codex: none,
# minimal, high; Claude Code: high, max), in different fields per wire format.
# Every effort a client sends is mapped onto the template's vocabulary; "off"
# means "turn reasoning off for this request". Values not in the map are
# dropped so the server default applies, never forwarded to fail.
# Designed for Flash-Next with low as the server default: "high" (Claude
# Code's default, not a user choice) maps to medium, and xhigh -- which cost
# 3-7x the tokens for no quality gain in the 2026-10 evaluation -- is reached
# only on an explicit xhigh/max request. Override with PROXY_EFFORT_MAP (JSON).
EFFORT_MAP = json.loads(os.environ.get("PROXY_EFFORT_MAP") or json.dumps({
    "none": "off", "minimal": "low", "low": "low", "medium": "medium",
    "high": "medium", "xhigh": "xhigh", "max": "xhigh"}))
# Effort for the virtual "-think" model when the request names none, so that
# "think harder" still means something once reasoning is on by default.
# Empty: leave it to the template (whose own default is xhigh).
THINK_EFFORT = os.environ.get("PROXY_THINK_EFFORT", "medium")

# Unattributed-client log. Requests that carry no usable identity (no key,
# the shared upstream key, or a malformed credential) are summarised here so
# the client can be traced: by address (-> node -> Slurm job owner) and
# User-Agent. Only metadata, never prompts or keys, and only for unattributed
# traffic -- attributed users are already accounted under their netid.
# Aggregated per (address, User-Agent, path, model, credential kind) and
# written every UNATTRIBUTED_FLUSH seconds, so a busy client produces a few
# lines rather than one per request. Set the path empty to disable.
UNATTRIBUTED_LOG = os.environ.get(
    "PROXY_UNATTRIBUTED_LOG", "/apps/services/coding-agents/state/unattributed.jsonl")
UNATTRIBUTED_FLUSH = float(os.environ.get("PROXY_UNATTRIBUTED_FLUSH", "300"))
UNATTRIBUTED_MAX_KEYS = 2000   # bound memory if something sprays many agents/addresses

# Per-user concurrency limit. With one shared engine, a single user with many
# parallel requests (subagent fan-out, batch scripts) slows everyone: in the
# 2026-10 evaluation one user holding 32 requests slowed others' sessions
# 4.1x on Flash-Next. The limit is load-aware: ENGINE_BUDGET concurrent
# requests (where Flash-Next's throughput knee was measured) are shared
# equally among the users currently active, never fewer than
# USER_MAX_INFLIGHT each. A user alone may use the whole budget (32); with
# two active users each may have 16, three 10, four or more 8. Requests over
# a user's share wait here, in order, and so only slow that user; requests
# already running are never interrupted, so when someone new arrives a heavy
# user drains down to the new share as their requests finish. A request that
# would make the user's queue longer than USER_MAX_QUEUE, or that waits
# longer than USER_QUEUE_TIMEOUT seconds, gets HTTP 429 (which the
# harnesses retry). Users are keyed by netid across all agents; unattributed
# traffic by client address. Only inference (POST /v1/) counts, and a slot
# is held until the response has finished streaming.
# USER_MAX_INFLIGHT=0 disables the limit; ENGINE_BUDGET=0 makes it a fixed
# USER_MAX_INFLIGHT per user. PROXY_USER_LIMIT_EXEMPT is a comma-separated
# list of netids that are never limited (and not counted as active).
USER_MAX_INFLIGHT = int(os.environ.get("PROXY_USER_MAX_INFLIGHT", "8"))
ENGINE_BUDGET = int(os.environ.get("PROXY_ENGINE_BUDGET", "32"))
USER_MAX_QUEUE = int(os.environ.get("PROXY_USER_MAX_QUEUE", "64"))
USER_QUEUE_TIMEOUT = float(os.environ.get("PROXY_USER_QUEUE_TIMEOUT", "300"))
USER_LIMIT_EXEMPT = frozenset(
    x.strip() for x in os.environ.get("PROXY_USER_LIMIT_EXEMPT", "").split(",") if x.strip())
USER_LIMIT_LOG_EVERY = 60   # seconds between throttling summaries in the log

# No total timeout: generations legitimately run for many minutes. Guard only
# connection establishment, so a dead upstream fails fast instead of hanging.
UPSTREAM_TIMEOUT = ClientTimeout(total=None, connect=10, sock_connect=10)

# Hop-by-hop headers must not be forwarded in either direction.
HOP_BY_HOP = frozenset((
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length",
    "content-encoding",
))

NETID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,31}$")
# The four module harnesses, plus claude-mod: the module whose in-house mode
# drives this local model from Claude Code. It sends "<netid>.<label>"; with
# label "claude-mod" its usage gets its own series instead of sharing
# "claude" with the coding-agents launcher.
VALID_AGENTS = frozenset(("claude", "codex", "copilot", "pi", "claude-mod"))

# Token fields across all three wire formats. Matching the individual fields
# rather than the enclosing object keeps this robust when a usage block is
# split across chunk boundaries or nested (the Responses API nests
# input_tokens_details inside usage). The trailing quote-colon prevents
# "input_tokens_per_turn" from matching "input_tokens".
USAGE_RE = re.compile(
    r'"(prompt_tokens|completion_tokens|input_tokens|output_tokens)"\s*:\s*(\d+)'
)
PROMPT_KEYS = ("prompt_tokens", "input_tokens")
COMPLETION_KEYS = ("completion_tokens", "output_tokens")

# Retain this much of the stream tail between chunks so a usage block spanning
# a chunk boundary is still matched.
SCAN_CARRY = 8192

_session: ClientSession = None


def log(msg):
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
def parse_identity(headers):
    """Recover (netid, agent) from the API key the launcher set.

    Accepts "<netid>.<agent>", or a bare "<netid>" when the harness is not
    encoded. Anything unrecognised -- including the shared legacy key -- is
    reported as unattributed rather than refused.
    """
    raw = ""
    auth = headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        raw = auth[7:].strip()
    if not raw:
        raw = (headers.get("x-api-key") or "").strip()
    if not raw:
        return "unattributed", "unknown"
    # The shared site credential is not a netid, but it is shaped like one and
    # would otherwise be recorded as a user called "dummy-key". Anything
    # presenting the upstream key is a client that predates user-scoped auth
    # (or bypasses the launcher), so it is unattributed by definition.
    if raw == UPSTREAM_KEY:
        return "unattributed", "unknown"

    netid, _, agent = raw.partition(".")
    if not NETID_RE.match(netid):
        return "unattributed", "unknown"
    if agent not in VALID_AGENTS:
        agent = "unknown"
    return netid, agent


def credential_kind(headers):
    """Why a request is unattributed, without ever recording the credential:
    'none' (no key at all), 'shared-key' (the upstream key, i.e. a client
    configured by hand from the published endpoint), or 'malformed'."""
    auth = headers.get("Authorization", "")
    raw = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
    raw = raw or (headers.get("x-api-key") or "").strip()
    if not raw:
        return "none"
    if raw == UPSTREAM_KEY:
        return "shared-key"
    return "malformed"


_unattributed = {}   # (addr, user_agent, path, model, kind) -> counters


def note_unattributed(addr, user_agent, path, model, kind, prompt, completion):
    """Fold one unattributed request into the current window. Never raises."""
    try:
        ua = (user_agent or "-").replace("\n", " ").replace("\r", " ")[:200]
        key = (addr or "-", ua, path, model or "unknown", kind)
        rec = _unattributed.get(key)
        if rec is None:
            if len(_unattributed) >= UNATTRIBUTED_MAX_KEYS:
                key = ("-", "(overflow)", path, model or "unknown", kind)
                rec = _unattributed.get(key)
            if rec is None:
                rec = _unattributed[key] = {"requests": 0, "prompt_tokens": 0,
                                            "completion_tokens": 0, "first": time.time()}
        rec["requests"] += 1
        rec["prompt_tokens"] += prompt
        rec["completion_tokens"] += completion
        rec["last"] = time.time()
    except Exception:
        pass


def flush_unattributed():
    """Append the window's summaries as JSON lines, then start a new window."""
    global _unattributed
    if not _unattributed or not UNATTRIBUTED_LOG:
        return
    window, _unattributed = _unattributed, {}
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        # group-readable at most: the file maps addresses to activity
        fd = os.open(UNATTRIBUTED_LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
        with os.fdopen(fd, "a") as fh:
            for (addr, ua, path, model, kind), r in sorted(window.items()):
                fh.write(json.dumps({
                    "window_end": now, "client": addr, "user_agent": ua, "path": path,
                    "model": model, "credential": kind, "requests": r["requests"],
                    "prompt_tokens": r["prompt_tokens"],
                    "completion_tokens": r["completion_tokens"],
                    "first": datetime.fromtimestamp(r["first"], timezone.utc).isoformat(timespec="seconds"),
                    "last": datetime.fromtimestamp(r["last"], timezone.utc).isoformat(timespec="seconds"),
                }, separators=(",", ":")) + "\n")
    except Exception as exc:
        log(f"WARNING: could not write unattributed log ({exc})")


async def unattributed_flusher():
    while True:
        await asyncio.sleep(UNATTRIBUTED_FLUSH)
        flush_unattributed()


# ---------------------------------------------------------------------------
# Usage extraction
# ---------------------------------------------------------------------------
def scan_usage(text, found):
    """Fold any token counts in `text` into `found`.

    Takes the maximum per field: Anthropic reports output_tokens twice (0 in
    message_start, the real count in message_delta), and streaming formats
    report cumulative values, so max is correct for all three.
    """
    for key, val in USAGE_RE.findall(text):
        try:
            n = int(val)
        except ValueError:
            continue
        if n > found.get(key, -1):
            found[key] = n


def totals(found):
    prompt = max((found.get(k, 0) for k in PROMPT_KEYS), default=0)
    completion = max((found.get(k, 0) for k in COMPLETION_KEYS), default=0)
    return prompt, completion


# ---------------------------------------------------------------------------
# Request rewriting
# ---------------------------------------------------------------------------
def normalise_effort(payload):
    """Map every reasoning-effort field in `payload` onto the template's
    vocabulary (see EFFORT_MAP). Returns (changed, effort_seen)."""
    changed = False
    seen = False

    def mapped(value):
        if not isinstance(value, str):
            return None
        return EFFORT_MAP.get(value.strip().lower())

    def turn_off():
        kw = payload.get("chat_template_kwargs")
        if not isinstance(kw, dict):
            kw = {}
        kw["enable_thinking"] = False
        kw.pop("reasoning_effort", None)
        payload["chat_template_kwargs"] = kw

    # Chat Completions: top-level reasoning_effort, and chat_template_kwargs.
    for holder, key in ((payload, "reasoning_effort"),
                        (payload.get("chat_template_kwargs"), "reasoning_effort")):
        if isinstance(holder, dict) and key in holder:
            seen = True
            m = mapped(holder[key])
            if m == "off":
                holder.pop(key, None); turn_off()
            elif m is None:
                holder.pop(key, None)
            elif m != holder[key]:
                holder[key] = m
            else:
                continue
            changed = True
    # Responses API: reasoning.effort.
    rs = payload.get("reasoning")
    if isinstance(rs, dict) and "effort" in rs:
        seen = True
        m = mapped(rs["effort"])
        if m == "off":
            rs.pop("effort", None); turn_off(); changed = True
        elif m is None:
            rs.pop("effort", None); changed = True
        elif m != rs["effort"]:
            rs["effort"] = m; changed = True
    # Anthropic Messages: output_config.effort (Claude Code).
    oc = payload.get("output_config")
    if isinstance(oc, dict) and "effort" in oc:
        seen = True
        m = mapped(oc["effort"])
        if m == "off":
            oc.pop("effort", None); payload["thinking"] = {"type": "disabled"}; changed = True
        elif m is None:
            oc.pop("effort", None); changed = True
        elif m != oc["effort"]:
            oc["effort"] = m; changed = True
    return changed, seen


def rewrite_request(path, body):
    """Apply request rewrites; return (body, model-to-account-under).

    Two rewrites happen here:

    1. Thinking variant. A model named "<real><THINK_SUFFIX>" is virtual: the
       suffix is stripped and chat_template_kwargs.enable_thinking is set. vLLM
       accepts chat_template_kwargs on /v1/chat/completions, /v1/messages and
       /v1/responses alike, so one rewrite covers every harness. An explicit
       enable_thinking from the caller is left alone.
    2. Usage reporting. Streaming /v1/chat/completions omits usage unless the
       request opts in, so opt in on the caller's behalf. This only appends a
       final usage-bearing chunk; it does not alter the generation.

    Accounting reports the *virtual* name, so reasoning traffic forms its own
    series and the extra token cost of thinking is visible rather than merged
    into normal usage.

    Anything unparseable is passed through untouched -- this sits in the
    inference path and must never reject a request it merely failed to read.
    """
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return body, None
    if not isinstance(payload, dict):
        return body, None

    model = payload.get("model")
    account_as = model if isinstance(model, str) else None
    changed = False

    if (THINK_SUFFIX and isinstance(model, str)
            and model.endswith(THINK_SUFFIX)
            and len(model) > len(THINK_SUFFIX)):
        payload["model"] = model[: -len(THINK_SUFFIX)]
        kw = payload.get("chat_template_kwargs")
        if not isinstance(kw, dict):
            kw = {}
        kw.setdefault("enable_thinking", True)
        payload["chat_template_kwargs"] = kw
        changed = True
        think_requested = True
    else:
        think_requested = False

    eff_changed, effort_seen = normalise_effort(payload)
    changed = changed or eff_changed
    if think_requested and THINK_EFFORT and not effort_seen:
        payload["chat_template_kwargs"]["reasoning_effort"] = THINK_EFFORT
        changed = True

    # Codex multi-agent emits "agent_message" items into the Responses API
    # `input` array. That type is codex-internal and is not part of the
    # Responses schema, so vLLM rejects the whole request with a validation
    # error against every union variant (seen as "158 validation errors").
    # Rewrite them into ordinary user messages, which carry the same text and
    # which vLLM accepts, so delegated Codex agents can reach the model at all.
    if path.endswith("/responses") and isinstance(payload.get("input"), list):
        converted = 0
        items = []
        for item in payload["input"]:
            if isinstance(item, dict) and item.get("type") == "agent_message":
                content = item.get("content")
                items.append({
                    "type": "message",
                    "role": "user",
                    "content": content if isinstance(content, list) else [
                        {"type": "input_text", "text": str(content or "")}
                    ],
                })
                converted += 1
            else:
                items.append(item)
        if converted:
            payload["input"] = items
            changed = True

    if path.endswith("/chat/completions") and payload.get("stream"):
        opts = payload.get("stream_options")
        if not isinstance(opts, dict):
            opts = {}
        if opts.get("include_usage") is not True:
            opts["include_usage"] = True
            payload["stream_options"] = opts
            changed = True

    if not changed:
        return body, account_as
    try:
        return json.dumps(payload).encode(), account_as
    except (TypeError, ValueError):
        return body, account_as


def add_think_variants(raw):
    """Advertise the virtual thinking model in /v1/models.

    Some harnesses validate their configured model against this list before
    using it, so the virtual name has to appear here or selecting it fails.
    """
    if not THINK_SUFFIX:
        return raw
    try:
        doc = json.loads(raw)
        data = doc.get("data")
        if not isinstance(data, list):
            return raw
        extra = []
        for m in data:
            mid = m.get("id") if isinstance(m, dict) else None
            if isinstance(mid, str) and not mid.endswith(THINK_SUFFIX):
                variant = dict(m)
                variant["id"] = mid + THINK_SUFFIX
                extra.append(variant)
        if not extra:
            return raw
        doc["data"] = data + extra
        return json.dumps(doc).encode()
    except Exception:
        return raw


# ---------------------------------------------------------------------------
# Accounting
# ---------------------------------------------------------------------------
async def push_usage(record):
    """Report one request's usage. Fire-and-forget: failure is not the
    caller's problem and must never surface in the proxied response."""
    try:
        async with _session.post(
            COLLECTOR_URL, json=record,
            timeout=ClientTimeout(total=COLLECTOR_TIMEOUT),
        ) as resp:
            await resp.read()
    except Exception:
        pass


def record_later(netid, agent, model, prompt, completion, status, streamed,
                 ttft=None, duration=None):
    if prompt <= 0 and completion <= 0:
        return  # nothing worth reporting (e.g. an error or a non-generating call)
    rec = {
        "netid": netid,
        "agent": agent,
        "model": model or "unknown",
        "cluster": CLUSTER,
        "prompt_tokens": prompt,
        "completion_tokens": completion,
        "status": status,
        "streamed": streamed,
        "ts": time.time(),
    }
    # Latency is measured at the gateway, so it is what the client actually
    # experienced: queueing, prefill and decode all included. Omitted rather
    # than sent as zero when a request produced no first byte.
    if ttft is not None:
        rec["ttft_s"] = round(ttft, 4)
    if duration is not None:
        rec["duration_s"] = round(duration, 4)
    asyncio.create_task(push_usage(rec))


# ---------------------------------------------------------------------------
# Proxy
# ---------------------------------------------------------------------------
def forward_headers(src, netid, agent):
    out = {k: v for k, v in src.items() if k.lower() not in HOP_BY_HOP}
    # Substitute the real upstream credential for the identity-bearing one.
    out.pop("Authorization", None)
    out.pop("authorization", None)
    out.pop("x-api-key", None)
    out.pop("X-Api-Key", None)
    out["Authorization"] = f"Bearer {UPSTREAM_KEY}"
    if netid != "unattributed":
        # Visible to upstream logging; harmless if ignored.
        out["X-Forwarded-User"] = netid
        out["X-Forwarded-Agent"] = agent
    return out


# ---------------------------------------------------------------------------
# Per-user concurrency limit
# ---------------------------------------------------------------------------
class UserBusy(Exception):
    """The user's queue is full or the wait timed out."""


class UserSlots:
    """Per-key concurrency limit whose cap shrinks as more keys are active.

    A key is active while it has requests in flight or waiting; entries
    exist only then, so memory is bounded by live traffic, not by the number
    of users seen. Each key's waiters are served FIFO.
    """

    def __init__(self, floor, budget, max_queue, timeout):
        self.floor, self.budget = floor, budget
        self.max_queue, self.timeout = max_queue, timeout
        self._keys = {}    # key -> {"held": int, "queue": deque of futures}
        # Throttling since the last summary: key -> [queued, rejected, max wait]
        self.stats = {}

    def cap(self):
        if self.budget <= 0:
            return self.floor
        return max(self.floor, self.budget // max(len(self._keys), 1))

    def _stat(self, key):
        return self.stats.setdefault(key, [0, 0, 0.0])

    async def acquire(self, key):
        ent = self._keys.get(key)
        if ent is None:
            ent = self._keys[key] = {"held": 0, "queue": collections.deque()}
        if not ent["queue"] and ent["held"] < self.cap():
            ent["held"] += 1
            return
        if len(ent["queue"]) >= self.max_queue:
            self._stat(key)[1] += 1
            self._drop_if_idle(key, ent)
            raise UserBusy(f"{ent['held']} running and {len(ent['queue'])} "
                           "waiting")
        fut = asyncio.get_running_loop().create_future()
        ent["queue"].append(fut)
        st = self._stat(key)
        st[0] += 1
        t0 = time.monotonic()
        try:
            async with asyncio.timeout(self.timeout):
                await fut
        except BaseException as exc:
            if fut.done() and not fut.cancelled():
                # Granted at the same moment as the timeout or hang-up:
                # hand the slot straight back.
                self.release(key)
            else:
                fut.cancel()
                try:
                    ent["queue"].remove(fut)
                except ValueError:
                    pass
                self._drop_if_idle(key, ent)
            if isinstance(exc, TimeoutError):
                st[1] += 1
                raise UserBusy(f"waited {self.timeout:g}s for a request slot")
            raise
        finally:
            st[2] = max(st[2], time.monotonic() - t0)

    def release(self, key):
        ent = self._keys.get(key)
        if ent is None:
            return
        ent["held"] -= 1
        self._drop_if_idle(key, ent)
        self._dispatch()

    def _drop_if_idle(self, key, ent):
        if ent["held"] <= 0 and not ent["queue"] and self._keys.get(key) is ent:
            del self._keys[key]
            self._dispatch()    # one fewer active user: the others' share grows

    def _dispatch(self):
        cap = self.cap()
        for ent in list(self._keys.values()):
            q = ent["queue"]
            while q and ent["held"] < cap:
                fut = q.popleft()
                if fut.done():      # cancelled while queued
                    continue
                ent["held"] += 1
                fut.set_result(None)

    def snapshot(self, key):
        ent = self._keys.get(key)
        return (ent["held"], len(ent["queue"])) if ent else (0, 0)


_user_slots = UserSlots(max(USER_MAX_INFLIGHT, 1), ENGINE_BUDGET,
                        USER_MAX_QUEUE, USER_QUEUE_TIMEOUT)


def limit_key(netid, remote):
    """Key the per-user limit applies to, or None if exempt/disabled."""
    if USER_MAX_INFLIGHT <= 0 or netid in USER_LIMIT_EXEMPT:
        return None
    if netid == "unattributed":
        return f"unattributed@{remote}"
    return netid


def busy_response(path, reason):
    msg = (f"Too many concurrent requests for this user ({reason}). This "
           f"shared model currently allows {_user_slots.cap()} at a time per "
           "user; please retry shortly.")
    if path.startswith("/v1/messages"):
        payload = {"type": "error",
                   "error": {"type": "rate_limit_error", "message": msg}}
    else:
        payload = {"error": {"message": msg, "type": "rate_limit_error",
                             "code": "rate_limit_exceeded"}}
    return web.json_response(payload, status=429, headers={"Retry-After": "30"})


async def user_limit_logger():
    while True:
        await asyncio.sleep(USER_LIMIT_LOG_EVERY)
        try:
            stats, _user_slots.stats = _user_slots.stats, {}
            for key, (queued, rejected, wait) in sorted(stats.items()):
                held, waiting = _user_slots.snapshot(key)
                log(f"user limit: {key} queued={queued} rejected={rejected} "
                    f"max_wait={wait:.1f}s now in_flight={held} waiting={waiting} "
                    f"cap={_user_slots.cap()} active_users={len(_user_slots._keys)}")
        except Exception as exc:
            log(f"user limit logger error: {exc!r}")


async def handle(request: web.Request):
    key = None
    if request.method == "POST" and request.rel_url.path.startswith("/v1/"):
        try:
            netid, _ = parse_identity(request.headers)
            key = limit_key(netid, request.remote)
        except Exception:
            key = None     # limiting must never break inference
    if key is None:
        return await proxy(request)
    try:
        await _user_slots.acquire(key)
    except UserBusy as exc:
        return busy_response(request.rel_url.path, str(exc))
    try:
        return await proxy(request)
    finally:
        _user_slots.release(key)


async def proxy(request: web.Request):
    path = request.rel_url.path
    url = f"{UPSTREAM}{request.rel_url}"
    netid, agent = parse_identity(request.headers)
    unattrib = None
    if netid == "unattributed":
        unattrib = (request.remote, request.headers.get("User-Agent"),
                    credential_kind(request.headers))
    # Monotonic: wall-clock jumps must not corrupt a latency sample.
    t0 = time.monotonic()
    ttft = None

    body = b""
    model = None
    accountable = request.method == "POST" and path.startswith("/v1/")
    if accountable:
        body = await request.read()
        body, model = rewrite_request(path, body)
    elif request.method not in ("GET", "HEAD", "OPTIONS"):
        body = await request.read()

    hdrs = forward_headers(request.headers, netid, agent)

    try:
        upstream = await _session.request(
            request.method, url, data=body if body else None,
            headers=hdrs, timeout=UPSTREAM_TIMEOUT, allow_redirects=False,
        )
    except Exception as exc:
        log(f"upstream error for {request.method} {path}: {exc!r}")
        return web.json_response(
            {"error": {"message": "upstream unavailable", "type": "proxy_error"}},
            status=502,
        )

    # /v1/models is small and must be rewritten as a whole to advertise the
    # virtual thinking model, so it is buffered rather than streamed.
    if (request.method == "GET" and path.rstrip("/").endswith("/v1/models")
            and upstream.status == 200):
        try:
            raw = await upstream.read()
        finally:
            upstream.release()
        return web.Response(status=200, body=add_think_variants(raw),
                            content_type="application/json")

    resp_hdrs = {k: v for k, v in upstream.headers.items()
                 if k.lower() not in HOP_BY_HOP}
    out = web.StreamResponse(status=upstream.status, headers=resp_hdrs)
    # Disable aiohttp's own buffering so SSE reaches the client token by token.
    out.enable_chunked_encoding()
    await out.prepare(request)

    found = {}
    carry = ""
    streamed = False
    try:
        async for chunk in upstream.content.iter_any():
            # Forward first: accounting must never delay a token.
            await out.write(chunk)
            if ttft is None:
                ttft = time.monotonic() - t0
            if not accountable:
                continue
            streamed = True
            try:
                text = carry + chunk.decode("utf-8", errors="ignore")
                scan_usage(text, found)
                carry = text[-SCAN_CARRY:]
            except Exception:
                carry = ""
    except (asyncio.CancelledError, ConnectionResetError):
        # Client hung up mid-generation. Record what we saw and re-raise so
        # aiohttp can clean up the connection properly.
        if accountable:
            p, c = totals(found)
            # Client aborted: the elapsed time is not a completed response, so
            # report TTFT (which did happen) but no duration.
            record_later(netid, agent, model, p, c, upstream.status, streamed,
                         ttft=ttft)
            if unattrib:
                note_unattributed(unattrib[0], unattrib[1], path, model, unattrib[2], p, c)
        raise
    except Exception as exc:
        log(f"stream error for {netid}/{agent} {path}: {exc!r}")
    finally:
        upstream.release()

    try:
        await out.write_eof()
    except Exception:
        pass

    if accountable:
        p, c = totals(found)
        record_later(netid, agent, model, p, c, upstream.status, streamed,
                     ttft=ttft, duration=time.monotonic() - t0)
        if unattrib:
            note_unattributed(unattrib[0], unattrib[1], path, model, unattrib[2], p, c)
    return out


async def on_startup(app):
    global _session
    _session = ClientSession(auto_decompress=False)
    log(f"proxying {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}")
    log(f"usage records -> {COLLECTOR_URL}")
    if UNATTRIBUTED_LOG:
        app["unattributed_flusher"] = asyncio.create_task(unattributed_flusher())
        log(f"unattributed-client summaries -> {UNATTRIBUTED_LOG} every {UNATTRIBUTED_FLUSH:.0f}s")
    if USER_MAX_INFLIGHT > 0:
        app["user_limit_logger"] = asyncio.create_task(user_limit_logger())
        share = (f"budget {ENGINE_BUDGET} shared by active users, at least "
                 f"{USER_MAX_INFLIGHT} each" if ENGINE_BUDGET > 0
                 else f"fixed {USER_MAX_INFLIGHT} each")
        log(f"per-user limit: {share}, queue {USER_MAX_QUEUE}, "
            f"wait {USER_QUEUE_TIMEOUT:g}s, exempt {sorted(USER_LIMIT_EXEMPT) or 'none'}")
    else:
        log("per-user limit: disabled")


async def on_cleanup(app):
    flush_unattributed()
    if _session:
        await _session.close()


def main():
    app = web.Application(client_max_size=1024 ** 3)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app.router.add_route("*", "/{tail:.*}", handle)
    web.run_app(app, host=LISTEN_HOST, port=LISTEN_PORT, access_log=None,
                print=None)


if __name__ == "__main__":
    main()
