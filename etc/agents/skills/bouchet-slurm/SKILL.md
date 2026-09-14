---
name: bouchet-slurm
description: Use for Slurm jobs, sbatch/srun/salloc, resource requests, partitions, CPU/memory/walltime/GPU requests, and durable batch workflows on YCRC Bouchet.
---

# Bouchet Slurm

- Computational work belongs in Slurm jobs/allocations, not on login or transfer nodes.
- Match CPU, memory, GPU, and walltime requests to the workload.
- Prefer durable `sbatch` scripts for longer-running work.
- `sbatch` and `srun` are intentionally permitted by this deployment. Jobs they launch run as normal user Slurm jobs outside the interactive coding-agent Apptainer filesystem sandbox.
- Do not assume paths visible only inside the interactive container will exist in a submitted job.
- Do not kill or signal another user's jobs or processes.
- Do not assume that the partition literally named `gpu` contains all GPU resources. When asked what GPU partitions or GPU types exist, inspect all partitions/nodes (for example with `sinfo -h -o "%P %G %N"` or `sinfo -N -h -o "%N %P %G"`) rather than restricting discovery with `sinfo -p gpu`.
- A partition may exist without being available to the current user. For `priority_*`, do not merely check entitlement: Priority Tier is paid. Route to `bouchet-priority` and obtain explicit user confirmation before actually submitting, resubmitting, launching an interactive allocation, or moving a job into Priority Tier.
- `admintest` is never an allowed target for this normal-user coding-agent deployment. Do not recommend it and do not submit jobs to it.
- Treat interactive-vs-batch suitability as a **partition-policy question**, not something inferable from the partition name. On Bouchet, use `devel` for CPU development/debugging and `gpu_devel` for GPU development/debugging by default. Do not call a production partition “batch-only” unless current YCRC documentation/policy says so. Priority Tier documentation explicitly permits interactive jobs on Priority Tier partitions for entitled users.
- For shell-style interactive allocations, use either `salloc <resources>` or `srun <resources> --pty bash -i`; do not use `salloc --pty`.

## Route specialized Slurm questions to the focused skills

- For tasks vs. CPUs, threading, multiprocessing, MPI, hybrid MPI+threads, GNU Parallel, or multi-node CPU layout, use `bouchet-parallel`.
- For pending jobs, failed/cancelled jobs, OOM/timeout diagnosis, resource efficiency, quotas, submission-rate failures, or batch-vs-interactive discrepancies, use `bouchet-job-troubleshooting`.
- For large independent batches and job arrays, use `bouchet-dsq-arrays`.
- For GPU sizing, GPU memory, GPU types, CUDA, Jobstats GPU utilization, and multi-GPU layouts, use `bouchet-gpu`.
- For `priority`, `priority_gpu`, `priority_mpi`, paid Priority Tier credits, `prio_` accounts, or Priority Tier costs/usage, use `bouchet-priority`.
- For `scavenge`, `scavenge_gpu`, preemption, requeue/checkpoint decisions, or opportunistic capacity, use `bouchet-scavenge`.

Keep this skill as the general Slurm entry point; do not invent detailed parallel or failure-remediation rules when a focused Bouchet skill applies.

For supporting detail, read `references/slurm-resources.md`.
