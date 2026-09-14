---
name: bouchet-scavenge
description: Use for Bouchet scavenge or scavenge_gpu jobs, preemption, requeue/checkpoint strategy, opportunistic resources, or deciding whether a workload is safe for scavenge.
---

# Bouchet Scavenge

Scavenge is opportunistic, preemptable capacity. Recommend it only when the workload can tolerate interruption.

## Core behavior

- Scavenge can run outside some normal resource limits and can use otherwise idle resources, including unused resources on private/special-purpose nodes.
- Any scavenge job may be preempted when the node is needed by a job in its normal partition.
- Preemption may happen without advance notice.
- Scavenge therefore provides opportunistic capacity, not guaranteed runtime or availability.

Do not present scavenge as equivalent to Standard Tier with a shorter queue.

## Decide whether the workload is a good fit

Good candidates are workloads that:
- checkpoint frequently enough to limit lost work;
- can restart cheaply;
- consist of independent/restartable tasks;
- can tolerate being killed and retried.

Poor candidates include workloads with:
- long startup or initialization costs;
- long periods between checkpoints;
- expensive unrecoverable progress;
- fragile interactive state;
- external side effects that are unsafe to repeat.

Before recommending scavenge for a long-running job, determine how the application restarts after preemption. If there is no practical restart/checkpoint strategy, prefer a non-preemptable partition.

## Requeue is not checkpointing

To have Slurm automatically put a preempted job back in the queue, a submission may include:

```bash
#SBATCH --requeue
```

But `--requeue` reruns the original submission script. It does **not** restore application state by itself. The application must checkpoint/restart correctly if progress is to resume rather than start over.

For a requeued job, inspect all job instances/history with:

```bash
sacct -j <jobid> --duplicates
```

## Bouchet scavenge partitions

- `scavenge` is the general preemptable partition.
- `scavenge_gpu` contains scavenge-able GPU resources and has higher priority for those GPU nodes than ordinary `scavenge`.
- Both are preemptable and have Bouchet-specific limits; consult current partition documentation or Slurm configuration rather than hard-coding remembered inventory.
- A GPU is **not** allocated merely by choosing `scavenge` or `scavenge_gpu`; explicitly request GPUs with `--gpus` or the appropriate GPU resource option.
- Use `bouchet-gpu` for GPU count/type/VRAM decisions.

Do not infer current idle hardware from documentation. Query Slurm for live availability, for example:

```bash
sinfo -e -o "%.6D|%T|%c|%G|%b" | column -ts "|"
```

## Arrays and dSQ

Independent restartable tasks can be a strong scavenge use case. For many tasks, use `bouchet-dsq-arrays` to construct the array/dSQ workflow rather than submitting many individual jobs.

When combining arrays with scavenge:
- make each task idempotent or safely restartable;
- write outputs atomically when possible;
- make logs/output unique per array element;
- do not assume `--requeue` alone prevents duplicate work or repeated side effects.

## Interactive work

Scavenge is generally a poor default for interactive debugging because an interactive session can disappear on preemption. Prefer the documented development partitions (`devel` / `gpu_devel`) for normal interactive development unless the user specifically accepts scavenge's interruption risk and current YCRC policy supports the intended workflow.

## Troubleshooting preemption

When a scavenge job disappears, is requeued, or has repeated attempts:
- inspect job/accounting state rather than assuming an application failure;
- use `sacct`, including `--duplicates` for requeued jobs;
- distinguish scheduler preemption from OOM, timeout, application exit, or GPU-utilization enforcement;
- route general failure diagnosis to `bouchet-job-troubleshooting`.

For source-backed details, read `references/scavenge.md`.
