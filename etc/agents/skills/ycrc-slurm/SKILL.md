---
name: ycrc-slurm
description: Use for Slurm jobs, sbatch/srun/salloc, resource requests, partitions, CPU/memory/walltime/GPU requests, and durable batch workflows on YCRC clusters.
---

# YCRC Slurm

- Computational work belongs in Slurm jobs/allocations, not on login or transfer nodes.
- For short CPU development and testing, use `devel`; for GPU development, `gpu_devel` (see `ycrc-gpu`). Their per-user limits are aggregate across all of a user's jobs in the partition; check the current values (see `references/slurm-resources.md`) rather than relying on remembered numbers.
- Before suggesting or submitting to `devel` or `gpu_devel`, check the user's current jobs there (`squeue -u $USER -p devel,gpu_devel`). Open OnDemand sessions (Jupyter, RStudio, VS Code, Remote Desktop) and `salloc` often already occupy them. `gpu_devel` allows one job per user; `devel` allows 2 jobs and **4 CPUs and 60G in total across all of the user's `devel` jobs**, not per job. Add up the CPUs and memory their `devel` jobs already hold (`squeue -u $USER -p devel -o '%i %C %m %T'`) and size the new request to what is left: with a 2-CPU Jupyter session running, a new `devel` job can have at most 2 CPUs (memory defaults to a fixed amount per CPU; see `scontrol show partition devel`). The limits fail differently: a job over the job count is rejected at once (`QOSMaxSubmitJobPerUserLimit`), but a job over the CPU or memory total is accepted and stays pending (`QOSMaxCpuPerUserLimit`, `QOSMaxMemoryPerUser`) until other `devel` jobs end. If the new work would not fit, run CPU work in a standard CPU partition (this cluster's are listed below), and for GPU work either end the existing `gpu_devel` job or submit the work as a batch job to a production GPU partition (interactive GPU work has no other partition).
- Interactive jobs (Open OnDemand sessions and `salloc`) also count toward the `interactive` QOS: at most 4 running per user across all partitions. A fifth is accepted but waits (`QOSMaxJobsPerUserLimit`) until one ends; batch jobs are not affected. `squeue -u $USER -o '%i %P %q %j'` shows which of the user's jobs are interactive (QOS column); if they already have 4, suggest ending an idle session or using a batch job.
- Match CPU, memory, GPU, and walltime requests to the workload.
- Prefer durable `sbatch` scripts for longer-running work.
- Do not kill or signal another user's jobs or processes.
- Do not assume that the partition literally named `gpu` contains all GPU resources. When asked what GPU partitions or GPU types exist, inspect all partitions/nodes (for example with `sinfo -h -o "%P %G %N"` or `sinfo -N -h -o "%N %P %G"`) rather than restricting discovery with `sinfo -p gpu`.
- A partition may exist without being available to the current user. For Priority Tier partitions (`priority` and its variants), do not merely check entitlement: Priority Tier is paid. Route to `ycrc-priority` and obtain explicit user confirmation before actually submitting, resubmitting, launching an interactive allocation, or moving a job into Priority Tier.
- Interactive GPU work must use `gpu_devel`. Do not use Standard Tier production GPU partitions (this cluster's are listed below) for interactive allocations, even if changing QOS or another option makes Slurm accept the request. Scheduler acceptance does not override YCRC policy. Priority Tier is a documented paid exception for entitled users; use `ycrc-priority` and obtain confirmation before launching it.
- For shell-style interactive allocations, use either `salloc <resources>` or `srun <resources> --pty bash -i`; do not use `salloc --pty`.

## On Bouchet

- `salloc`'s default partition on Bouchet is `devel`.
- `devel` (and `gpu_devel`) default to 5G of memory per CPU.
- Standard CPU partitions: when new work would not fit in `devel`, run CPU work in `day` (or `week`).
- Standard Tier production GPU partitions include `gpu` (also `gpu_rtx6000`, `gpu_h100`, `gpu_h200`, `gpu_b200`; see `ycrc-gpu`): never use them for interactive allocations.
- Priority Tier partitions are `priority`, `priority_gpu` and `priority_mpi` (`priority_*`); route them to `ycrc-priority`. MPI partitions are `mpi`/`scavenge_mpi` (route to `ycrc-mpi`); scavenge partitions are `scavenge`/`scavenge_gpu` (route to `ycrc-scavenge`).
- Course accounts (username `courseid_netid`) can also use `education` (CPU: per user 4 jobs, 16 CPUs and 200G in total) and `education_gpu` (1 job, 1 GPU per user; RTX 5000 Ada, A5000, A40), each up to 1 day, portal sessions up to 6 hours. Prefer them for course work when they have room and the work fits; otherwise use the public partitions. Check room with `sinfo -p education,education_gpu -o '%P %C %G'`.
- For Bouchet's live `devel`/`gpu_devel` limits and partition-discovery examples, read `references/slurm-bouchet.md`.

### In the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`)

- The coding agent already runs inside its own small `agent`-partition allocation, started by the launcher and meant for coordination, editing, inspection, small tests and job submission. That allocation is for the agent, not for the user's computation. Do not request another `agent` allocation, and do not run substantial computation in the session: submit it with `sbatch` to the appropriate CPU, GPU or development partition.
- Open WebUI also runs as an Open OnDemand session and can occupy `devel`/`gpu_devel`. In Open WebUI, the `my_jobs` tool lists the user's jobs (use it in place of `squeue -u $USER -p devel,gpu_devel`) and shows the same columns as `squeue -u $USER -p devel -o '%i %C %m %T'`.
- `sbatch` and `srun` are intentionally permitted by this deployment. Jobs they launch run as normal user Slurm jobs outside the interactive coding-agent Apptainer filesystem sandbox.
- Do not assume paths visible only inside the interactive container will exist in a submitted job.
- `admintest` is reserved for administrative testing and is never an allowed target for this normal-user coding-agent deployment. Do not recommend `admintest`, and do not submit or test jobs against it.

## Route specialized Slurm questions to the focused skills

- For general tasks vs. CPUs, threading, multiprocessing, GNU Parallel, or CPU layout, use `ycrc-parallel`.
- For MPI, mpi4py, MPI ranks, multi-node MPI, dedicated MPI partitions, or hybrid MPI+threads, use `ycrc-mpi`.
- For pending jobs, failed/cancelled jobs, OOM/timeout diagnosis, resource efficiency, quotas, submission-rate failures, or batch-vs-interactive discrepancies, use `ycrc-job-troubleshooting`.
- For large independent batches and job arrays, use `ycrc-dsq-arrays`.
- For GPU sizing, GPU memory, GPU types, CUDA, Jobstats GPU utilization, and multi-GPU layouts, use `ycrc-gpu`.
- For `priority` and other Priority Tier partitions, paid Priority Tier credits, Priority Tier accounts, or Priority Tier costs/usage, use `ycrc-priority`.
- For `scavenge` and other scavenge partitions, preemption, requeue/checkpoint decisions, or opportunistic capacity, use `ycrc-scavenge`.
- For Apptainer/Singularity containers, use `ycrc-apptainer`.
- For AlphaFold workflows, use `ycrc-alphafold`.
- For CryoSPARC workflows, use `ycrc-cryosparc`.

Keep this skill as the general Slurm entry point; do not invent detailed parallel or failure-remediation rules when a focused skill applies.

For supporting detail, read `references/slurm-resources.md`.
