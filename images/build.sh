#!/usr/bin/env bash
# Build the coding-agent images.
#
#   images/build.sh OUTDIR                 base + all four harness images
#   images/build.sh OUTDIR codex           only the Codex image, on OUTDIR's
#                                          existing base
#   images/build.sh OUTDIR base claude     rebuild the base, then Claude
#
# Produces OUTDIR/coding-agents-<name>.sif and OUTDIR/versions.txt. Each
# harness image is the base plus one client, so a harness can be upgraded by
# rebuilding just its image; rebuild the base (and then every harness) to
# change the shared tooling. Needs a compute node with --fakeroot, e.g.
#   salloc -p day -c 8 --mem=32G -t 3:00:00
set -euo pipefail

[[ $# -ge 1 ]] || { sed -n '2,13p' "$0"; exit 2; }
out="$(mkdir -p "$1" && cd "$1" && pwd -P)"
shift
targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(base claude codex copilot pi)

# %files paths in the definitions are relative to the repository root.
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

base="$out/coding-agents-base.sif"
for t in "${targets[@]}"; do
    case "$t" in base|claude|codex|copilot|pi) ;; *) echo "unknown image: $t" >&2; exit 2 ;; esac
    if [[ "$t" != base && ! -f "$base" ]]; then
        echo "no base image at $base; build 'base' first" >&2
        exit 1
    fi
    echo "== building $t"
    args=()
    [[ "$t" == base ]] || args=(--build-arg "base=$base")
    apptainer build --fakeroot --force "${args[@]}" \
        "$out/coding-agents-$t.sif" "images/$t.def" > "$out/build-$t.log" 2>&1 \
        || { echo "build of $t failed; see $out/build-$t.log" >&2; exit 1; }
done

# Record what each image actually contains (harness versions are unpinned
# except Pi, so this is the only record of what shipped).
{
    for t in claude codex copilot pi; do
        sif="$out/coding-agents-$t.sif"
        [[ -f "$sif" ]] || continue
        case "$t" in
            claude)  v="$(apptainer exec "$sif" claude --version 2>/dev/null | head -1)" ;;
            codex)   v="$(apptainer exec "$sif" codex --version 2>/dev/null | head -1)" ;;
            copilot) v="$(apptainer exec "$sif" sh -c 'npm ls -g @github/copilot 2>/dev/null' | grep -o 'copilot@[0-9.]*')" ;;
            pi)      v="$(apptainer exec "$sif" pi --version 2>/dev/null | head -1)" ;;
        esac
        printf '%-8s %-40s %s\n' "$t" "$v" "$(sha256sum "$sif" | cut -c1-64)"
    done
    printf '%-8s %-40s %s\n' base "$(apptainer exec "$base" sh -c 'python --version; python -m pytest --version 2>&1' | paste -sd' ')" \
        "$(sha256sum "$base" | cut -c1-64)"
} 2>/dev/null | tee "$out/versions.txt"
