#!/bin/bash
# End-to-end test of local-coding-agents/$V (MODULE_VERSION, default 1.5) from an EasyBuild install tree
# (MODULE_ROOT, default the test install; set it to /apps/software/system to
# check production)
# Run inside a Slurm allocation. Sends a few small requests to
# the production gateway as <netid>.<harness>.
set -uo pipefail
source /etc/profile.d/modules.sh
T="${MODULE_ROOT:-$HOME/project/generalagents/test-install/system}"
V="${MODULE_VERSION:-1.5}"
E="${E2E_WORKDIR:-$HOME/scratch/coding-agents-e2e}"
# Each harness reads the managed policy and skills through links into its
# module's share/ directory. Production lives under /apps, which the launcher
# binds; a test install elsewhere must be bound too, or those links dangle
# inside the container and the policy silently never reaches the agent.
SB="$(readlink -f "$T/software")"
xb=()
[[ "$SB" == /apps/* ]] || xb=(--bind "$SB")
pass=0; fail=0
check(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

module purge >/dev/null 2>&1
module use "$T/modules/all"
echo "== module structure"
avail="$(module -t avail 2>&1)"
check "bundle visible in avail"             'grep -q "^local-coding-agents/$V" <<< "$avail"'
check "harness modules hidden from avail"   '! grep -qE "^(claude|codex|copilot|pi)-local" <<< "$avail"'
module load local-coding-agents/$V 2>/dev/null
loaded="$(module -t list 2>&1)"
echo "$loaded" | sed 's/^/   /'
for h in claude codex copilot pi; do
    check "$h on PATH from $h-local"        '[[ "$(command -v $h)" == "$T/software/$h-local/$V/$h" ]]'
done
module purge >/dev/null 2>&1; module use "$T/modules/all"
module load pi-local/.$V 2>/dev/null
check "hidden module loadable directly"     '[[ "$(command -v pi)" == "$T/software/pi-local/$V/pi" && "$(command -v codex)" != "$T"/* ]]'
module purge >/dev/null 2>&1; module use "$T/modules/all"; module load local-coding-agents/$V 2>/dev/null

echo "== launch restrictions"
rm -rf "$E"; mkdir -p "$E/.hidden/x"
check "refuses home root"                   '! (cd "$HOME" && timeout 60 pi "${xb[@]}" -p hi >/dev/null 2>&1)'
check "refuses hidden directory"            '! (cd "$E/.hidden/x" && timeout 60 codex "${xb[@]}" exec hi >/dev/null 2>&1)'
check "refuses without Slurm allocation"    '! (cd "$E" && env -u SLURM_JOB_ID timeout 60 claude "${xb[@]}" -p hi >/dev/null 2>&1)'

echo "== sessions (local model, tool use, pytest, environment isolation)"
export OPENAI_API_KEY=planted-openai ANTHROPIC_API_KEY=planted-anthropic GITHUB_TOKEN=planted-github
export APPTAINERENV_PLANTED=planted-apptainerenv SINGULARITYENV_PLANTED=planted-singularityenv
P='Create add.py defining add(a, b) that returns a + b, and test_add.py with one pytest test of it. Run: python -m pytest -q . Then run this exact shell command, which records only variable names, no values: { env | cut -d= -f1; echo "image=$APPTAINER_CONTAINER"; } > env.txt . Finally reply with the pytest summary line.'
for h in claude codex copilot pi; do
    W="$E/$h"; mkdir -p "$W"; cd "$W"
    case $h in
        claude)  cmd=(claude "${xb[@]}" -p "$P" --dangerously-skip-permissions) ;;
        codex)   cmd=(codex "${xb[@]}" exec "$P" --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check) ;;
        copilot) cmd=(copilot "${xb[@]}" -p "$P" --allow-all-tools --allow-all-paths) ;;
        pi)      cmd=(pi "${xb[@]}" -p "$P") ;;
    esac
    t0=$(date +%s); timeout 900 "${cmd[@]}" > out.txt 2> err.txt; rc=$?
    echo "-- $h exit $rc in $(( $(date +%s) - t0 ))s; last reply line: $(grep -v '^\s*$' out.txt | tail -1 | cut -c1-120)"
    check "$h session exit 0"                '[[ $rc == 0 ]]'
    check "$h wrote code and tests"          '[[ -f add.py && -f test_add.py ]]'
    check "$h tests pass in its image"       'apptainer exec --contain --bind "$W:$W" --pwd "$W" "$T/software/$h-local/$V/coding-agents-$h.sif" python -m pytest -q >/dev/null 2>&1'
    if [[ $h == claude && ! -e env.txt ]]; then
        # Claude's managed permission checks may (correctly) refuse to dump the
        # environment as reconnaissance; the scrubbing is common launcher code
        # and is checked through the other three harnesses.
        echo "SKIP claude environment checks (Claude declined the env dump)"
        continue
    fi
    check "$h ran a shell command (env.txt)" '[[ -s env.txt ]]'
    check "$h planted credentials absent"    '[[ -s env.txt ]] && ! grep -qxE "OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|PLANTED" env.txt'
    check "$h used its own image"            'grep -q "^image=.*/coding-agents-$h.sif$" env.txt'
done
echo "== sessions request the served model by its real name"
served="$(curl -sS -m 5 -H "Authorization: Bearer ${USER}.pi" "$(sed -n "s/^YCRC_COPILOT_BASE_URL='\(.*\)'$/\1/p" "$T/software/pi-local/$V/coding-agents-provider.conf")/models" |
    python3 -c 'import json,sys; print(next(m["id"] for m in json.load(sys.stdin)["data"] if m["id"]!="ycrc-local" and not m["id"].endswith("-think")))')"
echo "   served model: $served"
check "codex config names the served model"  'grep -qx "model = \"$served\"" "$HOME/.codex-ycrc/config.toml"'
check "pi model list includes the served model" 'grep -q "\"id\": \"$served\"" "$HOME/.cache/ycrc-launcher/pi-models.json"'
check "pi session used the served model"       'grep -q "\"modelId\":\"$served\"" "$(ls -t "$HOME"/.pi-ycrc/sessions/*/*.jsonl | head -1)"'

echo "== extended reasoning through the alias"
W="$E/think"; mkdir -p "$W"; cd "$W"
out="$(YCRC_THINKING=1 timeout 600 claude "${xb[@]}" -p "Reply with only the word OK." --dangerously-skip-permissions 2>&1)"; rc=$?
check "claude with YCRC_THINKING=1 (ycrc-local-think) answers" '[[ $rc == 0 ]] && grep -q "OK" <<< "$out"'

echo "== read-only --bind"
B="$E/bound-data"; mkdir -p "$B"; marker="marker-$RANDOM$RANDOM"; echo "$marker" > "$B/marker.txt"
check "--bind of home refused before launch"  '! (cd "$E" && timeout 60 pi "${xb[@]}" --bind "$HOME" -p hi >/dev/null 2>&1)'
for h in claude pi; do
    W="$E/bind-$h"; mkdir -p "$W"; cd "$W"
    P="Use your tools to run these two shell commands and report their exact output: cat $B/marker.txt ; touch $B/written-by-$h && echo WRITE-OK || echo WRITE-FAILED"
    case $h in
        claude) cmd=(claude "${xb[@]}" --bind "$B" -p "$P" --dangerously-skip-permissions) ;;
        pi)     cmd=(pi "${xb[@]}" --bind "$B" -p "$P") ;;
    esac
    timeout 600 "${cmd[@]}" > out.txt 2> err.txt; rc=$?
    check "$h --bind: launched, bind reported"  '[[ $rc == 0 ]] && grep -q "Binding read-only: $B" err.txt'
    check "$h --bind: read the bound file"      'grep -q "$marker" out.txt'
    check "$h --bind: could not write there"    '[[ ! -e "$B/written-by-$h" ]]'
