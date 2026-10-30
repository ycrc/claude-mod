---
name: ycrc-job-troubleshooting
description: Use when a Slurm job on YCRC clusters is pending, failed, cancelled, timed out, OOM-killed, inefficient, missing expected software/files, or otherwise behaving unexpectedly; covers squeue/scontrol/sacct/seff/jobstats, memory, quotas, rate limits, modules/Conda, and evidence-first remediation.
---

# YCRC Slurm job troubleshooting

Diagnose first; change the request second. Do not guess why a job is pending or failed from the submission script alone when Slurm can report the reason/state.

## Start with the job ID and current state

For a current job:

```bash
squeue -j <jobid> -o "%.18i %.9P %.16j %.2t %.10M %.6D %R"
scontrol show job <jobid>
```

For completed/failed jobs:

```bash
sacct -j <jobid> -X -o JobID,JobName,Partition,State,ExitCode,Elapsed,Timelimit,ReqMem,MaxRSS,AllocTRES
```

If useful, inspect steps as well by omitting `-X` or requesting the needed step fields. Do not infer an exit cause from a generic nonzero code if logs/Slurm state provide a more specific explanation.

## Pending jobs: read the reason

The pending reason in `squeue`/`scontrol` is the starting point. Do **not** "fix" a pending job by blindly increasing/decreasing CPUs, memory, walltime, nodes, or changing partitions.

Common categories include:
- waiting for resources that match the request;
- priority/fair-share ordering;
- dependency or reservation conditions;
- account/QOS/partition constraints;
- an impossible or overly restrictive request.

Use current Slurm data before claiming a node or partition is available. A long wait does not by itself prove the request is invalid.

Before submitting to a Priority Tier partition, use the entitlement guidance in `ycrc-slurm`. Some partitions are never an allowed target for a normal user; see the cluster facts below.

## Failed jobs: separate scheduler failure from application failure

Use all three sources when available:

1. Slurm state and exit code (`sacct`, `scontrol`).
2. Slurm stdout/stderr/application logs.
3. Resource-usage evidence (`seff`, `jobstats`, `seff-array`).

Do not overwrite or delete useful logs while diagnosing.

## Out of host memory

YCRC documents messages such as:

```text
slurmstepd: error: Detected 1 oom-kill event(s).
```

as evidence that the job exceeded its allocated **host RAM**. Bus errors can also occur when a process tries to use memory outside the Slurm allocation.

First inspect requested vs. observed memory:

```bash
seff <jobid>
sacct -j <jobid> -o JobID,State,ExitCode,ReqMem,MaxRSS,AllocTRES
```

Then either request more host RAM (`--mem` or `--mem-per-cpu`) or reduce the application's memory use. Do not simply multiply memory by an arbitrary factor.

For GPU-memory/OOM issues, use `ycrc-gpu`: host RAM and GPU VRAM are different resources.

## Timeout

If the job state/logs show that the time limit was reached, compare actual work completed and representative runtime before increasing `--time`. Requesting a dramatically excessive walltime can delay scheduling; request a realistic amount with reasonable headroom.

Do not treat every `CANCELLED` state as a timeout; inspect Slurm's state/reason and logs.

## CPU or memory inefficiency

For completed jobs:

```bash
seff <jobid>
```

For arrays:

```bash
seff-array <array_job_id>
```

Use `jobstats <jobid>` where appropriate for YCRC resource/utilization views, including GPU jobs.

Interpret low CPU efficiency carefully. Possible causes include:
- serial software given multiple CPUs;
- incorrect thread/worker configuration;
- I/O or synchronization bottlenecks;
- an application waiting on another resource;
- simply over-requesting CPUs.

Do not conclude that the fix is always "request fewer CPUs" without understanding the workload. Use `ycrc-parallel` to correct task/thread/node layouts.

Low memory efficiency means the job may be over-requesting host RAM, but tune from multiple representative runs when workloads vary substantially.

## Sizing the next job from completed jobs

