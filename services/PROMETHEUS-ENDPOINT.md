# Coding-agents usage endpoint — Prometheus scrape target

Per-netid usage accounting for the `local-coding-agents` module (Qwen3.8-27B
served by vLLM on Bouchet).

## Scrape target

```
http://a1127u31n01.mghpcc.ycrc.yale.edu:9103/metrics
```

Plain HTTP, no authentication, no TLS. Returns the standard Prometheus text
exposition format. A suggested scrape interval is 30s; the endpoint is cheap
(it serves from memory and makes one local call to vLLM).

```yaml
  - job_name: coding-agents
    scrape_interval: 30s
    static_configs:
      - targets: ['a1127u31n01.mghpcc.ycrc.yale.edu:9103']
        labels:
          cluster: bouchet
```

### One target, not two

This endpoint already includes vLLM's own `/metrics` output, so a single
scrape covers both per-netid usage and vLLM's aggregate serving metrics
(`vllm:*` — ~1380 series across the 4 data-parallel engines). There is no need
to also scrape `:8008/metrics`.

If you would rather keep them independent — so that a collector outage doesn't
also blind you to vLLM — set `COLLECTOR_FEDERATE_VLLM=0` on the collector and
add `a1127u31n01.mghpcc.ycrc.yale.edu:8008` as a second target. vLLM's
`/metrics` is unauthenticated and can be scraped directly.

### Caveat: the hostname moves

The endpoint lives on whichever node the inference job is allocated. That is
currently `a1127u31n01` and is stable in practice — the job holds a
`reservation=inference` with a 31-day walltime — but it **will** change when
the job is resubmitted onto a different node.

If that matters, the robust fix is `file_sd_configs` pointed at a small JSON
file that the serving job rewrites with its own hostname on startup. Happy to
add that if you want the target to follow the job automatically.

## Metrics exposed

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `coding_agents_sessions_total` | counter | `cluster`, `netid`, `agent` | Agent sessions recorded |
| `coding_agents_session_seconds_total` | counter | `cluster`, `netid`, `agent` | Wall-clock seconds in session |
| `coding_agents_sessions_failed_total` | counter | `cluster`, `netid`, `agent` | Sessions exiting non-zero |
| `coding_agents_last_session_timestamp_seconds` | gauge | `cluster`, `netid`, `agent` | Unix time of last session end |
| `coding_agents_distinct_netids` | gauge | `cluster` | Distinct netids seen to date |
| `coding_agents_records_ingested_total` | counter | `cluster` | Session records accepted |
| `coding_agents_records_rejected_total` | counter | `cluster` | Records rejected as invalid |
| `coding_agents_collector_uptime_seconds` | gauge | `cluster` | Collector uptime |
| `coding_agents_vllm_scrape_up` | gauge | `cluster` | 1 if vLLM metrics were readable |
| `coding_agents_prompt_tokens_total` | counter | `cluster`, `netid`, `agent`, `model` | Prompt (input) tokens |
| `coding_agents_completion_tokens_total` | counter | `cluster`, `netid`, `agent`, `model` | Completion (output) tokens |
| `coding_agents_model_requests_total` | counter | `cluster`, `netid`, `agent`, `model` | Inference requests |
| `coding_agents_token_reports_total` | counter | `cluster` | Token reports accepted from the gateway |
| `coding_agents_token_reports_rejected_total` | counter | `cluster` | Token reports rejected as invalid |
| `coding_agents_ttft_seconds` | histogram | `cluster`, `netid`, `agent` | Time to first byte, per netid |
| `coding_agents_request_duration_seconds` | histogram | `cluster`, `netid`, `agent` | Full request duration, per netid |

`agent` is one of `claude`, `codex`, `copilot`, `pi`.

### Cardinality

One series per (netid, agent) pair, per metric. With four harnesses that is at
most 4 series per netid per metric — a few thousand series even at full
campus adoption. The collector hard-caps distinct series at 20,000 and rejects
new ones beyond that, so a malformed or hostile client cannot blow up the TSDB.

### Example queries

```promql
# Weekly active netids
count(count by (netid) (increase(coding_agents_sessions_total[7d]) > 0))

# Sessions per harness per day
sum by (agent) (increase(coding_agents_sessions_total[1d]))

# Heaviest users by time spent, this month
topk(20, sum by (netid) (increase(coding_agents_session_seconds_total[30d])))

# Failure rate per harness
sum by (agent) (increase(coding_agents_sessions_failed_total[1d]))
  / sum by (agent) (increase(coding_agents_sessions_total[1d]))

# Heaviest users by tokens this month -- the cost question
topk(20, sum by (netid) (
  increase(coding_agents_prompt_tokens_total[30d])
  + increase(coding_agents_completion_tokens_total[30d])))

# Token throughput per harness
sum by (agent) (rate(coding_agents_completion_tokens_total[5m]))

# Share of tokens that could not be attributed to a netid
sum(increase(coding_agents_prompt_tokens_total{netid="unattributed"}[1d]))
  / sum(increase(coding_agents_prompt_tokens_total[1d]))

# p95 time-to-first-token per netid -- "is this user seeing slow responses?"
histogram_quantile(0.95,
  sum by (netid, le) (rate(coding_agents_ttft_seconds_bucket[30m])))

# p95 full request duration per harness
histogram_quantile(0.95,
  sum by (agent, le) (rate(coding_agents_request_duration_seconds_bucket[30m])))

# Mean TTFT per netid
rate(coding_agents_ttft_seconds_sum[30m])
  / rate(coding_agents_ttft_seconds_count[30m])
```