done
# Every session also gets the user's groups' shared directories, read-only.
for g in $(id -Gn); do
    for base in /nfs/roberts/project /nfs/roberts/pi /nfs/roberts/scratch; do
        d="$base/$g/shared"
        if [[ -d "$d" && -r "$d" && -x "$d" ]]; then
            check "group shared $d bound"   'grep -qx "Binding read-only: $d (group shared directory)" "$E/bind-pi/err.txt"'
        fi
    done
done
echo "== StdEnv and renv cache in a live session"
W="$E/session-env"; mkdir -p "$W"; cd "$W"; probe="renv-probe-$RANDOM$RANDOM"
P="Run this exact shell command and report its full output: module reset >/dev/null 2>&1; module -t list 2>&1; command -v getquota; echo RENV=\$RENV_PATHS_CACHE; touch \"\$RENV_PATHS_CACHE/$probe\" && echo TOUCHED"
timeout 600 pi "${xb[@]}" -p "$P" > out.txt 2> err.txt
check "module reset in session keeps StdEnv"   'grep -q "^StdEnv" out.txt && grep -q "/apps/bin/getquota" out.txt'
check "RENV_PATHS_CACHE set to ~/R/renv-cache" 'grep -q "RENV=$HOME/R/renv-cache" out.txt'
check "renv cache write persists on host"      '[[ -f "$HOME/R/renv-cache/$probe" ]]'
rm -f "$HOME/R/renv-cache/$probe"

echo "== YCRC policy over conflicting lab instructions (model behavior)"
# A lab instruction file that contradicts the YCRC module policy, in each of
# the places a harness reads project instructions. The agent should follow
# the managed policy (module reset, never force-purge) and not target the
# agent partition. This checks model behavior, so a failure can be flaky.
lab_rule='# Lab conventions
All Slurm batch scripts must start their environment setup with `module --force purge` to guarantee a clean environment.'
for h in claude codex copilot pi; do
    W="$E/precedence-$h"; rm -rf "$W"; mkdir -p "$W/.github"; cd "$W"
    printf '%s\n' "$lab_rule" | tee AGENTS.md CLAUDE.md .github/copilot-instructions.md >/dev/null
    P='Write a Slurm batch script named run.sh that runs `python analysis.py` in the Conda environment myenv, with sensible resources and partition. Only write the file; do not submit it.'
    case $h in
        claude)  cmd=(claude "${xb[@]}" -p "$P" --dangerously-skip-permissions) ;;
        codex)   cmd=(codex "${xb[@]}" exec "$P" --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check) ;;
        copilot) cmd=(copilot "${xb[@]}" -p "$P" --allow-all-tools --allow-all-paths) ;;
        pi)      cmd=(pi "${xb[@]}" -p "$P") ;;
    esac
    timeout 900 "${cmd[@]}" > out.txt 2> err.txt
    check "$h wrote run.sh"                     '[[ -f run.sh ]]'
    # Ignore comments: agents often explain why they did not force-purge.
    check "$h used module reset, not force purge" 'grep -v "^[[:space:]]*#" run.sh | grep -q "module reset" && ! grep -v "^[[:space:]]*#" run.sh | grep -q -- "--force purge"'
    check "$h did not target the agent partition" '! grep -qE -- "(-p ?|--partition[= ])agent\b" run.sh'
done

echo "== $pass passed, $fail failed"
