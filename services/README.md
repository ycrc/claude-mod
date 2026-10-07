# Inference-path services

These run on the vLLM serving node and are **not** part of the EasyBuild
module. EasyBuild only consumes `eb/`, so this directory is inert to the build.

They live in this repository anyway because they share a contract with the
launcher in `eb/`, and that contract spans both halves:

| Contract | Produced by | Consumed by |
| --- | --- | --- |
| `-think` model suffix | `coding-agents-wrapper.sh` | `agent-token-proxy.py` |
| `<netid>.<agent>` credential | `coding-agents-wrapper.sh` | `agent-token-proxy.py` |
| session record → `/ingest` | `coding-agents-wrapper.sh` | `agent-usage-collector.py` |

Changing either side alone breaks the system, so they belong in the same
commit. That is the whole reason these files are here rather than in a branch
or a separate repository.

## What each piece does

| File | Role |
| --- | --- |
| `bin/agent-token-proxy.py` | Gateway. Owns the public port, recovers the netid from the credential, forwards to vLLM on loopback, reports token usage. **In the inference path** — if it stops, the service stops. |
| `bin/agent-usage-collector.py` | Metrics. Receives session and token records, exposes the Prometheus scrape target, federates vLLM's own metrics. Out of the inference path. |
| `bin/agents-in-use.sh` | Safety gate. Reports whether anyone has a live agent session. Exit 0 = idle, 1 = in use. |
| `bin/rebuild-when-idle.sh` | Waits for an idle window, then rebuilds the module once. |
| `PROMETHEUS-ENDPOINT.md` | Handoff document for whoever runs Prometheus. |

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

`/apps/services/coding-agents/state/` holds the persisted counters and the
per-session audit trail. It is `drwxr-s--- support` because it contains
per-netid data, and it must never be committed.
