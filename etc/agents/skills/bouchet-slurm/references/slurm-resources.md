# Slurm and resource requests on Bouchet

Sources:
- `docs/clusters/bouchet-rob.md`
- `docs/clusters-at-yale/job-scheduling/resource-requests.md`

Bouchet computation must be submitted through Slurm; login nodes are for connecting, file management, and job submission, while transfer nodes are for data movement.

Use partitions as intended and release idle resources. Request CPU, memory, GPU, and walltime resources to match the workload.

## Partition and GPU discovery

Do not assume that the partition named `gpu` represents every GPU resource on Bouchet. A query such as `sinfo -p gpu` answers only for the partition literally named `gpu`; it is not sufficient for questions such as "what GPU partitions exist?" or "where are the H200s?".

For cluster-wide discovery, inspect all partitions/nodes, for example:

```bash
sinfo -h -o "%P %G %N"
sinfo -N -h -o "%N %P %G"
```

To locate a requested GPU model, search the all-partition result rather than preselecting `gpu`, for example:

```bash
sinfo -N -h -o "%N %P %G" | grep -i h200
```

Use Slurm output for live node/partition state. Do not infer that a GPU model does not exist on Bouchet merely because it is absent from the `gpu` partition.

## Partition access and priority partitions

Partition existence and user entitlement are separate questions. It is fine to recommend a partition that matches the requested resources, but do not assume that the current user can submit there simply because `sinfo` or `scontrol` lists it.

For any `priority_*` partition, confirm user access before actually submitting a job. When practical, use a non-submitting validation with the intended resource request, such as:

```bash
sbatch --test-only -p <priority_partition> [other normal sbatch options] job.sh
```

If entitlement cannot be confirmed, say that the partition exists and may fit the workload but access has not been verified. Do not silently substitute a priority partition as if it were generally available.

`admintest` is reserved for administrative testing and is never an allowed target for this normal-user coding-agent deployment. Do not recommend `admintest`, and do not submit or test jobs against it.

## Resource requests

GPU access requires requesting GPUs in a suitable GPU-containing partition. Common Slurm GPU options include `--gpus`, `--gpus-per-node`, and `--gpus-per-task`. The YCRC resource-request documentation currently warns not to use `--mem-per-gpu` because it does not work as intended; request host memory with `--mem` or `--mem-per-cpu` instead.

Do not use GPU nodes unless the workload can actually use the requested GPU resources.
