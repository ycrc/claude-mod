# Bouchet Slurm troubleshooting reference

Sources from the YCRC documentation used for this skill:
- `docs/clusters-at-yale/job-scheduling/common-job-failures.md`
- `docs/clusters-at-yale/job-scheduling/resource-usage.md`
- `docs/clusters-at-yale/job-scheduling/jobstats.md`
- `docs/clusters-at-yale/job-scheduling/resource-requests.md`

Key YCRC guidance captured here:

- Slurm OOM messages indicate the job exceeded its allocated host memory; the remedy is to request an appropriate amount of RAM or reduce the application's memory use.
- `getquota` is the appropriate first check for storage quota failures; filesystem quota is separate from job RAM.
- YCRC rate-limits job submissions to 200 jobs/hour per cluster; dSQ/job arrays are the recommended alternative for large independent batches.
- Incompatible software module toolchains can cause reload/conflict errors and abnormal application behavior; use compatible modules/reset when switching toolchains.
- Conda environments should be established in the batch job itself rather than assumed to carry over correctly from the submission shell.
- `seff` reports completed-job CPU and memory efficiency; `seff-array` summarizes arrays; `sacct` provides flexible job/accounting state and resource data.
- Representative actual usage should guide future CPU, RAM, and walltime requests.
