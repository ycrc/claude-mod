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
VALID_AGENTS = frozenset(("claude", "codex", "copilot", "pi"))

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


async def handle(request: web.Request):
    path = request.rel_url.path
    url = f"{UPSTREAM}{request.rel_url}"
    netid, agent = parse_identity(request.headers)
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
    return out


async def on_startup(app):
    global _session
    _session = ClientSession(auto_decompress=False)
    log(f"proxying {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}")
    log(f"usage records -> {COLLECTOR_URL}")


async def on_cleanup(app):
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
