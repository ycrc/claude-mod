#!/usr/bin/env bash
# retire-when-unused.sh -- retire old local-coding-agents versions once nothing
# runs from them.
#
#   retire-when-unused.sh 1.2 1.3
#
# Each version is retired on its own, as soon as no process runs from it: its
# install directories and module files (the bundle and the four hidden harness
# modules) are MOVED, not deleted, to $DEST/retired-<version>-<date>, and the
# Lmod cache is refreshed. Restore by moving them back under
# /apps/software/system. A version's processes are counted on every node where
# agents-in-use.sh reports a live agent container, by matching its launcher path
# (.../software/<harness>-local/<version>/); any failure to check counts as "in
# use". Meant to run unattended as its own Slurm job:
#
#   sbatch -p week -t 7-00:00:00 -c 1 --mem=1G -o retire-%j.out \
#     --wrap "services/bin/retire-when-unused.sh 1.2 1.3"
#
# Generalises the one-off retire-1.1.sh (2026-10-22).

set -uo pipefail

CHECK=/apps/services/coding-agents/bin/agents-in-use.sh
SW=/apps/software/system/software
MOD=/apps/software/system/modules
DEST=/apps/services/coding-agents
LOG="${LOG:-$DEST/logs/retire-when-unused.log}"
CACHE_UPDATE=/apps/custom/lmod/bin/update-cache.sh
CACHE_FILE=/apps/custom/lmod/cache/spiderT.lua
NAMES=(claude-local codex-local copilot-local pi-local local-coding-agents)
INTERVAL="${INTERVAL:-300}"
DEADLINE_MIN="${DEADLINE_MIN:-9900}"     # just under the week partition's 7 days
DRY_RUN="${DRY_RUN:-0}"                  # 1: count once, report, move nothing

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

[[ $# -gt 0 ]] || { sed -n '2,18p' "$0"; exit 2; }
pending=()
for v in "$@"; do
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { log "ERROR: bad version '$v'"; exit 2; }
    [[ -d "$SW/local-coding-agents/$v" ]] || { log "ERROR: local-coding-agents/$v is not installed"; exit 2; }
    pending+=("$v")
done
default="$(ls "$MOD/all/local-coding-agents" | sed -n 's/^\([0-9.]*\)\.lua$/\1/p' | sort -V | tail -1)"
for v in "${pending[@]}"; do
    [[ "$v" == "$default" ]] && { log "ERROR: $v is the newest (default) version; refusing"; exit 2; }
done

# Live agent containers, as "node" lines; "IDLE" if none; "unknown" on failure.
agent_nodes(){
    local out rc nodes
    out="$(timeout 240 "$CHECK" 2>&1)"; rc=$?
    if [[ $rc == 0 ]] && grep -q '^IDLE' <<< "$out"; then echo IDLE; return; fi
    nodes="$(sed -n 's/^  \([A-Za-z0-9_-]*\): [0-9]* Apptainer runtime parent.*/\1/p' <<< "$out" | sort -u)"
    [[ -n "$nodes" ]] && echo "$nodes" || echo unknown
}

# Number of processes running version $1's launchers on the given nodes, or "unknown".
count_version(){
    local v="$1"; shift
    local pat n c total=0
    # Launchers live in <harness>-local/<version>/ since 1.1, and in
    # local-coding-agents/<version>/ for the single-module 1.0.
    pat="/software/([a-z]*-local|local-coding-agents)/${v//./[.]}/"     # [.] so grep does not match its own arguments
    for n in "$@"; do
        c="$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 "$n" \
             "ps -eo args | grep -cE -- '$pat'; true" 2>/dev/null)" || { echo unknown; return; }
        [[ "$c" =~ ^[0-9]+$ ]] || { echo unknown; return; }
        total=$((total + c))
    done
    echo "$total"
}

counts(){   # prints "<version> <count>" for each pending version
    local nodes v
    nodes="$(agent_nodes)"
    for v in "${pending[@]}"; do
        case "$nodes" in
            IDLE)    echo "$v 0" ;;
            unknown) echo "$v unknown" ;;
            *)       echo "$v $(count_version "$v" $nodes)" ;;
        esac
    done
}

retire(){
    local v="$1" dest name mf path target before
    dest="$DEST/retired-$v-$(date +%F)"
    log "$v unused; moving it to $dest"
    mkdir -p "$dest" || { log "ERROR: cannot create $dest"; return 1; }
    for name in "${NAMES[@]}"; do
        if [[ "$name" == local-coding-agents ]]; then mf="$v.lua"; else mf=".$v.lua"; fi
        for path in "$SW/$name/$v" "$MOD/all/$name/$mf" "$MOD/devel/$name/$mf"; do
            [[ -e "$path" || -L "$path" ]] || continue
            target="$dest${path#/apps/software/system}"
            mkdir -p "$(dirname "$target")" && mv -- "$path" "$target" \
                && log "moved $path" || { log "ERROR: could not move $path"; return 1; }
        done
    done
    # update-cache.sh exits 1 from its final chmod (cache files owned by
    # others) even when the cache was rewritten, so check the file instead.
    before="$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)"
    bash -lc "$CACHE_UPDATE" >> "$LOG" 2>&1
    if [[ "$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)" -gt "$before" ]]; then
        log "Lmod cache refreshed"
    else
        log "WARNING: Lmod cache was not rewritten; run $CACHE_UPDATE"
    fi
    log "$v retired; restore by moving $dest/software and $dest/modules back under /apps/software/system"
}

if [[ "$DRY_RUN" == 1 ]]; then
    log "DRY RUN (default stays $default): $(counts | paste -sd' ') -- versions with 0 would be retired"
    exit 0
fi

log "=== waiting to retire: ${pending[*]} (default stays $default; poll ${INTERVAL}s, give up after ${DEADLINE_MIN}m) ==="
end=$(( $(date +%s) + DEADLINE_MIN * 60 ))
last=""
while [[ ${#pending[@]} -gt 0 ]]; do
    if (( $(date +%s) >= end )); then log "DEADLINE reached; NOT retired: ${pending[*]}"; exit 3; fi
    first="$(counts)"
    free=()
    while read -r v n; do
        [[ "$n" == 0 ]] && free+=("$v")
    done <<< "$first"
    if [[ ${#free[@]} -gt 0 ]]; then
        sleep 30                       # re-check to narrow the race with a starting session
        while read -r v n; do
            if [[ "$n" == 0 && " ${free[*]} " == *" $v "* ]]; then
                retire "$v" || exit 2
                pending=("${pending[@]/$v}"); pending=(${pending[@]})
            fi
        done <<< "$(counts)"
    fi
    [[ ${#pending[@]} -gt 0 ]] || break
    status="$(counts | paste -sd' ')"
    [[ "$status" != "$last" ]] && log "still in use (version count): $status"
    last="$status"
    sleep "$INTERVAL"
done
log "=== done ==="
