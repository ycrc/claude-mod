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
import pwd
import socket
import re
import sys
import time
from datetime import datetime, timezone

from aiohttp import ClientSession, ClientTimeout, web

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Settings come from the environment, which the supervising loop in the
# serving job's webui.sh sets. That loop runs from Slurm's stored copy of the
# script, so changing a setting there means resubmitting the whole serving job
# (and reloading the model). PROXY_SETTINGS_FILE lets an administrator change
# PROXY_* settings with only a gateway restart instead: KEY=VALUE lines,
# '#' comments; only PROXY_* keys are read, and they override the environment.
def _load_settings_file(path):
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                if key.startswith("PROXY_"):
                    os.environ[key] = value.strip().strip("'\"")
    except FileNotFoundError:
        pass


_load_settings_file(os.environ.get("PROXY_SETTINGS_FILE",
                                   "/apps/services/coding-agents/gateway.env"))

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

# Stable model alias. Harnesses, subagents and module configs ask for
# MODEL_ALIAS (and MODEL_ALIAS + THINK_SUFFIX) rather than a real model name;
# the gateway rewrites it to whatever vLLM is serving, learned from vLLM's own
# /v1/models. Swapping the served model then needs only the vLLM launch to
# change -- no module rebuild, no gateway change. Usage is accounted under the
# real model name, so metrics still show which model did the work. Requests
# naming a real model pass through untouched. Set empty to disable.
MODEL_ALIAS = os.environ.get("PROXY_MODEL_ALIAS", "ycrc-local")
# Seconds between re-reads of vLLM's model list. Whenever vLLM cannot be read
# the alias target is forgotten, so a vLLM restart with a different model is
# re-learned on the first request after it comes back, not up to a minute later.
SERVED_MODEL_REFRESH = float(os.environ.get("PROXY_SERVED_MODEL_REFRESH", "60"))

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

# Identity enforcement. When on, inference endpoints (/v1/...) refuse any
# request that does not carry "<netid>.<agent>" with a recognised agent and a
# netid that exists on this cluster -- i.e. the shared key, no key, a bare or
# malformed key -- with HTTP 403 and a message telling the user how to get
# access. This is what keeps personal installs pointed at the published
# endpoint from using the model anonymously. It is not authentication (the
# credential is not a secret), but it ends anonymous use and makes every
# request accountable to a netid. Requests from IDENTITY_EXEMPT_ADDRS (the
# serving node itself) are always served, for administrators' checks; users
# cannot reach loopback. Refusals are still summarised in the unattributed
# log, with credential kind "<kind>-refused". Off unless set to 1.
REQUIRE_IDENTITY = os.environ.get("PROXY_REQUIRE_IDENTITY", "0") == "1"
IDENTITY_EXEMPT_ADDRS = frozenset(
    a.strip() for a in os.environ.get("PROXY_IDENTITY_EXEMPT_ADDRS", "127.0.0.1,::1").split(",")
    if a.strip())
IDENTITY_MESSAGE = os.environ.get("PROXY_IDENTITY_MESSAGE") or (
    "Direct access to the YCRC-hosted model isn't supported. Use module load "
    "local-coding-agents for access to local only instances (claude, codex, "
    "copilot, pi) or for Claude Enterprise, use module load claude. "
    "Questions: research.computing@yale.edu")
NETID_CACHE_TTL = 3600   # seconds to remember whether a netid exists

# Node-ownership check. The "<netid>.<agent>" key is not a secret: any client
# can name any netid. The module's launcher only runs inside the user's own
# Slurm allocation (as do the Open OnDemand Open WebUI app and claude-mod), so
# a genuine request comes from a node where that netid has a running job. This
# check resolves the client address to its node and asks Slurm who has
# running or completing jobs there (cached NODE_CACHE_TTL seconds per node, refreshed on a
# miss so a job that has just started is not flagged).
#   off      no check (default)
#   flag     serve, but summarise mismatches to NODE_CHECK_LOG
#   enforce  refuse mismatches with HTTP 403
# Any lookup failure (unresolvable address, squeue error or timeout) lets the
# request through: the check must never lock out legitimate users. Requests
# from IDENTITY_EXEMPT_ADDRS (the serving node itself) are not checked.
NODE_CHECK = os.environ.get("PROXY_NODE_CHECK", "off").strip().lower()
NODE_CHECK_LOG = os.environ.get(
    "PROXY_NODE_CHECK_LOG", "/apps/services/coding-agents/state/node-check.jsonl")
