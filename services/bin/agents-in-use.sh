#!/usr/bin/env bash
# agents-in-use.sh -- report active local-coding-agents sessions.
#
# Run this before restarting vLLM, restarting the gateway, or rebuilding the
# module. All three disrupt live users:
#
#   vLLM restart     kills in-flight generation and takes ~6 min to reload
#   gateway restart  ~10s outage; drops any request in flight
#   module rebuild   EasyBuild rewrites coding-agents.sif in place, and a
#                    running agent has that image mounted
#
# Session records are only written when a session EXITS, so the metrics
# endpoint cannot tell you who is active right now. This scans for the actual
# container processes instead, which catches idle-but-open sessions too.
#
# Scanning is targeted rather than cluster-wide: only nodes allocated to netids
# that have used the module are checked, which is a handful rather than ~350.
#
# Exit status: 0 if idle (safe), 1 if sessions are active, 2 on error.

set -uo pipefail

METRICS="${METRICS_URL:-http://a1127u31n01.mghpcc.ycrc.yale.edu:9103/metrics}"
# Match the Apptainer runtime process specifically, not merely any command
# line that mentions the image. Without the "Apptainer runtime parent" anchor,
# any shell command that happens to contain the image name -- including the
# maintenance command about to run -- is reported as an active session.
# The bracketed first character additionally stops the scan matching itself.
SIF_PATTERN="${SIF_PATTERN:-[A]pptainer runtime parent: coding-agents\.sif}"

command -v clush >/dev/null 2>&1 || { echo "error: clush not found" >&2; exit 2; }

echo "== in-flight inference =="
metrics="$(curl -s --max-time 10 "$METRICS" 2>/dev/null)"
if [[ -z "$metrics" ]]; then
    echo "  WARNING: metrics endpoint unreachable; cannot check in-flight requests"
else
    running=$(awk '/^vllm:num_requests_running\{/ {s+=$2} END {printf "%d", s+0}' <<< "$metrics")
    waiting=$(awk '/^vllm:num_requests_waiting\{/ {s+=$2} END {printf "%d", s+0}' <<< "$metrics")
    echo "  running: ${running}   waiting: ${waiting}"
fi

# Netids that have ever used the module; their jobs are the only places an
# agent can be running.
mapfile -t netids < <(grep -oE 'coding_agents_sessions_total\{[^}]*netid="[^"]+"' <<< "$metrics" \
    | grep -oE 'netid="[^"]+"' | cut -d'"' -f2 | sort -u | grep -v '^unattributed$')
mapfile -t tok_netids < <(grep -oE 'coding_agents_prompt_tokens_total\{[^}]*netid="[^"]+"' <<< "$metrics" \
    | grep -oE 'netid="[^"]+"' | cut -d'"' -f2 | sort -u | grep -v '^unattributed$')
netids=($(printf '%s\n' "${netids[@]:-}" "${tok_netids[@]:-}" | sort -u | grep -v '^$'))

if [[ ${#netids[@]} -eq 0 ]]; then
    echo "== no known module users; nothing to scan =="
    exit 0
fi

echo "== known module users: ${netids[*]} =="

nodes=""
for u in "${netids[@]}"; do
    n="$(squeue -u "$u" -h -t RUNNING -o "%N" 2>/dev/null | paste -sd, -)"
    [[ -n "$n" ]] && nodes="${nodes:+$nodes,}$n"
done

if [[ -z "$nodes" ]]; then
    echo "== none of them have running jobs -- no agent can be active =="
    exit 0
fi

expanded="$(scontrol show hostnames "$nodes" 2>/dev/null | sort -u | paste -sd, -)"
count=$(tr ',' '\n' <<< "$expanded" | grep -c .)
echo "== scanning $count node(s) for live agent containers =="

hits="$(clush -w "$expanded" -t 5 -u 30 \
        "pgrep -af '$SIF_PATTERN' 2>/dev/null" 2>/dev/null | grep -v '^clush:' || true)"

if [[ -z "$hits" ]]; then
    echo
    echo "IDLE -- no active agent sessions found. Safe to restart or rebuild."
    exit 0
fi

echo
echo "ACTIVE SESSIONS:"
sed 's/^/  /' <<< "$hits"
echo
echo "IN USE -- do not restart vLLM, restart the gateway, or rebuild the module."
exit 1
