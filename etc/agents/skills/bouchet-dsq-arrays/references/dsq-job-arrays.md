# YCRC dSQ/job-array reference notes

These notes summarize the YCRC documentation used to build the Bouchet dSQ/job-array skill.

- Slurm job arrays are intended for large batches of independent, homogeneous jobs.
- Arrays can grow and shrink with available resources and may have an explicit concurrency limit.
- They are not recommended when reusable initialization dominates runtime.
- `SLURM_ARRAY_TASK_ID` identifies a hand-written array element.
- `%A` is the array job ID and `%a` is the task index in Slurm output-file patterns.
- Resource requests in an array script are allocated to **each** running array element.
- Individual elements can be managed with `jobid_index` syntax, and `seff-array` can summarize resource use.
- YCRC's Dead Simple Queue (`dSQ`) converts a text job file containing one self-contained command per line into a job array.
- Blank lines and lines beginning with `#` in a dSQ job file are ignored.
- YCRC recommends bundling tasks shorter than about one minute so that each array element runs for at least roughly 10 minutes.
- `module load dSQ` exposes the `dsq` command.
- dSQ `--max-jobs N` limits simultaneously running jobs from the array.
- dSQ's generated array uses zero-based line/task indexing.
- dSQ can create a per-job status TSV; dSQAutopsy/`dsqa` can summarize an array and generate a rerun job file for unsuccessful jobs.
- YCRC documents a cluster job-submission rate limit of 200 jobs per hour and recommends arrays/dSQ instead of loops of individual `sbatch` submissions.

Source basis: YCRC documentation pages for Job Arrays/dSQ, common job failures/rate limits, Slurm command-line environment variables, resource requests, and resource usage included in the supplied documentation source tree.
