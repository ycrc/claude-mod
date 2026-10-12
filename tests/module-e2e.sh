#!/bin/bash
# End-to-end test of local-coding-agents/1.1 from an EasyBuild install tree
# (MODULE_ROOT, default the test install; set it to /apps/software/system to
# check production)
# Run inside a Slurm allocation. Sends a few small requests to
# the production gateway as <netid>.<harness>.
set -uo pipefail
source /etc/profile.d/modules.sh
T="${MODULE_ROOT:-$HOME/project/generalagents/test-install/system}"
E="${E2E_WORKDIR:-$HOME/scratch/coding-agents-e2e}"
pass=0; fail=0
check(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

module purge >/dev/null 2>&1
module use "$T/modules/all"
echo "== module structure"
avail="$(module -t avail 2>&1)"
check "bundle visible in avail"             'grep -q "^local-coding-agents/1.1" <<< "$avail"'
check "harness modules hidden from avail"   '! grep -qE "^(claude|codex|copilot|pi)-local" <<< "$avail"'
module load local-coding-agents/1.1 2>/dev/null
loaded="$(module -t list 2>&1)"
echo "$loaded" | sed 's/^/   /'
for h in claude codex copilot pi; do
    check "$h on PATH from $h-local"        '[[ "$(command -v $h)" == "$T/software/$h-local/1.1/$h" ]]'
done
module purge >/dev/null 2>&1; module use "$T/modules/all"
module load pi-local/.1.1 2>/dev/null
check "hidden module loadable directly"     '[[ "$(command -v pi)" == "$T/software/pi-local/1.1/pi" && "$(command -v codex)" != "$T"/* ]]'
module purge >/dev/null 2>&1; module use "$T/modules/all"; module load local-coding-agents/1.1 2>/dev/null

echo "== launch restrictions"
rm -rf "$E"; mkdir -p "$E/.hidden/x"
check "refuses home root"                   '! (cd "$HOME" && timeout 60 pi -p hi >/dev/null 2>&1)'
check "refuses hidden directory"            '! (cd "$E/.hidden/x" && timeout 60 codex exec hi >/dev/null 2>&1)'
check "refuses without Slurm allocation"    '! (cd "$E" && env -u SLURM_JOB_ID timeout 60 claude -p hi >/dev/null 2>&1)'

echo "== sessions (local model, tool use, pytest, environment isolation)"
export OPENAI_API_KEY=planted-openai ANTHROPIC_API_KEY=planted-anthropic GITHUB_TOKEN=planted-github
export APPTAINERENV_PLANTED=planted-apptainerenv SINGULARITYENV_PLANTED=planted-singularityenv
P='Create add.py defining add(a, b) that returns a + b, and test_add.py with one pytest test of it. Run: python -m pytest -q . Then run this exact shell command, which records only variable names, no values: { env | cut -d= -f1; echo "image=$APPTAINER_CONTAINER"; } > env.txt . Finally reply with the pytest summary line.'
for h in claude codex copilot pi; do
    W="$E/$h"; mkdir -p "$W"; cd "$W"
    case $h in
        claude)  cmd=(claude -p "$P" --dangerously-skip-permissions) ;;
        codex)   cmd=(codex exec "$P" --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check) ;;
        copilot) cmd=(copilot -p "$P" --allow-all-tools --allow-all-paths) ;;
        pi)      cmd=(pi -p "$P") ;;
    esac
    t0=$(date +%s); timeout 900 "${cmd[@]}" > out.txt 2> err.txt; rc=$?
    echo "-- $h exit $rc in $(( $(date +%s) - t0 ))s; last reply line: $(grep -v '^\s*$' out.txt | tail -1 | cut -c1-120)"
    check "$h session exit 0"                '[[ $rc == 0 ]]'
    check "$h wrote code and tests"          '[[ -f add.py && -f test_add.py ]]'
    check "$h tests pass in its image"       'apptainer exec --contain --bind "$W:$W" --pwd "$W" "$T/software/$h-local/1.1/coding-agents-$h.sif" python -m pytest -q >/dev/null 2>&1'
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
echo "== extended reasoning through the alias"
W="$E/think"; mkdir -p "$W"; cd "$W"
out="$(YCRC_THINKING=1 timeout 600 claude -p "Reply with only the word OK." --dangerously-skip-permissions 2>&1)"; rc=$?
check "claude with YCRC_THINKING=1 (ycrc-local-think) answers" '[[ $rc == 0 ]] && grep -q "OK" <<< "$out"'
echo "== $pass passed, $fail failed"
