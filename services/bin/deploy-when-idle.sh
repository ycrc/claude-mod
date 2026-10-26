#!/usr/bin/env bash
# deploy-when-idle.sh -- deploy services/bin, apply gateway settings, and
# restart the gateway and collector once, when no agent sessions are active.
#
#   SERVING_JOB=28502643 deploy-when-idle.sh [PROXY_KEY=VALUE ...]
#
# Each PROXY_KEY=VALUE argument is set in gateway.env (replacing an existing
# line for that key) just before the restart; gateway.env is backed up first.
# Meant to run unattended as its own Slurm job, so it survives the session
# that started it:
#
#   sbatch -p week -t 7-00:00:00 -c 1 --mem=1G -o deploy-when-idle-%j.out \
#     --wrap "SERVING_JOB=28502643 services/bin/deploy-when-idle.sh PROXY_API_ACCESS=1"
#
# Like rebuild-when-idle.sh, it waits for agents-in-use.sh to report idle,
# re-checks a few seconds later to narrow the race against a session starting,
# deploys at most once, and gives up at a deadline rather than polling forever.
# Open WebUI and scripted traffic are not agent sessions, so it also waits for
# zero in-flight requests right before restarting. DRY_RUN=1 performs every
# check (including reaching the serving job) but deploys, edits and kills
# nothing.

set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST=/apps/services/coding-agents
CHECK="$DEST/bin/agents-in-use.sh"
ENV_FILE="$DEST/gateway.env"
LOG="${LOG:-$DEST/logs/deploy-when-idle.log}"
GATEWAY="${GATEWAY:-http://a1127u31n01.mghpcc.ycrc.yale.edu:8008}"
METRICS="${METRICS:-http://a1127u31n01.mghpcc.ycrc.yale.edu:9103/metrics}"
INTERVAL="${INTERVAL:-300}"
DEADLINE_MIN="${DEADLINE_MIN:-9900}"     # just under the week partition's 7 days
DRY_RUN="${DRY_RUN:-0}"
: "${SERVING_JOB:?set SERVING_JOB to the serving job id}"

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
in_flight(){
    curl -s --max-time 10 "$METRICS" 2>/dev/null | awk '
        /^vllm:num_requests_(running|waiting)\{/ {s += $2; seen = 1}
        END {if (seen) printf "%d", s; else print "unknown"}'
}
# srun into the serving job, without this job's own Slurm settings leaking in.
on_serving_node(){
    local unset_args=()
    while IFS= read -r v; do unset_args+=(-u "$v"); done < <(compgen -e | grep '^SLURM_')
    env "${unset_args[@]}" srun --overlap --jobid="$SERVING_JOB" --ntasks=1 bash -c "$1"
}

settings=("$@")
for kv in "${settings[@]}"; do
    [[ "$kv" =~ ^PROXY_[A-Z0-9_]+=[^[:space:]]*$ ]] || { log "ERROR: bad setting '$kv'"; exit 2; }
done

log "=== deploy-when-idle: job ${SLURM_JOB_ID:-none}, serving job $SERVING_JOB, settings: ${settings[*]:-none}, dry run: $DRY_RUN ==="
log "repo $(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null)"

# Fail fast if the serving job cannot be reached, rather than after waiting.
if ! out="$(on_serving_node 'hostname -s; pgrep -f "[a]gent-token-proxy.py" | head -1; pgrep -f "[a]gent-usage-collector.py" | head -1' 2>&1)"; then
    log "ERROR: cannot reach serving job $SERVING_JOB: $out"; exit 2
fi
log "serving job reachable: $(echo $out)"

log "waiting for an idle window (poll ${INTERVAL}s, give up after ${DEADLINE_MIN}m)"
end=$(( $(date +%s) + DEADLINE_MIN * 60 ))
while :; do
    if [ "$(date +%s)" -ge "$end" ]; then
        log "DEADLINE reached with no idle window; nothing deployed"; exit 3
    fi
    if timeout 240 "$CHECK" >/dev/null 2>&1; then
        sleep 5
        if timeout 240 "$CHECK" >/dev/null 2>&1; then
            log "idle confirmed"; break
        fi
        log "a session appeared on re-check; continuing to wait"
    fi
    [[ "$DRY_RUN" == 1 ]] && { log "DRY RUN: not idle now; a real run would keep waiting"; break; }
    sleep "$INTERVAL"
done

if [[ "$DRY_RUN" == 1 ]]; then
    log "DRY RUN: would run $REPO/services/deploy.sh"
    for kv in "${settings[@]}"; do log "DRY RUN: would set ${kv} in $ENV_FILE"; done
    log "DRY RUN: in-flight requests now: $(in_flight)"
    log "DRY RUN: would SIGKILL the gateway and collector via job $SERVING_JOB"
    exit 0
fi

log "deploying"
if ! "$REPO/services/deploy.sh" >>"$LOG" 2>&1; then
    log "ERROR: deploy.sh failed or found sessions; nothing restarted"; exit 4
fi

if [[ ${#settings[@]} -gt 0 ]]; then
    cp -p "$ENV_FILE" "$ENV_FILE.bak-$(date +%F-%H%M)"
    tmp="$(mktemp "$ENV_FILE.XXXXXX")"
    cp -p "$ENV_FILE" "$tmp"
    for kv in "${settings[@]}"; do
        key="${kv%%=*}"
        if grep -q "^${key}=" "$tmp"; then
            sed -i "s|^${key}=.*|${kv}|" "$tmp"
        else
            printf '%s\n' "$kv" >> "$tmp"
        fi
    done
    mv -f "$tmp" "$ENV_FILE"
    log "gateway.env now: $(grep -v '^#' "$ENV_FILE" | grep . | paste -sd' ')"
fi

# Restart only between requests: wait up to 10 minutes for none in flight.
for _ in $(seq 1 120); do
    n="$(in_flight)"
    [[ "$n" == 0 ]] && break
    sleep 5
done
log "in-flight requests at restart: $n"

if ! on_serving_node 'kill -9 $(pgrep -f "[a]gent-token-proxy.py") $(pgrep -f "[a]gent-usage-collector.py")' >>"$LOG" 2>&1; then
    log "ERROR: restart command failed; check job $SERVING_JOB"; exit 5
fi
log "SIGKILL sent; waiting for the supervision loops to restart both services"

ok=0
for _ in $(seq 1 24); do
    sleep 5
    g="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$GATEWAY/health")"
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$METRICS")"
    if [[ "$g" == 200 && "$c" == 200 ]]; then ok=1; break; fi
done
if [[ $ok != 1 ]]; then
    log "ERROR: services not healthy after 2 minutes (gateway $g, collector $c)"; exit 6
fi
log "healthy: gateway $g, collector $c"

# Smoke tests: one request on the api label, one refused key.
api="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $(id -un).api" -H 'Content-Type: application/json' \
    -d '{"model":"ycrc-local","reasoning_effort":"none","max_tokens":5,"messages":[{"role":"user","content":"Say ok."}]}')"
bad="$(curl -s --max-time 30 "$GATEWAY/v1/models" -H 'Authorization: Bearer not-a-key')"
log "smoke test: <netid>.api request -> HTTP $api; refused-key message: ${bad:0:160}"
log "=== done ==="
