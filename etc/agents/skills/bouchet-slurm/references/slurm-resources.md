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

GPU access requires explicitly requesting GPUs in a suitable GPU-containing partition; selecting a GPU partition alone does not allocate a GPU. Common Slurm GPU options include `--gpus`, `--gpus-per-node`, and `--gpus-per-task`. Prefer `--gpus=<N>` when total GPU count is what matters, and use per-node/per-task forms when topology or the distributed launcher requires them.

Host RAM and GPU VRAM are separate resources. `--mem` and `--mem-per-cpu` request host RAM and do not increase GPU VRAM. The YCRC resource-request documentation currently warns not to use `--mem-per-gpu` because it does not work as intended; request host memory with `--mem` or `--mem-per-cpu` instead.

Do not use GPU nodes unless the workload can actually use the requested GPU resources.

### GPU-count and CPU-count correctness

Do not infer a whole-node GPU request from an aggregate VRAM requirement. GPU memory is local to each device unless the application explicitly distributes model/state across multiple GPUs. Determine whether the workload supports multi-GPU sharding first, then request the smallest practical number of GPUs that provides the needed usable aggregate VRAM and runtime headroom. If the workload cannot shard, it must fit on one GPU.

For a single-process multi-GPU interactive job, a request should normally use `--ntasks=1`, `--gpus=<N>`, and `--cpus-per-task=<C>`. Remember that `-n` is an alias for `--ntasks`, not a CPU request. Do not write contradictory requests such as `--ntasks=1 -n 128`; use `-c 128` or `--cpus-per-task=128` only when that many CPUs are actually justified.

Do not assume that more GPUs improve performance. Verify that the application uses all requested devices and, when practical, validate multi-GPU scaling in an appropriate development allocation before recommending a larger production request.

Do not select GPU hardware solely by VRAM. Account for required numerical precision/capabilities and software compatibility. Avoid unnecessarily constraining a job to a specific GPU model when several compatible GPU types can satisfy the workload.

For CPU resources, use `--cpus-per-task` for CPUs belonging to a task; `--cpus-per-gpu` can be appropriate when CPU demand scales with GPU count. Do not invent large CPU counts from GPU count or node size.

Do not hard-code claims that a specific node currently has free GPUs. Query current Slurm state before making availability claims.
