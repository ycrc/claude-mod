---
name: bouchet-dsq-arrays
description: Use for large batches of independent similar jobs on YCRC Bouchet, including Slurm job arrays, dSQ/Dead Simple Queue, array concurrency limits, job-list generation, array monitoring, failed-task reruns, and avoiding submission-rate limits.
---

# Bouchet dSQ and Slurm job arrays

Use this skill when a user has many independent or nearly identical tasks, is writing a loop around `sbatch`, is approaching job-submission limits, or asks about dSQ/job arrays.

## Choose the right pattern

- Prefer a **Slurm job array** when the tasks are homogeneous and can be selected cleanly by an integer index such as `SLURM_ARRAY_TASK_ID`.
- Prefer **dSQ (Dead Simple Queue)** when the user already has, or can easily generate, one complete command per task. dSQ converts that job list into a Slurm array and provides status/rerun tooling.
- Do not submit hundreds or thousands of independent jobs with a shell loop around `sbatch`. YCRC documentation states that clusters enforce a **200 job submissions per hour** rate limit; arrays/dSQ are the intended alternative.
- Job arrays/dSQ are for independent tasks. Do not present them as a replacement for MPI, tightly coupled distributed jobs, or a workflow where tasks depend on one another.
- Job arrays are not ideal when most runtime is reusable initialization/startup overhead. Consider restructuring into longer-lived workers or bundling work instead.
- If individual tasks are very short (less than about one minute), bundle multiple tasks into each array element so an element runs for roughly **10 minutes or more**. Large numbers of tiny jobs burden the scheduler and storage.

## Resources are per array element

A resource request in an array or dSQ-generated script applies to **each running element**, not to the array as a whole.

For example, if each element requests:

```bash
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=01:00:00
```

then ten simultaneously running elements can consume up to 40 CPUs and 160 GiB of host RAM. Size resources from one task, then separately decide how many tasks may run concurrently.

For GPU arrays, also use the `bouchet-gpu` skill. A GPU request is likewise per array element.

## Plain Slurm job arrays

A typical homogeneous array looks like:

```bash
#!/bin/bash
#SBATCH --job-name=my-array
#SBATCH --array=1-1000%50
#SBATCH --output=slurm-%A.%a.out
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=00:20:00

module reset
module load miniconda
conda activate env_name
python my_script.py "image_${SLURM_ARRAY_TASK_ID}.jpg"
```

Key rules:

- `SLURM_ARRAY_TASK_ID` is the element index.
- `%A` in output names is the parent array job ID; `%a` is the array task index. Use both to avoid log-file collisions.
- The optional `%50` in `--array=1-1000%50` limits the number of array elements that may run simultaneously. Choose concurrency from workload/resource needs and cluster conditions; do not maximize it blindly.
- Array indices do not have to begin at 1, but code and input mapping must use the same convention.
- Avoid having every element write to the same output/cache/temp file. Give elements unique paths when concurrent writes could collide.
- Slurm jobs start in the directory from which the job was submitted unless the script changes directory or specifies another working directory.

Submit once:

```bash
sbatch job-array.sh
```

Do not wrap that `sbatch` command in a loop.

## dSQ workflow

### 1. Build a job file

Create one **self-contained command per line**. Blank lines and lines beginning with `#` are ignored by dSQ.

Example:

```text
module reset; module load miniconda; conda activate env_name; python my_script.py image_1.jpg
module reset; module load miniconda; conda activate env_name; python my_script.py image_2.jpg
module reset; module load miniconda; conda activate env_name; python my_script.py image_3.jpg
```

Because coding-agent shell invocations do not preserve environment changes across separate tool calls, generate lines that contain all environment setup needed by that task. A dSQ job-line itself may contain a sequence of commands separated by `;` or `&&`.

### 2. Load dSQ and generate the batch script

Run module setup and `dsq` in the same coding-agent shell invocation:

```bash
module load dSQ && dsq \
  --job-file joblist.txt \
  --max-jobs 50 \
  --mem-per-cpu 4g \
  -t 20:00
```

- `--max-jobs N` limits simultaneously running array elements. Use it when the workload would otherwise create excessive concurrent CPU, memory, GPU, filesystem, license, database, or service load.
- dSQ normally writes a batch script. Prefer inspecting that generated script before submitting when constructing or modifying a workflow.
- `--submit` can submit directly, but do not use it reflexively when reviewing the generated Slurm request first would be safer or clearer.
- Resource options supplied to `dsq` apply to **each line/job**, not the entire job list.

Then submit the generated script once:

```bash
sbatch dsq-joblist-YYYY-MM-DD.sh
```

Do not assume the exact generated filename; inspect the `dsq` output or directory.

## dSQ indexing is zero-based

The dSQ-generated array indexes job-file commands from **zero**. The first runnable line is task index 0, the second is 1, the third is 2, etc.

Do not confuse this with examples of hand-written Slurm arrays that start at 1.

## Monitor and manage arrays

Useful commands include:

```bash
squeue -u "$USER"
squeue -j <array_job_id>
seff-array <array_job_id>
```

An individual array element is addressed with `jobid_index` syntax:

```bash
scancel 14567_4
scancel '14567_[10-20]'
```

Cancelling the parent array job ID cancels the array; cancelling `jobid_index` targets only selected elements. Only act on jobs the current user is authorized to manage.

## Failed-task reruns with dSQAutopsy

dSQ writes a status TSV for completed elements unless that feature is suppressed. Use `dsqa`/dSQAutopsy rather than resubmitting every command when only a subset failed or was preempted.

Summary example:

```bash
module load dSQ && dsqa -j <array_job_id>
```

To create a new job file containing selected unsuccessful states from the original job file:

```bash
module load dSQ && dsqa -j <array_job_id> -f joblist.txt > re-run_jobs.txt 2> array-report.txt
```

Review the rerun list before submitting it. Do not create array elements that merely check whether earlier work succeeded and immediately exit when dSQAutopsy can omit successful tasks entirely.

## Common mistakes to prevent

- Do not use a loop such as `for ...; do sbatch ...; done` for a large independent batch.
- Do not multiply a per-task resource request by the number of elements in the `#SBATCH` directives. Slurm allocates those resources independently to each running element.
- Do not assume array size equals concurrent usage. Array size is total work; `%N` or dSQ `--max-jobs N` controls concurrency.
- Do not omit unique log/output naming for concurrently running tasks.
- Do not rely on mutable shell state from before `sbatch`; initialize modules/Conda/environment inside the batch script or each self-contained dSQ command.
- Do not generate thousands of sub-minute elements when work can be bundled.
- Do not invent current queue capacity, partition availability, or a safe concurrency level from stale information. Use the `bouchet-slurm` skill and current Slurm state when those facts matter.

For the YCRC-derived details captured for this deployment, read `references/dsq-job-arrays.md`.