### Latency: per-netid vs cluster-wide

The `coding_agents_*_seconds` histograms above are measured at the gateway, so
they are what the client experienced end to end — queueing, prefill and decode
included — and they are attributable to a netid.

The federated `vllm:*` histograms cover the same ground cluster-wide and break
it down by phase, which the per-netid ones cannot:
`vllm:time_to_first_token_seconds`, `vllm:e2e_request_latency_seconds`,
`vllm:request_queue_time_seconds`, `vllm:request_prefill_time_seconds`,
`vllm:request_decode_time_seconds`, `vllm:request_time_per_output_token_seconds`,
plus `vllm:num_requests_waiting` for live queue depth.

Use the per-netid histograms to find *who* is slow, then the `vllm:*` phase
breakdown to find *why*. On this workload, prefill dominates first-token time
because agent prompts run to ~200k tokens; queue time is typically negligible.

## How records get there

The `local-coding-agents` wrapper POSTs one JSON record to `:9103/ingest` when
an agent session exits. The netid comes from the account database (`id -un`),
not from the environment.

**Recorded:** netid, uid, harness, cluster, model, Slurm job ID, node,
start/end time, duration, exit status.

**Not recorded:** prompts, completions, file paths, command arguments, working
directory. Nothing about what the user was doing — only that they used it.

Reporting is best-effort and bounded by a 3-second timeout with all output
discarded, so a collector outage cannot break or delay anyone's session.
Measured overhead on session exit is ~28ms.

## Token attribution

vLLM's own metrics are aggregate-only, so `vllm:request_prompt_tokens_sum`
cannot be attributed to anyone. The per-netid token counters above come from a
gateway that fronts vLLM on this node: vLLM listens on loopback only, the
gateway owns the public port, and it reads the `usage` block out of each
response as it streams past.

Counts are the model's own, not an estimate. Spot-checked against the
harnesses' self-reported totals: Codex reported "13,908 tokens used" for a
request recorded here as 13906 prompt + 2 completion.

Traffic that presents no netid is still served normally and recorded under
`netid="unattributed"`, so nothing silently disappears from the totals.

## How much to trust the numbers

Token counts are measured at the gateway and are solid. The session figures
are self-reported by the launcher, so treat them as advisory. Neither path is
an authentication boundary.

One caveat about reading session duration as load: wall-clock time is a weak
proxy for consumption. An agent sitting idle at a prompt for an hour logs an
hour at near-zero cost, while a short session over a large context can be far
more expensive. For cost questions, use the token counters.

## Operations

The collector runs beside vLLM, started from `/home/mrr68/logs/webui.sh`:

```
/apps/services/coding-agents/bin/agent-usage-collector.py  # metrics service (stdlib python3)
/apps/services/coding-agents/bin/agent-token-proxy.py      # gateway in front of vLLM (aiohttp)
/apps/services/coding-agents/state/state.json              # persisted counters
/apps/services/coding-agents/state/sessions.jsonl          # raw per-session audit trail
/apps/services/coding-agents/logs/collector.log            # collector log
/apps/services/coding-agents/logs/gateway.log              # gateway log
```

Port layout on the serving node:

| Port | Bound | Serves |
|---|---|---|
| 8008 | `0.0.0.0` | gateway — the OpenAI/Anthropic API surface clients use |
| 8010 | `127.0.0.1` | vLLM itself, reachable only via the gateway |
| 9103 | `0.0.0.0` | this metrics endpoint |
| 8080 | `0.0.0.0` | open-webui |

Both services are supervised by restart loops in `webui.sh` and restart on
crash; a clean exit (job teardown) stops the loop rather than fighting it.
The gateway waits for vLLM to answer before binding, so it never fronts a
still-loading model.

`bin/` and this document are world-readable. `state/` and `logs/` are
`drwxr-s--- support`, since they hold per-netid data that shouldn't be readable
by every cluster user.

Counters are persisted to disk and reloaded on startup, so they stay monotonic
across restarts and reschedules. `sessions.jsonl` keeps the raw records
independently of the counters, so history can be recomputed if needed.

Health check: `curl http://a1127u31n01.mghpcc.ycrc.yale.edu:9103/health`

Contact: Michael Rothberg (mrr68) — maintainer of the locally hosted model.
