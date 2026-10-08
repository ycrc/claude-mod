---
claude-args: --bind ~/scratch/test-bind
setup: mkdir -p ~/scratch/test-bind && touch ~/scratch/test-bind/myfile.txt
cleanup: rm -rf ~/scratch/test-bind
---

List the contents of test-bind