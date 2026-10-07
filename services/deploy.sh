#!/usr/bin/env bash
# deploy.sh -- copy the inference-path services from this repository to the
# live location under /apps.
#
# Copying alone changes nothing: the running processes keep their loaded code
# until restarted. That is deliberate, so a deploy and a restart are separate
# decisions -- the gateway sits in the inference path and restarting it drops
# any request in flight.
#
# Refuses to run while anyone has a live agent session, since overwriting the
# gateway under traffic is exactly what the idle gate exists to prevent.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST="${DEST:-/apps/services/coding-agents}"
CHECK="${DEST}/bin/agents-in-use.sh"
force=0
[[ "${1:-}" == "--force" ]] && force=1

if [[ $force -eq 0 ]]; then
    if [[ -x "$CHECK" ]]; then
        echo "== checking for live agent sessions =="
        if ! timeout 240 "$CHECK" >/dev/null 2>&1; then
            echo "IN USE -- sessions are active; not deploying." >&2
            echo "Re-run when idle, or pass --force if you know why." >&2
            exit 1
        fi
        echo "  idle"
    else
        echo "WARNING: $CHECK not found; cannot verify idleness." >&2
        echo "Pass --force to deploy anyway." >&2
        exit 1
    fi
fi

mkdir -p -- "${DEST}/bin"
changed=0
for f in "$SRC"/bin/*; do
    name="$(basename -- "$f")"
    target="${DEST}/bin/${name}"
    if [[ -f "$target" ]] && cmp -s "$f" "$target"; then
        printf '  unchanged  %s\n' "$name"
    else
        install -m 0755 -- "$f" "$target"
        printf '  DEPLOYED   %s\n' "$name"
        changed=$((changed + 1))
    fi
done

if [[ -f "$SRC/PROMETHEUS-ENDPOINT.md" ]]; then
    if cmp -s "$SRC/PROMETHEUS-ENDPOINT.md" "${DEST}/PROMETHEUS-ENDPOINT.md" 2>/dev/null; then
        printf '  unchanged  PROMETHEUS-ENDPOINT.md\n'
    else
        install -m 0644 -- "$SRC/PROMETHEUS-ENDPOINT.md" "${DEST}/PROMETHEUS-ENDPOINT.md"
        printf '  DEPLOYED   PROMETHEUS-ENDPOINT.md\n'
        changed=$((changed + 1))
    fi
fi

echo
if [[ $changed -eq 0 ]]; then
    echo "Nothing changed; running services are already up to date."
    exit 0
fi

cat <<'EOF'
Files copied. The running services still have their OLD code loaded.

To pick up the change, SIGKILL them on the serving node -- the supervision
loops in webui.sh restart them within ~5s. Do NOT use SIGTERM: a clean exit
is treated as "stop", so the collector would shut down for good.

    srun --overlap --jobid=<serving job> --ntasks=1 bash -c \
      'kill -9 $(pgrep -f "[a]gent-token-proxy.py")'

Restarting the gateway drops any request in flight, so check idleness again
immediately beforehand.
EOF
