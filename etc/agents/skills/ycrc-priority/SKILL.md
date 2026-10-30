---
name: ycrc-priority
description: Use for Priority Tier partitions on YCRC clusters (priority, priority_gpu, priority_mpi), paid priority credits, Priority Tier Slurm accounts (prio_...), Priority Tier cost/usage questions, or moving/submitting jobs to Priority Tier partitions.
---

# YCRC Priority Tier

Priority Tier is a paid, opt-in scheduling tier. Treat use of it as a billable action, not merely a partition-selection detail.

## Hard confirmation gate for billable actions

Before **actually submitting, resubmitting, or moving a job into any Priority Tier partition**, you must:

1. Determine that Priority Tier is relevant to the user's goal.
2. Verify or clearly establish the required Priority Tier entitlement/account when practical.
3. Tell the user that Priority Tier consumes paid credits / incurs charges to the group's Priority Tier account.
4. Ask for explicit confirmation that they want to use paid Priority Tier for the specific job or clearly defined batch of jobs.
5. Perform the billable Slurm action only after that explicit confirmation.

This confirmation gate applies to actions such as:

```bash
sbatch -p priority ...
sbatch -p <priority_partition> ...
salloc -p <priority_partition> ...
srun -p <priority_partition> ...
scontrol update JobId=<jobid> Partition=<priority_partition>
```

It applies to every Priority Tier partition on the cluster (this cluster's are listed below).

It does **not** prevent you from:
- explaining Priority Tier;
- checking whether the user appears to have access;
- querying current Priority Tier usage;
- estimating cost;
- drafting a Priority Tier command or submission script;
- showing Priority Tier as an option alongside free Standard Tier.

A clear user instruction such as “submit these 20 jobs to priority” can serve as confirmation for that clearly defined batch. Do not treat old or unrelated consent as blanket authorization for future Priority Tier submissions.

Never silently change a Standard Tier job to Priority Tier because the Standard Tier queue is busy.

## Access and account selection

- Priority Tier access is opt-in and granted to approved users/groups.
- Priority Tier jobs require a Priority Tier Slurm account (this cluster's account naming is below).
- Before actually submitting, verify the intended account when practical. Do not invent a Priority Tier account name.
- If access is uncertain, inspect the user's available Slurm accounts/associations or use a non-submitting validation such as `sbatch --test-only` when practical.

## What Priority Tier changes

- Priority Tier is a fast lane: Priority Tier jobs precede pending jobs in corresponding Standard Tier partitions, subject to resource availability and ordering among Priority Tier jobs.
- Priority Tier does **not** guarantee immediate start.
- Standard Tier, private nodes, and scavenge partitions do not incur Priority Tier charges.
- Interactive jobs are permitted on Priority Tier partitions for entitled users, but the paid-credit confirmation gate still applies before launching the interactive allocation.

## Cost awareness

- Priority Tier usage is billed based on **actual runtime**, not requested walltime.
- All allocated CPUs, host memory, and GPUs are billed even if they are underused.
- GPU Service Units/cost differ substantially by GPU model. When using a Priority Tier GPU partition, be specific about GPU type when appropriate so the user does not unintentionally receive a more expensive resource than required.
- Rates can change. Use current YCRC documentation or the YCRC cost calculator / usage tools for exact cost estimates rather than hard-coding remembered prices.

Do not claim remaining budget or annual usage-limit headroom unless you have current evidence.

## On Bouchet

- Bouchet's Priority Tier partitions are `priority`, `priority_gpu`, and `priority_mpi`. The confirmation gate applies to every one of them, for example `sbatch -p priority_gpu ...`, `sbatch -p priority_mpi ...`, `salloc -p priority_gpu ...`, `srun -p priority_gpu ...`, and `scontrol update JobId=<jobid> Partition=priority_gpu`.
- Bouchet Priority Tier jobs require a `prio_...` Slurm account, for example:

```bash
#SBATCH -A prio_groupname
```

or:

```bash
#SBATCH -A prio_groupname_projectid
```

- A `prio_...` account is for Priority Tier and cannot be used in Standard Tier partitions. Do not invent a `prio_` account name.
- For non-GPU compute jobs, Service Units are based on the larger of CPU core count or total RAM allocation divided by 15 GB.
- When using `priority_gpu`, be specific about GPU type when appropriate so the user does not unintentionally receive a more expensive resource than required.
- Useful usage command (groups can also inspect usage in the YCRC User Portal):

```bash
getusage -g prio_groupname
```

## Choosing Priority Tier responsibly

Priority Tier may be appropriate when faster scheduling materially matters and the user knowingly accepts the cost. It should not be the automatic response to a pending Standard Tier job.

For a pending job, first use `ycrc-job-troubleshooting` to understand the scheduler reason. Then, if Priority Tier could help, present it as a paid option and ask before actually using it.

For GPU sizing/type selection, use `ycrc-gpu` in addition to this skill. For CPU/task layout, use `ycrc-parallel`.

For source-backed details, read `references/priority-tier.md`.
