# Inference-path services

These run on the vLLM serving node and are **not** part of the EasyBuild
module. EasyBuild only consumes `eb/`, so this directory is inert to the build.

They live in this repository anyway because they share a contract with the
launcher in `eb/`, and that contract spans both halves:

| Contract | Produced by | Consumed by |
| --- | --- | --- |
| `ycrc-local` model alias | `coding-agents-provider.conf`, `codex-config.toml`, `pi-models.json`, site subagents | `agent-token-proxy.py` |
| `-think` model suffix | `coding-agents-wrapper.sh` | `agent-token-proxy.py` |
| `<netid>.<agent>` credential (agents: claude, codex, copilot, pi, claude-mod) | `coding-agents-wrapper.sh`, claude-mod's in-house mode | `agent-token-proxy.py`, `agent-usage-collector.py` |
| session record → `/ingest` | `coding-agents-wrapper.sh` | `agent-usage-collector.py` |

Changing either side alone breaks the system, so they belong in the same
commit. That is the whole reason these files are here rather than in a branch
or a separate repository.

## What each piece does

| File | Role |
| --- | --- |
| `bin/agent-token-proxy.py` | Gateway. Owns the public port, recovers the netid from the credential, forwards to vLLM on loopback, reports token usage. **In the inference path** — if it stops, the service stops. |
| `bin/agent-usage-collector.py` | Metrics. Receives session and token records, exposes the Prometheus scrape target, federates vLLM's own metrics. Out of the inference path. |
| `bin/agents-in-use.sh` | Safety gate. Reports whether anyone has a live agent session (1.0's `coding-agents.sif` or 1.1's `coding-agents-<harness>.sif`). Exit 0 = idle, 1 = in use. |
| `bin/rebuild-when-idle.sh` | Installs or rebuilds module easyconfigs (default: the bundle and its four harness modules). A new version installs at once; rebuilding an installed one waits for an idle window and snapshots it first. |
| `PROMETHEUS-ENDPOINT.md` | Handoff document for whoever runs Prometheus. |

## Gateway behaviour

Besides attribution, the gateway rewrites requests so the harnesses and the
served model fit together. Each behaviour is configured by environment
variables in `webui.sh`'s gateway loop; the defaults are what production runs.
To change a setting without resubmitting the serving job, put `KEY=VALUE`
lines in `/apps/services/coding-agents/gateway.env` (only `PROXY_*` keys are
read; they override the environment) and restart the gateway.

| Behaviour | What it does | Settings |
| --- | --- | --- |
| Model alias | `ycrc-local` (and `ycrc-local-think`) is rewritten to whatever vLLM serves, learned from vLLM's `/v1/models` and re-learned after any outage. Usage is accounted under the real name. | `PROXY_MODEL_ALIAS` (`ycrc-local`; empty disables), `PROXY_SERVED_MODEL_REFRESH` (60 s) |
| Thinking variant | `<model>-think` turns reasoning on, at `PROXY_THINK_EFFORT` if the request names no effort. | `PROXY_THINK_SUFFIX` (`-think`), `PROXY_THINK_EFFORT` (`medium`) |
| Effort mapping | Clients' effort values (none, minimal, low, medium, high, xhigh, max, in any wire format) are mapped onto the chat template's low/medium/xhigh; `none` turns reasoning off; unknown values are dropped rather than rejected. | `PROXY_EFFORT_MAP` (JSON) |
| Per-user limit | A budget of concurrent requests is shared by the users currently active (32 alone, 16 with two, ... never below 8). Extra requests wait in order; beyond the queue or wait limit they get HTTP 429. Unattributed traffic is limited per client address. | `PROXY_ENGINE_BUDGET` (32; 0 = fixed), `PROXY_USER_MAX_INFLIGHT` (8; 0 disables), `PROXY_USER_MAX_QUEUE` (64), `PROXY_USER_QUEUE_TIMEOUT` (300 s), `PROXY_USER_LIMIT_EXEMPT` |
| Identity enforcement | Off by default. With `PROXY_REQUIRE_IDENTITY=1`, `/v1/` requests without `<netid>.<agent>` (recognised agent, existing netid) get HTTP 403 with a message pointing to `module load local-coding-agents` and `module load claude`. Requests from the serving node itself are exempt. Refusals are logged as `<kind>-refused`. Not authentication: the credential is not a secret. | `PROXY_REQUIRE_IDENTITY` (0), `PROXY_IDENTITY_EXEMPT_ADDRS` (`127.0.0.1,::1`), `PROXY_IDENTITY_MESSAGE` |
| Node-ownership check | Off by default. `flag` logs, and `enforce` refuses (HTTP 403), requests whose key names a netid with no running Slurm job on the client's node, i.e. a key that names someone else. Node owners come from `squeue`, cached a minute and refreshed on a miss; lookup failures let the request through; loopback is exempt. Mismatches are summarised to `state/node-check.jsonl` (netid, agent, node, User-Agent). | `PROXY_NODE_CHECK` (`off`/`flag`/`enforce`), `PROXY_NODE_CHECK_LOG`, `PROXY_NODE_CACHE_TTL` (60 s) |
| Unattributed clients | Requests without a usable `<netid>.<agent>` credential are summarised (address, User-Agent, path, model, counts; never prompts or keys) every 5 minutes to `state/unattributed.jsonl`. | `PROXY_UNATTRIBUTED_LOG` (empty disables) |

The gateway logs alias changes and a once-a-minute summary of throttled users
to `logs/gateway.log`.

## Changing the served model

The module never names the model, so a swap touches only the serving side:
change `--served-model-name` and the model flags in `~/logs/webui.sh`, and
relaunch vLLM inside the running job (as `~/logs/restart-vllm-flashnext.sh`
does). The gateway follows on the first request after vLLM is healthy. Only
the context and output limits in `coding-agents-provider.conf`,
`codex-config.toml` and `pi-models.json` are model-specific; if they change,
rebuild the module. Clients that name a model directly (not `ycrc-local`)
must be updated, or they get HTTP 404.

`~/logs/cutover-flashnext.sh` is the idle-gated cutover used for the
2026-10-12 switch to Qwen3.8-Flash-Next: it stops vLLM, launches the new
model, verifies it through the gateway, rolls back to the previous model on
any failure, and runs `tests/module-e2e.sh` afterwards.

## Deploying

`deploy.sh` copies `bin/` and the handoff doc to
`/apps/services/coding-agents/`. It refuses to run while anyone has a live
session, because overwriting the gateway under traffic drops in-flight
requests.

```bash
./services/deploy.sh            # refuses if sessions are active
./services/deploy.sh --force    # skip the idle check (know why you are doing this)
```

Copying the files does **not** restart anything. The running processes keep
their loaded code until restarted:

```bash
# on the serving node, via the job's allocation
kill -9 $(pgrep -f '[a]gent-token-proxy.py')
```

Use `SIGKILL`, not `SIGTERM`. Both services are supervised by restart loops in
`webui.sh`, and those loops treat a clean exit (rc 0) as "stop", so `SIGTERM`
on the collector shuts it down permanently instead of restarting it.

## State that is deliberately not in git

`/apps/services/coding-agents/state/` holds the persisted counters, the
per-session audit trail and the unattributed-client log. It is `drwxr-s--- support` because it contains
per-netid data, and it must never be committed.
