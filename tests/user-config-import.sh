#!/bin/bash
# Test the launcher's user configuration import (the section between the
# "user configuration import" markers in eb/coding-agents-wrapper.sh) against a
# throwaway home directory. Needs no container, module or Slurm allocation.
set -uo pipefail
repo="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

section="$T/import.sh"
sed -n '/^# --- BEGIN user configuration import ---$/,/^# --- END user configuration import ---$/p' \
    "$repo/eb/coding-agents-wrapper.sh" > "$section"
check "import section found"                '[[ -s "$section" ]]'

# A managed site tree like the one EasyBuild installs under share/agents.
site="$T/share/agents"
mkdir -p "$site/skills/bouchet-storage" "$site/subagents"
echo "SITE POLICY" > "$site/AGENTS.md"
echo site > "$site/skills/bouchet-storage/SKILL.md"
echo site > "$site/subagents/quick-task.md"

# A user's normal configuration for each harness.
H="$T/home"
mkdir -p "$H/.claude/skills/my-skill" "$H/.claude/skills/bouchet-storage" "$H/.claude/agents" \
         "$H/.claude/commands" "$H/.claude/hooks" "$H/.claude/projects" \
         "$H/.codex/prompts" "$H/.pi/agent/extensions/subagent" "$H/.pi/agent/extensions/mine" \
         "$H/.copilot/agents" "$T/elsewhere/linked-skill"
cat > "$H/.claude/settings.json" <<EOF
{"model": "opus", "apiKeyHelper": "/bin/echo key", "theme": "dark",
 "env": {"ANTHROPIC_BASE_URL": "https://api.anthropic.com", "MY_TOKEN": "x", "BASH_DEFAULT_TIMEOUT_MS": "5000"},
 "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/done.sh && $H/.claude/hooks/done.sh"}]}]}}
EOF
echo "my claude notes" > "$H/.claude/CLAUDE.md"
echo user > "$H/.claude/skills/my-skill/SKILL.md"
mkdir -p "$H/.claude/skills/synced/acct/docx" && echo account > "$H/.claude/skills/synced/acct/docx/SKILL.md"
echo user > "$H/.claude/skills/bouchet-storage/SKILL.md"
echo linked > "$T/elsewhere/linked-skill/SKILL.md"
ln -s "$T/elsewhere/linked-skill" "$H/.claude/skills/linked-skill"
echo user > "$H/.claude/agents/quick-task.md"
echo user > "$H/.claude/commands/review.md"
echo '#!/bin/sh' > "$H/.claude/hooks/done.sh"
echo secret > "$H/.claude/.credentials.json"
echo history > "$H/.claude/projects/session.jsonl"
echo "my codex rules" > "$H/.codex/AGENTS.md"
echo 'model = "gpt-5"' > "$H/.codex/config.toml"
echo user > "$H/.codex/prompts/fix.md"
echo '{"defaultProvider": "openai", "theme": "light", "packages": ["npm:x"]}' > "$H/.pi/agent/settings.json"
echo user > "$H/.pi/agent/extensions/subagent/index.ts"
echo user > "$H/.pi/agent/extensions/mine/index.ts"
echo '{"secret": 1}' > "$H/.pi/agent/auth.json"
echo user > "$H/.copilot/agents/helper.md"
mkdir -p "$H/.pi/agent/prompts"
echo user > "$H/.pi/agent/prompts/fix.md"
echo same > "$H/.pi/agent/prompts/same.md"

# A returning user: Pi already ran under the module before this feature and
# saved its own settings and a prompt, all newer than the user's originals.
mkdir -p "$H/.pi-ycrc/prompts"
touch -d '1 month ago' "$H/.pi/agent/settings.json" "$H/.pi/agent/prompts/"*
echo '{"lastChangelogVersion": "0.85.1", "theme": "dark"}' > "$H/.pi-ycrc/settings.json"
echo made-in-ycrc > "$H/.pi-ycrc/prompts/fix.md"
echo same > "$H/.pi-ycrc/prompts/same.md"

run_import(){
    local agent="$1"
    ( set -euo pipefail
      host_home="$H"; site_agents_dir="$site"; site_skills_dir="$site/skills"
      claude_config_dir="$H/.claude-ycrc"; codex_home="$H/.codex-ycrc"; pi_home="$H/.pi-ycrc"
      copilot_home="$H/.copilot-ycrc"
      mkdir -p "$claude_config_dir/skills" "$claude_config_dir/agents" "$codex_home" "$pi_home" "$copilot_home"
      # What the launcher links in after the import, so re-runs see the links.
      ln -sfn "$site/skills/bouchet-storage" "$claude_config_dir/skills/bouchet-storage"
      [[ -e "$claude_config_dir/agents/quick-task.md" ]] || ln -s "$site/subagents/quick-task.md" "$claude_config_dir/agents/quick-task.md"
      source "$section"
    )
}

for agent in claude codex pi copilot; do
    check "$agent import exits 0"           'run_import $agent 2>"$T/err.$agent"'
done
check "no warnings"                         '! grep -q Warning "$T"/err.*'

