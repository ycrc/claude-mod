#!/usr/bin/env bash
# rebuild-when-idle.sh -- (re)build local-coding-agents modules once, safely,
# verify them, and stop.
#
#   rebuild-when-idle.sh                       the whole module: the bundle and
#                                              its four hidden harness modules
#   rebuild-when-idle.sh codex-local.eb        just one harness, e.g. after
#                                              rebuilding only its image
#
# Sources must already be staged into easybuild-sources with checksums agreeing
# with the easyconfigs; this script only builds.
#
# Installing a version that is not yet installed touches nothing a running
# session uses, so it proceeds at once. Rebuilding an installed version
# rewrites images that live sessions have mounted, so it first waits for no
# active agent sessions and takes a rollback snapshot of each install (minus
# the unchanged-size .sif images). Builds at most once, gives up at a deadline
# rather than polling forever, and re-checks idleness immediately before
# building to narrow the race against a user starting a session mid-poll.

set -uo pipefail

CHECK=/apps/services/coding-agents/bin/agents-in-use.sh
EB=$HOME/project/generalagents/bouchet-coding-agents-1.0/eb
SRC=$HOME/project/generalagents/easybuild-sources
PREFIX=/apps/software/system/software
LOG=/apps/services/coding-agents/logs/rebuild-when-idle.log
INTERVAL="${INTERVAL:-240}"
DEADLINE_MIN="${DEADLINE_MIN:-50}"

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
ec_field(){ sed -n "s/^$2 = '\(.*\)'$/\1/p" "$EB/$1" | head -1; }

ecs=("$@")
[[ ${#ecs[@]} -gt 0 ]] || ecs=(claude-local.eb codex-local.eb copilot-local.eb pi-local.eb local-coding-agents.eb)

installed=()
for ec in "${ecs[@]}"; do
    [[ -f "$EB/$ec" ]] || { log "ERROR: no easyconfig $EB/$ec"; exit 2; }
    d="$PREFIX/$(ec_field "$ec" name)/$(ec_field "$ec" version)"
    [[ -d "$d" ]] && installed+=("$d")
done

if [[ ${#installed[@]} -gt 0 ]]; then
    log "=== rebuilding installed ${installed[*]}: waiting for an idle window (poll ${INTERVAL}s, give up after ${DEADLINE_MIN}m) ==="
    end=$(( $(date +%s) + DEADLINE_MIN*60 ))
    while :; do
        if [ "$(date +%s)" -ge "$end" ]; then
            log "DEADLINE reached with no idle window; module NOT rebuilt"
            exit 3
        fi
        if timeout 180 "$CHECK" >/dev/null 2>&1; then
            log "idle detected; re-checking to narrow the race"
            sleep 5
            if ! timeout 180 "$CHECK" >/dev/null 2>&1; then
                log "a session appeared on re-check; continuing to wait"
                sleep "$INTERVAL"; continue
            fi
            break
        fi
        sleep "$INTERVAL"
    done

    R=/apps/services/coding-agents/rollback-$(date +%F-%H%M)
    for d in "${installed[@]}"; do
        dest="$R/${d#$PREFIX/}"
        mkdir -p "$dest"
        if rsync -a --exclude '*.sif' "$d/" "$dest/"; then
            log "rollback snapshot: $dest"
        else
            log "ERROR: snapshot of $d failed; refusing to rebuild"; exit 2
        fi
    done
else
    log "=== installing new ${ecs[*]}: nothing in use is touched, not waiting ==="
fi

log "building ${ecs[*]}..."
if ( module load EasyBuild/5.4.0 && cd "$EB" \
     && eb "${ecs[@]}" --robot="$EB" --sourcepath="$SRC" --rebuild ) >>"$LOG" 2>&1; then
    log "BUILD OK"
else
    log "BUILD FAILED -- install may be inconsistent${R:+; rollback at $R}"; exit 2
fi

for ec in "${ecs[@]}"; do
    name="$(ec_field "$ec" name)"; P="$PREFIX/$name/$(ec_field "$ec" version)"
    h="${name%-local}"
    [[ -x "$P/$h" ]] || continue
    log "verify: $name launcher $(sha256sum "$P/$h" | cut -c1-12), image $(sha256sum "$P/coding-agents-$h.sif" | cut -c1-12), think suffix $(grep -h "THINK_SUFFIX='" "$P/coding-agents-provider.conf")"
done
log "=== done ==="
