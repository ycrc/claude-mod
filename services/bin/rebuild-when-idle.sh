#!/usr/bin/env bash
# rebuild-when-idle.sh -- wait for no active agent sessions, then rebuild the
# local-coding-agents module once, verify it, and stop.
#
# Sources must already be staged into easybuild-sources with checksums agreeing
# with the easyconfig; this script only builds. It takes a rollback snapshot of
# the current install (minus the unchanged .sif) before touching anything.
#
# Safety: builds at most once, gives up at a deadline rather than polling
# forever, and re-checks idleness immediately before building to narrow the
# race against a user starting a session mid-poll.

set -uo pipefail

CHECK=/apps/services/coding-agents/bin/agents-in-use.sh
EB=$HOME/project/generalagents/bouchet-coding-agents-1.0/eb
SRC=$HOME/project/generalagents/easybuild-sources
LOG=/apps/services/coding-agents/logs/rebuild-when-idle.log
INTERVAL="${INTERVAL:-240}"
DEADLINE_MIN="${DEADLINE_MIN:-50}"

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

log "=== waiting for an idle window (poll ${INTERVAL}s, give up after ${DEADLINE_MIN}m) ==="
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

R=/apps/services/coding-agents/rollback-1.0-presubagents-$(date +%F-%H%M)
mkdir -p "$R"
if rsync -a --exclude 'coding-agents.sif' \
      /apps/software/system/software/local-coding-agents/1.0/ "$R/"; then
    log "rollback snapshot: $R"
else
    log "ERROR: snapshot failed; refusing to rebuild"; exit 2
fi

log "building..."
if ( module load EasyBuild/5.4.0 && cd "$EB" \
     && eb local-coding-agents.eb --sourcepath="$SRC" --rebuild ) >>"$LOG" 2>&1; then
    log "BUILD OK"
else
    log "BUILD FAILED -- install may be inconsistent; rollback at $R"; exit 2
fi

P=/apps/software/system/software/local-coding-agents/1.0
log "verify: subagents shipped -> $(ls "$P/share/agents/subagents/" 2>/dev/null | tr '\n' ' ')"
log "verify: linker present    -> $(grep -c link_site_subagents_non_destructive "$P/coding-agents-wrapper.sh")"
log "verify: think suffix      -> $(grep -h "THINK_SUFFIX='" "$P/coding-agents-provider.conf")"
log "verify: harness hashes    -> $(for h in claude codex copilot pi; do sha256sum "$P/$h"|cut -c1-12; done | sort -u | tr '\n' ' ')"
log "=== done ==="