Y="$H/.claude-ycrc"
check "claude settings imported"            'jq -e ".theme == \"dark\"" "$Y/settings.json" >/dev/null'
check "claude model/apiKeyHelper dropped"   'jq -e "has(\"model\") or has(\"apiKeyHelper\") | not" "$Y/settings.json" >/dev/null'
check "claude unsafe env dropped"           'jq -e ".env == {\"BASH_DEFAULT_TIMEOUT_MS\": \"5000\"}" "$Y/settings.json" >/dev/null'
check "claude hook paths repointed"         '[[ "$(jq -r ".hooks.Stop[0].hooks[0].command" "$Y/settings.json")" == "~/.claude-ycrc/hooks/done.sh && $Y/hooks/done.sh" ]]'
check "claude settings private"             '[[ "$(stat -c %a "$Y/settings.json")" == 600 ]]'
check "CLAUDE.md, commands, hooks copied"   '[[ -f "$Y/CLAUDE.md" && -f "$Y/commands/review.md" && -f "$Y/hooks/done.sh" ]]'
check "user skill copied"                   '[[ -f "$Y/skills/my-skill/SKILL.md" && ! -L "$Y/skills/my-skill" ]]'
check "linked user skill copied as files"   '[[ -d "$Y/skills/linked-skill" && ! -L "$Y/skills/linked-skill" ]]'
check "account-synced skills not copied"   '[[ ! -e "$Y/skills/synced" ]]'
check "managed skill kept over user skill"  '[[ "$(readlink "$Y/skills/bouchet-storage")" == "$site/skills/bouchet-storage" ]]'
check "user agent replaces managed link"    '[[ -f "$Y/agents/quick-task.md" && ! -L "$Y/agents/quick-task.md" ]]'
check "credentials and history not copied"  '[[ ! -e "$Y/.credentials.json" && ! -e "$Y/projects" ]]'

check "codex prompts copied"                '[[ -f "$H/.codex-ycrc/prompts/fix.md" ]]'
check "codex config.toml not copied"        '[[ ! -e "$H/.codex-ycrc/config.toml" ]]'
for f in "$H/.codex-ycrc/AGENTS.md" "$H/.pi-ycrc/AGENTS.md"; do
    check "policy first in ${f#$H/}"        '[[ "$(head -1 "$f")" == "SITE POLICY" ]]'
done
check "codex personal rules appended"       'grep -q "my codex rules" "$H/.codex-ycrc/AGENTS.md"'
check "pi without personal rules: link"     '[[ -L "$H/.pi-ycrc/AGENTS.md" ]]'
check "copilot without personal rules: link" '[[ "$(readlink "$H/.copilot-ycrc/copilot-instructions.md")" == "$site/AGENTS.md" ]]'

P="$H/.pi-ycrc"
check "old settings merged over existing"   'jq -e ".theme == \"light\" and (has(\"defaultProvider\") or has(\"packages\") | not)" "$P/settings.json" >/dev/null'
check "harness-saved settings kept"         'jq -e ".lastChangelogVersion == \"0.85.1\"" "$P/settings.json" >/dev/null'
check "existing differing file kept"        '[[ "$(cat "$P/prompts/fix.md")" == made-in-ycrc ]]'
check "kept file reported once"             'grep -q "kept 1 existing file" "$T/err.pi"'
check "import record written"               'grep -q "$H/.pi/agent/settings.json" "$P/.ycrc-import-state"'
check "pi own extension copied"             '[[ -f "$P/extensions/mine/index.ts" ]]'
check "pi subagent extension not copied"    '[[ ! -e "$P/extensions/subagent" ]]'
check "pi auth not copied"                  '[[ ! -e "$P/auth.json" ]]'
check "copilot agent copied"                '[[ -f "$H/.copilot-ycrc/agents/helper.md" ]]'

# An unchanged original never overwrites the YCRC copy, and a deleted copy
# stays deleted; a later edit to the original is picked up.
echo '{"theme": "ycrc-edit"}' > "$Y/settings.json"; echo "ycrc edit" > "$Y/CLAUDE.md"
rm "$Y/commands/review.md"
run_import claude 2>/dev/null
check "YCRC-side edits survive relaunch"    'jq -e ".theme == \"ycrc-edit\"" "$Y/settings.json" >/dev/null && grep -q "ycrc edit" "$Y/CLAUDE.md"'
check "YCRC-side deletion respected"        '[[ ! -e "$Y/commands/review.md" ]]'
echo '{"theme": "newer"}' > "$H/.claude/settings.json"; echo "newer notes" > "$H/.claude/CLAUDE.md"
run_import claude 2>/dev/null
check "edited original picked up"           'jq -e ".theme == \"newer\"" "$Y/settings.json" >/dev/null && grep -q "newer notes" "$Y/CLAUDE.md"'
echo user-edit > "$H/.pi/agent/prompts/fix.md"
run_import pi 2>"$T/err.pi2"
check "edited original replaces kept file"  '[[ "$(cat "$P/prompts/fix.md")" == user-edit ]] && ! grep -q kept "$T/err.pi2"'

# Bad input only warns; it never stops the launch.
echo "not json" > "$H/.pi/agent/settings.json"
check "malformed settings only warn"        'run_import pi 2>"$T/err.bad" && grep -q "could not import" "$T/err.bad"'

# Opting out keeps the old behaviour: no copies, policy link only.
rm -rf "$H/.codex-ycrc"
check "opt-out exits 0"                     'YCRC_IMPORT_USER_CONFIG=0 run_import codex'
check "opt-out copies nothing"              '[[ ! -e "$H/.codex-ycrc/prompts" && -L "$H/.codex-ycrc/AGENTS.md" ]]'

echo "== $pass passed, $fail failed"
[[ $fail == 0 ]]