NODE_CACHE_TTL = float(os.environ.get("PROXY_NODE_CACHE_TTL", "60"))
NODE_REFRESH_MIN = float(os.environ.get("PROXY_NODE_REFRESH_MIN", "10"))
SQUEUE = os.environ.get("PROXY_SQUEUE", "squeue")
NODE_CHECK_FLUSH = float(os.environ.get("PROXY_NODE_CHECK_FLUSH", "300"))

# Diagnostic: when vLLM rejects a request (HTTP 400), log the request's
# structure -- which message parts it carried (text, image, document,
# tool_result, and the types nested inside them) -- with the start of vLLM's
# error. Types only: never any text, file content or credentials. Added to
# find which Claude Code part triggers "Unexpected item type in content".
# Set PROXY_LOG_REJECTED_SHAPES=0 to turn it off.
LOG_REJECTED_SHAPES = os.environ.get("PROXY_LOG_REJECTED_SHAPES", "1") == "1"

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
# "claude" with the coding-agents launcher. "openwebui" is the Open OnDemand
# Open WebUI app, which runs in the user's own job and sends
# "<netid>.openwebui".
VALID_AGENTS = frozenset(("claude", "codex", "copilot", "pi", "claude-mod", "openwebui"))

# Scripted access. "<netid>.api" is the identity for a researcher's own code --
# the OpenAI or Anthropic SDK, curl, a batch job -- rather than one of the
# harnesses above. It is accepted only when PROXY_API_ACCESS=1 (otherwise it is
# an unknown agent and refused like any other under REQUIRE_IDENTITY).
#
# The label must not become a way round the module's sandbox, so requests on
# it that look like a coding agent are refused (see harness_fingerprint): a
# known harness User-Agent or header, a harness system prompt, or a tool set
# that both runs shell commands and edits files. This raises the bar rather
# than proving anything -- a determined user can strip every marker -- but the
# request is still attributed to a netid (verified by the node-ownership check
# when that is on), so evasion is a policy matter, not an anonymous one.
#
# Scripts are batch-shaped, so they may hold only API_SHARE of the user's
# current share (rounded down, at least 1): a 10,000-item job cannot take every
# slot from the same user's interactive sessions. It scales with load -- with
# the defaults, 24 of 32 on a quiet engine, 6 of 8 when it is busy -- so
# batches run fast when there is room. 0 disables the separate cap.
API_AGENT = "api"
API_ACCESS = os.environ.get("PROXY_API_ACCESS", "0") == "1"
API_SHARE = min(max(float(os.environ.get("PROXY_API_SHARE", "0.75")), 0.0), 1.0)
if API_ACCESS:
    VALID_AGENTS = VALID_AGENTS | {API_AGENT}
# Optional link to user documentation for scripted access, added to refusals.
API_DOCS_URL = os.environ.get("PROXY_API_DOCS_URL", "").strip()
API_HARNESS_MESSAGE = os.environ.get("PROXY_API_HARNESS_MESSAGE") or (
    "This request looks like it comes from a coding agent. Coding agents are "
    "supported through module load local-coding-agents (claude, codex, copilot, "
    "pi), which runs them in a sandbox that protects your files and "
    "credentials. The <netid>.api key is for your own scripts and batch jobs. "
    "If this is a script that was refused by mistake, please tell us at "
    "research.computing@yale.edu")

# Products that identify themselves in User-Agent (or the X-Title/HTTP-Referer
# headers some IDE extensions send). Generic HTTP stacks (undici, OpenAI/Python,
# python-requests, curl) are deliberately absent: researchers' code uses them.
HARNESS_UA_RE = re.compile(os.environ.get("PROXY_API_HARNESS_UA") or (
    r"claude-cli|claude-code|codex|^pi \(|^omp/|copilot|opencode|aider|cline|"
    r"roo-?code|kilo-?code|continue\.dev|cursor|goose|crush|qwen-code|gemini-cli|"
    r"openhands|zed/"), re.I)
