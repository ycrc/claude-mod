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
- A partition may exist without being available to the current user. Recommending a partition is fine, but before actually submitting to any `priority_*` partition, confirm that the current user is entitled to use it. Prefer a non-submitting validation such as `sbatch --test-only` with the intended partition/account/resource request when practical; otherwise clearly state that access is unverified.
- `admintest` is never an allowed target for this normal-user coding-agent deployment. Do not recommend it and do not submit jobs to it.

For supporting detail, read `references/slurm-resources.md`.
