#!/usr/bin/env bash
# Replace etc/agents/skills -- the fallback copy of YCRC's skills bundled with
# the module -- with the Bouchet build of the central skills repository
# (github.com/ycrc/yale-ycrc-skills), and record which commit it came from.
# Sessions normally use the live shared checkout instead (see the launcher);
# edit skills in that repository, not here. Then run eb/make-site-tarball.sh.
#
# Usage: eb/sync-skills.sh /path/to/yale-ycrc-skills
set -euo pipefail
src="${1:?usage: $0 /path/to/yale-ycrc-skills}"
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
python3 "$src/tools/build.py" --check
[[ -z "$(git -C "$src" status --porcelain -- skills build CLUSTERS tools)" ]] ||
    { echo "$src has uncommitted skill changes; commit them first" >&2; exit 1; }
rsync -a --delete "$src/build/bouchet/skills/" etc/agents/skills/
printf '%s %s\n' "$(git -C "$src" rev-parse HEAD)" "$(git -C "$src" log -1 --format=%cs)" > etc/agents/SKILLS-SOURCE
echo "etc/agents/skills <- $src/build/bouchet/skills ($(cut -c1-12 etc/agents/SKILLS-SOURCE))"