# Headers only harnesses send: Codex's originator, Copilot's integration and
# editor headers.
HARNESS_HEADERS = ("originator", "copilot-integration-id", "editor-version",
                   "editor-plugin-version")
# System prompt openings of the common harnesses.
HARNESS_PROMPT_RE = re.compile(
    r"You are Claude Code|Claude Agent SDK|x-anthropic-billing-header|You are a coding agent|"
    r"interactive CLI tool that helps users with software engineering|"
    r"GitHub Copilot CLI|You are opencode|You are Cline|You are Roo|You are Kilo|"
    r"Act as an expert software developer|operating inside pi\b", re.I)
HARNESS_PROMPT_SCAN = 32768   # characters of system prompt examined
# A tool set with one of each is a coding agent. Names are compared lower-case,
# with Anthropic's dated server-tool suffix (bash_20250124) removed.
SHELL_TOOLS = frozenset((
    "bash", "shell", "exec_command", "unified_exec", "local_shell", "run_command",
    "run_shell_command", "execute_command", "terminal", "run_terminal_cmd",
    "run_in_terminal"))
EDIT_TOOLS = frozenset((
    "edit", "multiedit", "write", "apply_patch", "text_editor", "str_replace",
    "str_replace_editor", "str_replace_based_edit_tool", "create_file",
    "write_file", "edit_file", "replace_in_file", "write_to_file",
    "insert_edit_into_file", "notebookedit"))
DATED_TOOL_RE = re.compile(r"_\d{8}$")

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
_served_model = None   # what vLLM serves; resolves MODEL_ALIAS


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
def request_shape(body):
    """Structure of a request for diagnostics: part types only, never content."""
    try:
        payload = json.loads(body)
    except Exception:
        return "unparseable"
    seen = collections.Counter()

    def walk(part, where):
        if isinstance(part, dict):
            t = part.get("type", "?")
            extra = ""
            src = part.get("source")
            if isinstance(src, dict):
                extra = f"({src.get('type', '?')}/{src.get('media_type', '?')})"
            seen[f"{where}{t}{extra}"] += 1
            inner = part.get("content")
            if isinstance(inner, list):
                for p in inner:
                    walk(p, f"{where}{t}>")
        elif isinstance(part, str):
            seen[f"{where}str"] += 1

    if isinstance(payload, dict):
        for m in payload.get("messages") or []:
            if isinstance(m, dict):
                c = m.get("content")
                role = m.get("role", "?")
                if isinstance(c, list):
                    for part in c:
                        walk(part, f"{role}:")
                elif isinstance(c, str):
                    seen[f"{role}:str"] += 1
        inp = payload.get("input")
        if isinstance(inp, list):
            for item in inp:
                walk(item, "input:")
        sysp = payload.get("system")
        if isinstance(sysp, list):
            for part in sysp:
                walk(part, "system:")
    return ", ".join(f"{k} x{v}" for k, v in sorted(seen.items())) or "empty"


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

    The model alias (MODEL_ALIAS, after the thinking suffix is removed) is
    replaced by the served model, and accounted under the real name.

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

    if MODEL_ALIAS and _served_model and payload.get("model") == MODEL_ALIAS:
        payload["model"] = _served_model
        changed = True
        account_as = _served_model + (THINK_SUFFIX if think_requested else "")

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


