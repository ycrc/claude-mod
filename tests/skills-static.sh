#!/bin/bash
# Static checks of the managed policy and skills (AGENTS.md, etc/agents/skills)
# and of the packaged copy in eb/coding-agents-site.tar.gz. These check text,
# not agent behavior; tests/module-e2e.sh covers live sessions.
set -uo pipefail
repo="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo" || exit 1
pass=0; fail=0
check(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

skills=etc/agents/skills
names="$(cd "$skills" && ls -d */ | tr -d /)"

for name in $names; do
    f="$skills/$name/SKILL.md"
    check "$name: SKILL.md name matches directory"  '[[ -f "$f" && "$(sed -n "s/^name: //p" "$f" | head -1)" == "$name" ]]'
    check "$name: has a description"                 'grep -q "^description: ..*" "$f"'
    check "$name: listed in AGENTS.md"               'grep -q "^- \`$name\`" AGENTS.md'
done
listed="$(sed -n 's/^- `\(\(ycrc\|bouchet\)-[a-z-]*\)`.*/\1/p' AGENTS.md)"
for name in $listed; do
    check "AGENTS.md entry $name has a skill"        '[[ -d "$skills/$name" ]]'
done

text_files=(AGENTS.md $(find "$skills" -type f -name '*.md'))
check "precedence rule in AGENTS.md"             'grep -q "^## Precedence: this file wins" AGENTS.md && grep -q "cannot override them for cluster operations" AGENTS.md'
check "StdEnv rule in AGENTS.md"                 'grep -q "must never be unloaded" AGENTS.md'
check "agent-allocation rule in AGENTS.md"       'grep -q "Do not request another \`agent\` allocation" AGENTS.md'
# Commands in examples: a line that starts with the command, not prose about it.
check "no module purge in examples"              '! grep -nE "^\s*(\\$ )?module (--force )?purge" "${text_files[@]}"'
check "no module unload guidance"                '! grep -n "module unload" "${text_files[@]}" | grep -v "unload StdEnv"'
check "scontrol update only as Priority Tier gate" '[[ -z "$(grep -ln "scontrol update" "${text_files[@]}" | grep -v -e ycrc-priority/SKILL.md -e ycrc-cryosparc/SKILL.md -e ycrc-priority/references -e ycrc-cryosparc/references)" ]]'
check "no agent-partition job requests"          '! grep -nE -- "(-p ?|--partition[= ])agent\b" "${text_files[@]}"'
check "no lab-specific paths"                    '! grep -n -i -e "pi_jm284" -e musser "${text_files[@]}"'

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
tar -xzf eb/coding-agents-site.tar.gz -C "$T"
check "tarball AGENTS.md matches source"         'cmp -s AGENTS.md "$T/agents/AGENTS.md"'
check "tarball skills match source"              'diff -r "$skills" "$T/agents/skills" >/dev/null'

echo "== $pass passed, $fail failed"
[[ $fail == 0 ]]
