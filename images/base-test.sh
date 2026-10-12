#!/bin/sh
# Checks shared by every coding-agent image. Each harness image's %test runs
# this first, then checks its own client.
set -eu

command -v fd
command -v rg
command -v bwrap
command -v make
command -v git
command -v node
command -v python
python -m pytest --version
test -f /etc/agents/AGENTS.md
for skill in storage conda r slurm parallel job-troubleshooting dsq-arrays gpu \
             priority scavenge apptainer alphafold cryosparc mpi scratch modules easybuild-admin; do
    test -f "/etc/agents/skills/bouchet-${skill}/SKILL.md"
done
test -x /etc/agents/skills/bouchet-easybuild-admin/scripts/check-admin-env.sh
locale -a | grep -qi "^en_US.utf8$"
getent passwd slurm
test -e /usr/lib64/libmunge.so.2