def add_virtual_models(raw):
    """Advertise the model alias and the thinking variants in /v1/models.

    Some harnesses validate their configured model against this list before
    using it, so the virtual names have to appear here or selecting them fails.
    """
    if not THINK_SUFFIX and not MODEL_ALIAS:
        return raw
    try:
        doc = json.loads(raw)
        data = doc.get("data")
        if not isinstance(data, list):
            return raw
        models = [m for m in data if isinstance(m, dict) and isinstance(m.get("id"), str)]
        if MODEL_ALIAS and models and not any(m["id"] == MODEL_ALIAS for m in models):
            alias = dict(models[0])
            alias["id"] = MODEL_ALIAS
            models.append(alias)
        extra = [m for m in models if m not in data]
        if THINK_SUFFIX:
            for m in models:
                if not m["id"].endswith(THINK_SUFFIX):
                    variant = dict(m)
                    variant["id"] = m["id"] + THINK_SUFFIX
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

    def __init__(self, floor, budget, max_queue, timeout, cap_fn=None):
        self.floor, self.budget = floor, budget
        self.max_queue, self.timeout = max_queue, timeout
        self.cap_fn = cap_fn   # overrides floor/budget when set
        self._keys = {}    # key -> {"held": int, "queue": deque of futures}
        # Throttling since the last summary: key -> [queued, rejected, max wait]
        self.stats = {}

    def cap(self):
        if self.cap_fn is not None:
            return self.cap_fn()
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
# A per-netid cap for "<netid>.api" traffic, taken before the user's share and
# recomputed from it on every check, so it follows the number of active users.
# Script requests already running are never interrupted when it shrinks.
_api_slots = UserSlots(1, 0, USER_MAX_QUEUE, USER_QUEUE_TIMEOUT,
                       cap_fn=lambda: max(1, int(_user_slots.cap() * API_SHARE)))


def limit_key(netid, remote):
    """Key the per-user limit applies to, or None if exempt/disabled."""
    if USER_MAX_INFLIGHT <= 0 or netid in USER_LIMIT_EXEMPT:
        return None
    if netid == "unattributed":
        return f"unattributed@{remote}"
    return netid


def busy_response(path, reason, slots=None):
    slots = slots or _user_slots
    kind = "per user for scripts (<netid>.api)" if slots is _api_slots else "per user"
    msg = (f"Too many concurrent requests for this user ({reason}). This "
           f"shared model currently allows {slots.cap()} at a time {kind}; "
           "please retry shortly.")
    if path.startswith("/v1/messages"):
        payload = {"type": "error",
                   "error": {"type": "rate_limit_error", "message": msg}}
    else:
        payload = {"error": {"message": msg, "type": "rate_limit_error",
                             "code": "rate_limit_exceeded"}}
    return web.json_response(payload, status=429, headers={"Retry-After": "30"})


async def refresh_served_model():
    """Learn the served model from vLLM.

    If vLLM cannot be read (down, restarting, loading) the target is forgotten
    rather than kept: the model may be different when it returns, and a stale
    target would rewrite every alias request to a model that no longer exists.
    proxy() re-resolves on the next request while the target is unknown.
    """
    global _served_model
    ids = []
    try:
        async with _session.get(
                f"{UPSTREAM}/v1/models",
                headers={"Authorization": f"Bearer {UPSTREAM_KEY}"},
                timeout=ClientTimeout(total=5)) as r:
            if r.status == 200:
                data = (await r.json(content_type=None)).get("data") or []
                ids = [m.get("id") for m in data if isinstance(m, dict)]
                ids = [i for i in ids if isinstance(i, str) and i]
    except Exception:
        ids = []
    new = ids[0] if ids else None
    if new != _served_model:
        log(f"model alias {MODEL_ALIAS!r} -> {new!r}"
            + ("" if new else " (vLLM unavailable; re-resolving on next request)"))
        _served_model = new


async def served_model_watcher():
    while True:
        await refresh_served_model()
        await asyncio.sleep(SERVED_MODEL_REFRESH)


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


_netid_cache = {}   # netid -> (exists, monotonic expiry)


def _netid_exists_sync(netid):
    try:
        pwd.getpwnam(netid)
        return True
    except KeyError:
        return False


async def netid_exists(netid):
    """Whether netid is an account on this cluster. Cached; a lookup that
    fails (rather than answering "no such user") counts as existing, so a
    directory-service hiccup can never lock users out."""
    now = time.monotonic()
    hit = _netid_cache.get(netid)
    if hit and hit[1] > now:
        return hit[0]
    try:
        ok = await asyncio.get_running_loop().run_in_executor(
            None, _netid_exists_sync, netid)
    except Exception:
        return True
    if len(_netid_cache) > 20000:
        _netid_cache.clear()
    _netid_cache[netid] = (ok, now + NETID_CACHE_TTL)
    return ok


