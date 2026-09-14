---
name: bouchet-priority
description: Use for YCRC Bouchet Priority Tier partitions, paid priority credits, prio_ Slurm accounts, Priority Tier cost/usage questions, or moving/submitting jobs to priority, priority_gpu, or priority_mpi.
---

# Bouchet Priority Tier

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
sbatch -p priority_gpu ...
sbatch -p priority_mpi ...
salloc -p priority_gpu ...
srun -p priority_gpu ...
scontrol update JobId=<jobid> Partition=priority_gpu
```

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
- Bouchet Priority Tier jobs require a `prio_...` Slurm account, for example:

```bash
#SBATCH -A prio_groupname
```

or:

```bash
#SBATCH -A prio_groupname_projectid
```

- A `prio_...` account is for Priority Tier and cannot be used in Standard Tier partitions.
- Before actually submitting, verify the intended account when practical. Do not invent a `prio_` account name.
- If access is uncertain, inspect the user's available Slurm accounts/associations or use a non-submitting validation such as `sbatch --test-only` when practical.

## What Priority Tier changes

- Priority Tier is a fast lane: Priority Tier jobs precede pending jobs in corresponding Standard Tier partitions, subject to resource availability and ordering among Priority Tier jobs.
- Priority Tier does **not** guarantee immediate start.
- Standard Tier, private nodes, and scavenge partitions do not incur Priority Tier charges.
- Interactive jobs are permitted on Priority Tier partitions for entitled users, but the paid-credit confirmation gate still applies before launching the interactive allocation.

## Cost awareness

- Priority Tier usage is billed based on **actual runtime**, not requested walltime.
- All allocated CPUs, host memory, and GPUs are billed even if they are underused.
- For non-GPU compute jobs, Service Units are based on the larger of CPU core count or total RAM allocation divided by 15 GB.
- GPU Service Units/cost differ substantially by GPU model. When using `priority_gpu`, be specific about GPU type when appropriate so the user does not unintentionally receive a more expensive resource than required.
- Rates can change. Use current YCRC documentation or the YCRC cost calculator / usage tools for exact cost estimates rather than hard-coding remembered prices.

Useful usage command:

```bash
getusage -g prio_groupname
```

Do not claim remaining budget or annual usage-limit headroom unless you have current evidence.

## Choosing Priority Tier responsibly

Priority Tier may be appropriate when faster scheduling materially matters and the user knowingly accepts the cost. It should not be the automatic response to a pending Standard Tier job.

For a pending job, first use `bouchet-job-troubleshooting` to understand the scheduler reason. Then, if Priority Tier could help, present it as a paid option and ask before actually using it.

For GPU sizing/type selection, use `bouchet-gpu` in addition to this skill. For CPU/task layout, use `bouchet-parallel`.

For source-backed details, read `references/priority-tier.md`.
