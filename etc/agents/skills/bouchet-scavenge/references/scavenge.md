# YCRC Scavenge reference for Bouchet agents

Key YCRC documentation points:

- Scavenge allows opportunistic use of otherwise idle resources and can allow jobs outside some normal limits.
- Scavenge jobs are subject to preemption whenever a node is required for a job in its normal partition.
- Jobs may be killed without advance notice; use scavenge only for checkpointable or cheaply restartable workloads.
- Jobs with long startup times or long intervals between checkpoints are poor scavenge candidates.
- `#SBATCH --requeue` can automatically return a preempted job to the queue, but reruns the original script and does not itself restore program state.
- Requeued attempts retain the same job ID; `sacct -j <jobid> --duplicates` shows the full history.
- Bouchet has `scavenge_gpu`; it behaves like normal scavenge with respect to preemption and time limits while targeting scavenge-able GPU resources.
- Current hardware availability should be researched with live Slurm queries such as `sinfo`; documentation is not a live availability source.