async def identity_refusal(request):
    """Reason to refuse this request under REQUIRE_IDENTITY, or None."""
    if not REQUIRE_IDENTITY or not request.rel_url.path.startswith("/v1/"):
        return None
    if request.remote in IDENTITY_EXEMPT_ADDRS:
        return None
    netid, agent = parse_identity(request.headers)
    if netid == "unattributed":
        return credential_kind(request.headers)
    # The account first, so "unknown-agent" always names a real netid (the
    # refusal message may repeat it back).
    if not await netid_exists(netid):
        return "unknown-netid"
    if agent not in VALID_AGENTS:
        return "unknown-agent"
    return None


def _tool_names(payload):
    """Lower-case tool names across the chat, Responses and Messages formats."""
    names = set()
    for tool in payload.get("tools") or ():
        if not isinstance(tool, dict):
            continue
        fn = tool.get("function") if isinstance(tool.get("function"), dict) else {}
        # Anthropic and Responses tools carry "name"; chat tools nest it under
        # "function"; built-ins (local_shell, bash_20250124) carry only a type.
        name = tool.get("name") or fn.get("name") or tool.get("type")
        if isinstance(name, str):
            names.add(DATED_TOOL_RE.sub("", name.strip().lower()))
    return names


def _system_text(payload):
    """The start of the system/developer prompt, whichever format carries it."""
    parts = []

    def add(content):
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, str):
                    parts.append(block)
                elif isinstance(block, dict) and isinstance(block.get("text"), str):
                    parts.append(block["text"])

    add(payload.get("system"))          # Messages
    add(payload.get("instructions"))    # Responses
    turns = payload.get("messages") or payload.get("input")
    if isinstance(turns, list):
        for turn in turns:
            if isinstance(turn, dict) and turn.get("role") in ("system", "developer"):
                add(turn.get("content"))
    return "\n".join(parts)[:HARNESS_PROMPT_SCAN]


def harness_fingerprint(headers, body):
    """Why this request looks like a coding agent, or None."""
    for name in ("User-Agent", "X-Title", "HTTP-Referer"):
        if HARNESS_UA_RE.search(headers.get(name, "")):
            return "user-agent"
    for name in HARNESS_HEADERS:
        if name in headers:
            return f"header-{name}"
    if (headers.get("x-app", "").lower() == "cli"
            or "claude-code" in headers.get("anthropic-beta", "").lower()):
        return "header-claude-code"
    try:
        payload = json.loads(body)
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    names = _tool_names(payload)
    if names & SHELL_TOOLS and names & EDIT_TOOLS:
        return "tools"
    if HARNESS_PROMPT_RE.search(_system_text(payload)):
        return "system-prompt"
    return None


_api_refusals_logged = {}   # (netid, reason, user agent) -> monotonic time last logged


def note_api_refusal(netid, reason, user_agent, path):
    """Log a refused api request, at most once per 10 minutes per client kind."""
    ua = (user_agent or "-").replace("\n", " ").replace("\r", " ")[:200]
    key = (netid, reason, ua)
    now = time.monotonic()
    if now - _api_refusals_logged.get(key, -1e9) < 600:
        return
    if len(_api_refusals_logged) > 5000:
        _api_refusals_logged.clear()
    _api_refusals_logged[key] = now
    log(f"api request refused as a coding agent: netid={netid} reason={reason} "
        f"path={path} user_agent={ua!r}")


def api_harness_response(path):
    if path.startswith("/v1/messages"):
        payload = {"type": "error",
                   "error": {"type": "permission_error", "message": API_HARNESS_MESSAGE}}
    else:
        payload = {"error": {"message": API_HARNESS_MESSAGE, "type": "permission_error",
                             "code": "coding_agent_on_api_key"}}
    return web.json_response(payload, status=403)


_host_cache = {}      # client address -> short node name (or None)
_node_users = {}      # node -> (set of netids with running jobs, monotonic fetch time)
_node_flags = {}      # (netid, agent, node, user_agent, path, action) -> counters


async def client_node(addr):
    """Short hostname of a client address; None if it cannot be resolved."""
    if addr in _host_cache:
        return _host_cache[addr]
    try:
        name = (await asyncio.get_running_loop().run_in_executor(
            None, socket.gethostbyaddr, addr))[0]
        node = name.split(".")[0]
    except Exception:
        node = None
    if len(_host_cache) > 20000:
        _host_cache.clear()
    _host_cache[addr] = node
    return node


