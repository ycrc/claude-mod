---
claude-args: --bind ~/scratch/test-bind:rw
setup: mkdir -p ~/scratch/test-bind
cleanup: rm -rf ~/scratch/test-bind
---

Write the file myfile.txt to test-bind