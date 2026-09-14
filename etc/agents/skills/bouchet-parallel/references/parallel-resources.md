# Parallel CPU and Slurm resource guidance on Bouchet

Sources from the YCRC documentation used for this skill:
- `docs/clusters-at-yale/job-scheduling/resource-requests.md`
- `docs/clusters-at-yale/job-scheduling/slurm-examples.md`
- `docs/clusters-at-yale/job-scheduling/mpi.md`
- `docs/clusters-at-yale/guides/parallel.md`
- `docs/clusters-at-yale/job-scheduling/resource-usage.md`

Key YCRC rules captured here:

- `--ntasks`/`-n` represents Slurm tasks and maps naturally to MPI ranks/processes.
- `--cpus-per-task`/`-c` allocates CPUs to one task and is the correct control for ordinary non-MPI threaded applications.
- A task's CPUs remain on one node. A non-MPI application cannot span nodes merely because more CPUs were requested.
- Only hybrid MPI+threaded applications normally need both `--ntasks` and `--cpus-per-task` to increase application parallelism.
- Most applications do not automatically benefit from additional cores. Independent serial work is often better expressed with dSQ/job arrays.
- For OpenMP-style jobs, YCRC examples set `OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK`.
- GNU Parallel worker count should correspond to CPUs allocated with `--cpus-per-task` for the single-node patterns documented by YCRC.
- Bouchet's dedicated `mpi` partition is intended for tightly coupled multi-node MPI workloads that need whole, identical, unshared nodes; use of `mpirun` alone does not make that partition appropriate.
- Completed-job efficiency should be checked with tools such as `seff`; representative usage should guide later CPU/memory requests.
