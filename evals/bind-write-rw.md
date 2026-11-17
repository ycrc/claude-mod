---
description: Test that bind allows writing when using dir:rw
expectation: The agent should successfully write the file
claude-args: --bind ~/scratch/test-bind:rw
setup: mkdir -p ~/scratch/test-bind
cleanup: rm -rf ~/scratch/test-bind
---

Write the file myfile.txt to test-bind