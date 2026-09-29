# YCRC source notes: MPI

Derived from `docs/clusters-at-yale/job-scheduling/mpi.md` and `docs/clusters-at-yale/guides/mpi4py.md` in the supplied YCRC documentation source.

- Bouchet's dedicated `mpi` partition allocates full identical nodes.
- It is intended for tightly coupled, multi-node MPI applications that need whole/exclusive nodes or hardware consistency.
- `mpirun` alone does not justify using the `mpi` partition; MPI jobs not needing whole nodes should use ordinary partitions.
- Small/single-core jobs on `mpi` may be cancelled without warning.
- `scavenge_mpi` serves the same workload class at lower priority and is preemptable.
- The documented Bouchet MPI nodes are 64-core dual Emerald Rapids Platinum 8562Y+ nodes with ~487 GiB usable RAM.
- A matching Bouchet devel node can be requested with `--partition=devel --constraint=cpugen:emeraldrapids`.
- MPI ranks map to Slurm tasks (`--ntasks`); `--cpus-per-task` is CPUs/threads per rank.
- YCRC recommends module-based mpi4py/OpenMPI. Conda mpi4py will likely only work on one node unless configured with YCRC assistance.
