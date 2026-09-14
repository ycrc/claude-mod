#!/usr/bin/env bash
set -euo pipefail

# Example interactive build allocation on Bouchet:
# salloc -p devel --mem=20G -t 0-4

cd ~/project/bouchet-coding-agents
mkdir -p ~/scratch/bouchet-coding-agents
outD=~/scratch/bouchet-coding-agents

apptainer build --fakeroot --force "$outD/coding-agents.sif" coding-agents.def \
  2>&1 | tee "$outD/build.log"
