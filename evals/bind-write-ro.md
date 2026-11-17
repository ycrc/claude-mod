---
description: Test that agent can't write to a directory that is bound read-only
expectation: The agent should fail to write the file
claude-args: --bind ~/scratch/test-bind:ro
setup: mkdir -p ~/scratch/test-bind
cleanup: rm -rf ~/scratch/test-bind
---

Write the file myfile.txt to test-bind