#!/usr/bin/env bash
# Regenerate eb/coding-agents-site.tar.gz (the host-visible policy, skills and
# subagents each harness module installs under share/agents) from AGENTS.md
# and etc/agents/. Run after editing either, then re-inject checksums.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/agents"
cp -p AGENTS.md "$stage/agents/"
cp -rp etc/agents/skills etc/agents/subagents etc/agents/pi-subagents "$stage/agents/"
tar -czf eb/coding-agents-site.tar.gz -C "$stage" agents
tar -tzf eb/coding-agents-site.tar.gz | wc -l | xargs echo "entries:"