When a comparable job will be run again, size its request from what earlier runs actually used:

```bash
sacct -j <jobid> -o JobID,State,ExitCode,Elapsed,Timelimit,ReqMem,MaxRSS,ReqCPUS,TotalCPU,AllocTRES
seff <jobid>            # or seff-array <array_job_id>
jobstats <jobid>        # includes GPU utilization and GPU memory
```

- Use only runs that **completed successfully** and are comparable (same tool and version, similar input size and parameters). An OOM, timeout, cancellation or missing accounting record does not show what the job needed; it shows only that the request was not enough, or nothing.
- Compare requested with observed: peak memory (`MaxRSS`) against `ReqMem`, CPU time against elapsed time × CPUs, and elapsed time against the time limit. Leave headroom for variation rather than requesting the exact peak.
- **Host RAM and GPU memory are separate.** `MaxRSS`/`seff` report host RAM; GPU memory and GPU utilization come from `jobstats`. Size `--mem` from the former and the GPU type/count from the latter (see `ycrc-gpu`).
- **Array tasks vary.** Look at the spread across tasks (`seff-array`), not only the average; size for the larger tasks or split unusually large inputs.
- Low CPU or GPU utilization needs a diagnosis before cutting the request (see "CPU or memory inefficiency" above); reducing CPUs and time together on one observation can make the next run time out.

## Disk/quota failures

If a job cannot create/write files or reports disk-quota errors, inspect quota rather than increasing Slurm memory:

```bash
getquota
```

Project/scratch/storage quotas may be shared by a group. Use `ycrc-storage` for storage placement, scratch retention, and safe cleanup guidance.

Do not confuse filesystem quota with RAM or GPU VRAM.

## Submission-rate failures

YCRC limits submissions to **200 jobs per hour per cluster**. Errors mentioning the jobs-per-hour/accounting/QOS submission limit should not be solved with rapid retries.

Use `ycrc-dsq-arrays` to convert large independent workloads to a Slurm job array/dSQ workflow. Wait for the submission-rate window to recover before retrying ordinary submissions.

## Modules and Conda failures inside jobs

Do not assume a module or Conda environment active at submission time will be reproduced correctly inside the job.

Batch scripts should establish their own software environment. Examples:

```bash
module reset
module load <module>
<command>
```

or:

```bash
module reset
module load miniconda
conda activate <env>
python script.py
```

Use `ycrc-modules` and `ycrc-conda` for the detailed rules. Avoid mixing incompatible module toolchains. YCRC documentation notes that incompatible toolchains can produce reload/conflict errors and strange behavior.

## Job works interactively but not in batch

Compare:
- working directory;
- module/Conda initialization;
- environment variables;
- paths visible to the Slurm job;
- CPU/GPU allocation and application launch command;
- relative filenames and permissions.

If the agent itself runs in a sandbox, a path the agent can see may differ from what the submitted job sees; see the cluster facts below.

## Running-job inspection

Prefer scheduler/resource tools first. If process-level inspection is necessary, only inspect processes/jobs belonging to the current user and do not cross user boundaries.

For multi-node jobs, use YCRC-supported cluster tools/workflows rather than manually disrupting other users' nodes or processes.

## Do not mask failures

Do not:
- automatically resubmit repeatedly without identifying the failure;
- increase every resource "just in case";
- suppress nonzero exit codes merely to make a pipeline appear successful;
- keep GPU jobs alive artificially to avoid utilization enforcement;
- delete logs/status files needed to diagnose the problem.

A remediation should be tied to observed evidence: scheduler reason, exit state, error text, measured resource use, or documented application behavior.

## On Bouchet

- Priority Tier partitions are the `priority_*` partitions.

### In the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`)

- `admintest` is never an allowed target for this normal-user deployment.
- A job launched with `sbatch`/`srun` runs as the normal user outside the coding agent's interactive Apptainer filesystem sandbox. A path that exists only inside the agent container may not exist in the submitted job.

For YCRC-derived details, read `references/job-troubleshooting.md`.