async def node_job_users(node, max_age):
    """Netids with running (or completing) jobs on node, at most max_age seconds
    old; None on failure. Completing jobs count: a job that has just hit its time
    limit is still the user's for Slurm's KillWait window, and an agent's last
    requests can arrive then (seen 2026-10-26: bd473's session at timeout)."""
    hit = _node_users.get(node)
    now = time.monotonic()
    if hit and now - hit[1] < max_age:
        return hit[0]
    try:
        proc = await asyncio.create_subprocess_exec(
            SQUEUE, "-h", "-t", "R,CG", "-w", node, "-o", "%u",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), 10)
        if proc.returncode != 0:
            return None
    except Exception:
        return None
    users = set(out.decode(errors="ignore").split())
    if len(_node_users) > 5000:
        _node_users.clear()
    _node_users[node] = (users, now)
    return users


async def node_mismatch(request, netid):
    """The client's node if netid has no running job there, else None."""
    if NODE_CHECK not in ("flag", "enforce") or request.remote in IDENTITY_EXEMPT_ADDRS:
        return None
    node = await client_node(request.remote)
    if not node:
        return None
    users = await node_job_users(node, NODE_CACHE_TTL)
    if users is None or netid in users:
        return None
    users = await node_job_users(node, NODE_REFRESH_MIN)   # a job may have just started
    if users is None or netid in users:
        return None
    return node


def note_node_flag(netid, agent, node, user_agent, path, action):
    try:
        ua = (user_agent or "-").replace("\n", " ").replace("\r", " ")[:200]
        key = (netid, agent, node, ua, path, action)
        rec = _node_flags.get(key)
        if rec is None:
            if len(_node_flags) >= UNATTRIBUTED_MAX_KEYS:
                return
            rec = _node_flags[key] = {"requests": 0, "first": time.time()}
        rec["requests"] += 1
        rec["last"] = time.time()
    except Exception:
        pass


def flush_node_flags():
    global _node_flags
    if not _node_flags or not NODE_CHECK_LOG:
        return
    batch, _node_flags = _node_flags, {}
    end = datetime.now(timezone.utc).isoformat(timespec="seconds")
    lines = []
    for (netid, agent, node, ua, path, action), rec in batch.items():
        lines.append(json.dumps({
            "window_end": end, "netid": netid, "agent": agent, "node": node,
            "user_agent": ua, "path": path, "action": action,
            "requests": rec["requests"],
            "first": datetime.fromtimestamp(rec["first"], timezone.utc).isoformat(timespec="seconds"),
            "last": datetime.fromtimestamp(rec["last"], timezone.utc).isoformat(timespec="seconds"),
        }))
    try:
        fd = os.open(NODE_CHECK_LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
        with os.fdopen(fd, "a") as fh:
            fh.write("\n".join(lines) + "\n")
    except Exception as exc:
        log(f"node-check log write failed: {exc!r}")


async def node_flag_flusher():
    while True:
        await asyncio.sleep(NODE_CHECK_FLUSH)
        flush_node_flags()


def node_refusal_response(path, netid, node):
    if API_ACCESS:
        msg = (f"This request identifies as {netid}, but {netid} has no running Slurm "
               f"job on {node}. Run it inside your own Slurm allocation (salloc or "
               "sbatch) on a compute node: coding agents with module load "
               f"local-coding-agents, your own scripts with the key {netid}.api. "
               "Questions: research.computing@yale.edu")
    else:
        msg = (f"This request identifies as {netid}, but {netid} has no running Slurm "
               f"job on {node}. Use module load local-coding-agents inside your own "
               "Slurm allocation. Questions: research.computing@yale.edu")
    if path.startswith("/v1/messages"):
        payload = {"type": "error", "error": {"type": "permission_error", "message": msg}}
    else:
        payload = {"error": {"message": msg, "type": "permission_error",
                             "code": "node_mismatch"}}
    return web.json_response(payload, status=403)


SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9_-]{1,20}$")
SAFE_HOST_RE = re.compile(r"^[A-Za-z0-9.-]+(:\d{1,5})?$")


