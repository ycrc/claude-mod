---
name: bouchet-parallel
description: Use for CPU parallelism and Slurm layout on YCRC Bouchet, including single-threaded, multithreaded/OpenMP, multiprocessing, MPI, hybrid MPI+threads, GNU Parallel, tasks vs CPUs, nodes, and choosing arrays/dSQ instead of over-requesting CPUs.
---

# Bouchet CPU parallelism and Slurm layout

Use this skill before generating a multi-CPU or multi-node Slurm request. First identify **how the application actually parallelizes**; do not infer resource layout from the number of CPUs a user says are available.

## Classify the workload first

Before choosing `--ntasks`, `--cpus-per-task`, or `--nodes`, determine which model applies:

1. **Single-threaded / serial** — one process that uses one CPU core.
2. **Multithreaded / shared-memory** — one process uses multiple threads on one node (OpenMP, BLAS threads, many threaded libraries).
3. **Independent multiprocessing/workers** — multiple independent local processes, generally on one node unless the application explicitly supports distributed workers.
4. **MPI** — multiple communicating ranks/tasks that may span nodes.
5. **Hybrid MPI + threads** — multiple MPI ranks, each using multiple threads.
6. **Many independent tasks** — use `bouchet-dsq-arrays` rather than pretending the workload is one large parallel job.

If the application documentation or command does not indicate parallel support, assume that giving it more CPUs will **not** make it faster until verified.

## Slurm meanings: do not mix these up

- `--ntasks` / `-n` = number of Slurm tasks, normally MPI ranks/processes for an MPI application.
- `--cpus-per-task` / `-c` = CPUs assigned to each task/process. Use this for a multithreaded non-MPI program.
- `--nodes` / `-N` = number of nodes. Do not request multiple nodes unless the application can use them or topology requires them.
- `--ntasks-per-node` = placement of tasks across nodes; primarily useful for MPI/distributed layouts.

`-n` is **not** a CPU-count shortcut. Never produce contradictory requests such as:

```bash
--ntasks=1 -n 128
```

Those specify the same option twice. For a single multithreaded process needing 128 CPUs, the conceptual request is `--ntasks=1 --cpus-per-task=128`, but only if one Bouchet node can provide that many CPUs and the application can really use them.

A single Slurm task and all CPUs assigned to that task stay on one node. `--cpus-per-task` cannot make a non-distributed program span nodes.

## Single-threaded programs

Do not request many CPUs for software that only uses one core. A basic job generally needs one task and one CPU; Slurm defaults may already provide that.

If there are many independent serial invocations, route to `bouchet-dsq-arrays`. Running many separate tasks concurrently is usually the correct way to increase throughput for serial software.

## Multithreaded / OpenMP programs

For a non-MPI threaded program, request CPUs with `--cpus-per-task` and keep the workload on one node.

Typical pattern:

```bash
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8

export OMP_NUM_THREADS="$SLURM_CPUS_PER_TASK"
./my_threaded_program
```

Only set `OMP_NUM_THREADS` for software that uses OpenMP or honors that variable. For BLAS/numerical libraries, also consider the library's own thread controls rather than blindly exporting every common threading variable.

Verify scaling. If 8 CPUs do not materially outperform 4, do not recommend 16 just because they are available.

## Independent local workers and GNU Parallel

If many independent commands should run concurrently **within one node**, GNU Parallel or application-level multiprocessing can be appropriate. Match worker concurrency to allocated CPUs.

For GNU Parallel:

```bash
#SBATCH --cpus-per-task=8

module load parallel
parallel -j "$SLURM_CPUS_PER_TASK" command {} ::: inputs...
```

Do not start more CPU-bound workers than the job has CPUs without a specific reason. If the task set is large, long-running, needs independent retry/accounting, or should span many nodes through the scheduler, use a Slurm array/dSQ instead of one enormous GNU Parallel allocation.

## MPI programs

Use `--ntasks` for MPI ranks. Add `--nodes`/`--ntasks-per-node` only when the required layout matters.

Conceptual example:

```bash
#SBATCH --ntasks=16
#SBATCH --time=01:00:00

module load <matching-MPI-application-module>
mpirun <program>
```

Do not convert a threaded program into an MPI job by changing `--cpus-per-task` to `--ntasks`. The application must actually be MPI-enabled.

Do not assume that merely invoking `mpirun` means the dedicated Bouchet `mpi` partition is appropriate. YCRC documentation reserves Bouchet's `mpi` partition for tightly coupled multi-node MPI applications that benefit from whole, identical, unshared nodes. Smaller MPI jobs or MPI jobs that do not require exclusive nodes should use an appropriate ordinary partition. Jobs inappropriate for the dedicated `mpi` partition may be cancelled.

Before using the dedicated `mpi` partition, query current Bouchet partition/node configuration if exact core counts or layout matter. Do not rely on remembered hardware values.

## Hybrid MPI + threads

Hybrid applications legitimately use both tasks and CPUs per task:

```bash
#SBATCH --nodes=2
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=4

export OMP_NUM_THREADS="$SLURM_CPUS_PER_TASK"
mpirun <hybrid_program>
```

Interpret this as 8 MPI ranks with 4 CPUs/threads per rank. Choose `--nodes` so the requested ranks and CPUs can physically fit according to the application's desired placement.

Do not generate a hybrid layout unless the application really supports threaded MPI ranks.

## Choose throughput vs. single-job speed correctly

If the application is serial or scales poorly, more CPUs in one job waste resources. Prefer multiple independent jobs using dSQ/job arrays when the work can be partitioned by files, samples, parameters, seeds, subjects, or similar independent units.

Use `bouchet-dsq-arrays` for:
- large batches of independent commands;
- shell loops around `sbatch`;
- parameter sweeps where tasks do not communicate;
- retrying subsets of failed independent work.

Use MPI/multithreading only when the application itself supports and benefits from it.

## Validate resource use instead of guessing

After representative jobs complete, use `seff`, `jobstats`, or appropriate application profiling to verify CPU efficiency and memory use. Low CPU efficiency can mean the program is serial, worker/thread counts are misconfigured, I/O is limiting progress, or the job simply requested too many CPUs.

When diagnosing an existing job or a pending/failing job, use `bouchet-job-troubleshooting`.

For YCRC-derived details, read `references/parallel-resources.md` and the `bouchet-slurm` resource reference.
