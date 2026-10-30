---
name: ycrc-debugging
description: Use when code, a script, a test, or a pipeline fails or behaves unexpectedly and the cause is not yet known, before writing a fix. For Slurm jobs that are pending, failed, OOM-killed, or timed out, use ycrc-job-troubleshooting.
---

# Debugging

Find the cause before changing code. A fix written from a guess often hides the real problem.

1. **Reproduce** the failure where feasible, with the smallest input and command that show it. Keep reproduction light: anything substantial runs as a Slurm job (see `ycrc-slurm`).
2. **Read the evidence**: the full error message and traceback, logs, exit codes, and the exact command, inputs, versions, and environment used. Do not stop at the last line of a traceback.
3. **Identify the likely cause**, and check it: compare a working and a failing case, inspect intermediate values, or test one hypothesis at a time. Say what the evidence shows and what remains a guess.
4. **Make a targeted correction** at the cause. Avoid unrelated rewrites, broad `try`/`except` blocks that hide the error, or loosening checks just so the code runs.
5. **Verify**: rerun the reproduction and any relevant tests, and confirm the original symptom is gone and nothing nearby broke. Report what was verified and what was not.

If a fix does not work, return to the evidence instead of layering further changes on top.

## On Bouchet

### In the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`)

- The agent's own allocation is small, so keep reproduction light: anything substantial runs as a Slurm job (see `ycrc-slurm`).

## Route specialized problems

- Slurm states, pending reasons, OOM, timeouts, and resource efficiency: `ycrc-job-troubleshooting`.
- GPU memory, CUDA, and GPU utilization: `ycrc-gpu`. MPI launches and ranks: `ycrc-mpi`.
- Modules, Conda, and R environment problems: `ycrc-modules`, `ycrc-conda`, `ycrc-r`.
- When a bug changes research results, also follow `ycrc-research-analysis`.