def identity_message(request, reason):
    """The refusal text for a request without a usable key.

    With scripted access on, it says what was wrong with this key and exactly
    what to set, for people and for agents writing code on their behalf. Only
    the netid and a short, plain label are ever echoed back: a malformed key
    may be a real secret pasted by mistake.
    """
    if os.environ.get("PROXY_IDENTITY_MESSAGE") or not API_ACCESS:
        return IDENTITY_MESSAGE
    raw = ""
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        raw = auth[7:].strip()
    raw = raw or (request.headers.get("x-api-key") or "").strip()
    netid, _, label = raw.partition(".")
    if reason == "none":
        problem = "No API key was sent."
    elif reason == "shared-key":
        problem = "The old shared key is no longer accepted."
    elif reason == "unknown-netid":
        # Not echoed: the "netid" may be some other credential.
        problem = ("The key must start with your own NetID, and the part before "
                   "the dot is not an account on this cluster.")
    elif reason == "unknown-agent" and not label:
        problem = f"The key needs a label after your NetID, e.g. {netid}.api."
    elif reason == "unknown-agent" and SAFE_LABEL_RE.match(label):
        problem = f"'{label}' is not a recognised label in the key {netid}.{label}."
    elif reason == "unknown-agent":
        problem = f"The key for {netid} has an unrecognised label after the dot."
    else:
        problem = "The API key is not in the form <netid>.<label>."
    host = request.host if SAFE_HOST_RE.match(request.host or "") else "<this server>"
    msg = (f"{problem} For your own scripts, run inside a Slurm job (not on a login "
           f"node) and set OPENAI_BASE_URL=http://{host}/v1 and "
           "OPENAI_API_KEY=$(id -un).api (Anthropic SDK: "
           f"ANTHROPIC_BASE_URL=http://{host} and ANTHROPIC_API_KEY=$(id -un).api); "
           f"model ycrc-local, or ycrc-local{THINK_SUFFIX} for extended reasoning. "
           "For coding agents, use module load local-coding-agents (claude, codex, "
           "copilot, pi); for Claude Enterprise, module load claude.")
    if API_DOCS_URL:
        msg += f" Docs: {API_DOCS_URL}"
    return msg + " Questions: research.computing@yale.edu"


def identity_response(path, message=None):
    message = message or IDENTITY_MESSAGE
    if path.startswith("/v1/messages"):
        payload = {"type": "error",
                   "error": {"type": "permission_error", "message": message}}
    else:
        payload = {"error": {"message": message, "type": "permission_error",
                             "code": "identity_required"}}
    return web.json_response(payload, status=403)


async def handle(request: web.Request):
    try:
        reason = await identity_refusal(request)
    except Exception:
        reason = None      # enforcement must never break legitimate traffic
    if reason:
        note_unattributed(request.remote, request.headers.get("User-Agent"),
                          request.rel_url.path, None, f"{reason}-refused", 0, 0)
        try:
            message = identity_message(request, reason)
        except Exception:
            message = None     # fall back to the plain refusal
        return identity_response(request.rel_url.path, message)
    if NODE_CHECK in ("flag", "enforce") and request.rel_url.path.startswith("/v1/"):
        try:
            netid, agent = parse_identity(request.headers)
            if netid != "unattributed":
                node = await node_mismatch(request, netid)
                if node:
                    action = "refused" if NODE_CHECK == "enforce" else "flagged"
                    note_node_flag(netid, agent, node, request.headers.get("User-Agent"),
                                   request.rel_url.path, action)
                    if NODE_CHECK == "enforce":
                        return node_refusal_response(request.rel_url.path, netid, node)
        except Exception:
            pass       # the check must never break legitimate traffic
    key = None
    api_key = None
    if request.method == "POST" and request.rel_url.path.startswith("/v1/"):
        netid, agent = parse_identity(request.headers)
        if API_ACCESS and agent == API_AGENT:
            try:
                # aiohttp caches the body, so proxy() reads it again for free.
                why = harness_fingerprint(request.headers, await request.read())
            except Exception:
                why = None     # a failed check must never break a script
            if why:
                note_api_refusal(netid, why, request.headers.get("User-Agent"),
                                 request.rel_url.path)
                return api_harness_response(request.rel_url.path)
        try:
            key = limit_key(netid, request.remote)
            if key is not None and agent == API_AGENT and API_SHARE > 0:
                api_key = key
        except Exception:
            key = api_key = None     # limiting must never break inference
    if key is None:
        return await proxy(request)
    if api_key is not None:
        try:
            await _api_slots.acquire(api_key)
        except UserBusy as exc:
            return busy_response(request.rel_url.path, str(exc), _api_slots)
    try:
        try:
            await _user_slots.acquire(key)
        except UserBusy as exc:
            return busy_response(request.rel_url.path, str(exc))
        try:
            return await proxy(request)
        finally:
            _user_slots.release(key)
    finally:
        if api_key is not None:
            _api_slots.release(api_key)


