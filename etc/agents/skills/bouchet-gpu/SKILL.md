---
name: bouchet-gpu
description: Use for GPU jobs, Jobstats, GPU utilization, low-utilization diagnosis, GPU resource requests, CUDA/module troubleshooting, and YCRC GPU enforcement on Bouchet.
---

# Bouchet GPU workflows

- YCRC Jobstats documentation states that, as of 2026, GPU jobs below 10% GPU utilization are terminated.
- Diagnose low utilization rather than evading enforcement: verify GPU visibility/configuration, CUDA/modules/application settings, preprocessing placement, GPU count, and whether the workload needs a GPU at all.
- Do not create fake GPU activity, dummy kernels, busy loops, sleeps, or other behavior intended to retain an idle GPU allocation.
- `sleep` remains legitimate for ordinary polling/backoff/coordination when it is not being used to evade resource enforcement.
- Use `jobstats JOBID` when appropriate to inspect utilization.

For supporting detail and policy context, read `references/gpu-jobstats-policy.md`.
