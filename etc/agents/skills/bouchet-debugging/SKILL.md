---
name: bouchet-debugging
description: Use when code, a script, a test, or a pipeline fails or behaves unexpectedly and the cause is not yet known, before writing a fix. For Slurm jobs that are pending, failed, OOM-killed, or timed out, use bouchet-job-troubleshooting.
---

# Debugging

Find the cause before changing code. A fix written from a guess often hides the real problem.

1. **Reproduce** the failure where feasible, with the smallest input and command that show it. Keep reproduction light: the agent's own allocation is small, so anything substantial runs as a Slurm job (see `bouchet-slurm`).
2. **Read the evidence**: the full error message and traceback, logs, exit codes, and the exact command, inputs, versions, and environment used. Do not stop at the last line of a traceback.
3. **Identify the likely cause**, and check it: compare a working and a failing case, inspect intermediate values, or test one hypothesis at a time. Say what the evidence shows and what remains a guess.
4. **Make a targeted correction** at the cause. Avoid unrelated rewrites, broad `try`/`except` blocks that hide the error, or loosening checks just so the code runs.
5. **Verify**: rerun the reproduction and any relevant tests, and confirm the original symptom is gone and nothing nearby broke. Report what was verified and what was not.

If a fix does not work, return to the evidence instead of layering further changes on top.

## Route specialized problems

- Slurm states, pending reasons, OOM, timeouts, and resource efficiency: `bouchet-job-troubleshooting`.
- GPU memory, CUDA, and GPU utilization: `bouchet-gpu`. MPI launches and ranks: `bouchet-mpi`.
- Modules, Conda, and R environment problems: `bouchet-modules`, `bouchet-conda`, `bouchet-r`.
- When a bug changes research results, also follow `bouchet-research-analysis`.
