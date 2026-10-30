#!/bin/sh
# Checks shared by every coding-agent image. Each harness image's %test runs
# this first, then checks its own client.
set -eu

command -v ps
command -v fd
command -v rg
command -v bwrap
command -v make
command -v git
command -v node
command -v python
python -m pytest --version
test -f /etc/agents/AGENTS.md
# Skills are not baked into the images (see the launcher).
test ! -e /etc/agents/skills
locale -a | grep -qi "^en_US.utf8$"
getent passwd slurm
test -e /usr/lib64/libmunge.so.2