async def proxy(request: web.Request):
    global _served_model
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
        if MODEL_ALIAS and _served_model is None:
            await refresh_served_model()
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
        # vLLM is down, perhaps restarting with a different model: re-learn
        # the alias target once it is back rather than wait for the watcher.
        _served_model = None
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
        return web.Response(status=200, body=add_virtual_models(raw),
                            content_type="application/json")

    resp_hdrs = {k: v for k, v in upstream.headers.items()
                 if k.lower() not in HOP_BY_HOP}
    out = web.StreamResponse(status=upstream.status, headers=resp_hdrs)
    # Disable aiohttp's own buffering so SSE reaches the client token by token.
    out.enable_chunked_encoding()

    found = {}
    carry = ""
    streamed = False

    def account_abort():
        # Client hung up: record what was seen. The elapsed time is not a
        # completed response, so report TTFT (if it happened) but no duration.
        if accountable:
            p, c = totals(found)
            record_later(netid, agent, model, p, c, upstream.status, streamed,
                         ttft=ttft)
            if unattrib:
                note_unattributed(unattrib[0], unattrib[1], path, model, unattrib[2], p, c)

    # A client that disconnects is not a gateway error. Letting the
    # ConnectionError escape the handler makes aiohttp log a full traceback
    # ("Cannot write to closing transport"); returning instead lets aiohttp
    # treat the dead connection as an ordinary disconnect when it finishes
    # the response.
    try:
        await out.prepare(request)
    except ConnectionError:
        upstream.release()
        account_abort()
        return out

    try:
        rejected = (LOG_REJECTED_SHAPES and upstream.status == 400 and accountable)
        async for chunk in upstream.content.iter_any():
            # Forward first: accounting must never delay a token.
            await out.write(chunk)
            if rejected:
                rejected = False
                try:
                    err = chunk[:300].decode("utf-8", errors="ignore").replace("\n", " ")
                    # Validation errors echo the offending value ('input': ...),
                    # which can be user text: keep only the error, never values.
                    err = re.sub(r"""['"]input['"]\s*:\s*(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|[^,}]*)""",
                                 "'input': <redacted>", err)
                    log(f"rejected 400 {path} {netid}/{agent} model={model}: "
                        f"{err[:200]} | parts: {request_shape(body)[:1500]}")
                except Exception:
                    pass
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
    except asyncio.CancelledError:
        account_abort()
        raise
    except ConnectionError:
        # Client hung up mid-generation (see above).
        account_abort()
        return out
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
    log(f"identity enforcement: {'ON' if REQUIRE_IDENTITY else 'off'}"
        + (f", exempt {sorted(IDENTITY_EXEMPT_ADDRS)}" if REQUIRE_IDENTITY else ""))
    log(f"scripted access (<netid>.{API_AGENT}): "
        + (f"ON, scripts may hold {API_SHARE:.0%} of a user's share"
           if API_ACCESS and API_SHARE > 0
           else "ON, no separate cap" if API_ACCESS else "off"))
    log(f"node-ownership check: {NODE_CHECK}"
        + (f" -> {NODE_CHECK_LOG}" if NODE_CHECK in ("flag", "enforce") else ""))
    if NODE_CHECK in ("flag", "enforce"):
        app["node_flag_flusher"] = asyncio.create_task(node_flag_flusher())
    if MODEL_ALIAS:
        app["served_model_watcher"] = asyncio.create_task(served_model_watcher())
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
    flush_node_flags()
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
