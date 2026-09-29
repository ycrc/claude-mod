---
name: bouchet-mpi
description: Use for MPI and mpi4py on YCRC Bouchet, including MPI ranks/tasks, multi-node jobs, the mpi/scavenge_mpi partitions, whole-node suitability, hybrid MPI+threads, module/toolchain compatibility, and container MPI.
---

# Bouchet MPI workflows

MPI is for communicating parallel processes. Do not infer that a workload needs MPI merely because it uses many CPUs or invokes `mpirun`.

## Decide whether MPI is actually needed

Before designing an MPI job:

- Determine whether the application is genuinely MPI-enabled and whether ranks communicate.
- For independent tasks, prefer `bouchet-dsq-arrays`.
- For one multithreaded process, use `--cpus-per-task` and `bouchet-parallel`.
- YCRC's mpi4py guidance describes MPI as a comparatively advanced/last-resort approach when work cannot be restructured into simpler independent parallelism.

## Slurm mapping

MPI workers/ranks map to Slurm tasks:

- `--ntasks` / `-n` = number of MPI ranks/tasks.
- `--cpus-per-task` = CPUs/threads available to each rank.
- `--nodes` and `--ntasks-per-node` control multi-node placement when needed.

For four single-CPU ranks, the conceptual request is:

```bash
--ntasks=4
--cpus-per-task=1
```

Do not use `-n` as a synonym for total CPUs.

For hybrid MPI + threads, request multiple tasks and multiple CPUs per task, and configure the application's thread count to match. Use `bouchet-parallel` for the general task/thread distinction.

## The dedicated `mpi` partition is special

Bouchet's `mpi` partition allocates **full, identical nodes** and is reserved for tightly coupled MPI-enabled applications that:

- span multiple nodes; and
- need exclusive/whole nodes or are sensitive to node sharing/hardware differences.

Most appropriate jobs use all cores on each allocated node, though YCRC documents limited exceptions for tightly coupled workloads constrained by memory/load-balancing/core-count requirements.

**Using `mpirun` does not by itself justify the `mpi` partition.** MPI jobs that do not require exclusive nodes should use ordinary suitable partitions. Small/single-core jobs submitted to `mpi` may be cancelled without warning.

Bouchet's current YCRC documentation describes the `mpi` nodes as 64-core dual Emerald Rapids Platinum 8562Y+ systems with about 487 GiB usable RAM. Treat hardware as documentation-derived, not live availability; query Slurm for current state.

## `scavenge_mpi`

YCRC also documents `scavenge_mpi` for the same class of MPI workload at lower priority, subject to preemption. Route preemption/checkpoint/requeue decisions through `bouchet-scavenge`; do not assume every MPI application can safely resume after preemption.

## Compilation and modules

- Keep compiler/MPI/application toolchains compatible. Do not mix arbitrary MPI implementations across build and runtime.
- YCRC documents a Bouchet `devel` node matching the MPI generation for optimized compilation, selectable with:

```bash
--partition=devel --constraint=cpugen:emeraldrapids
```

- Discover current module versions rather than hard-coding old examples.

## mpi4py

- Prefer YCRC module-based OpenMPI/Python/mpi4py software for cluster-aware MPI.
- YCRC warns that `mpi4py` installed via Conda is unaware of cluster infrastructure and will likely work only on a single compute node.
- If a user needs a Conda mpi4py environment across multiple nodes, direct them to YCRC at `research.computing@yale.edu` rather than inventing a workaround.

## Apptainer + MPI

YCRC notes that MPI inside Apptainer requires the MPI version inside the container to be compatible with the cluster MPI. Route container mechanics to `bouchet-apptainer`; do not assume arbitrary container MPI binaries will work across nodes.

For YCRC-derived detail, read `references/mpi-ycrc.md`.
