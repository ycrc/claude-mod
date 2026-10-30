# Slurm on Bouchet

Sources:
- `docs/clusters/bouchet-rob.md`
- `docs/clusters-at-yale/job-scheduling/resource-requests.md`

Bouchet computation must be submitted through Slurm; login nodes are for connecting, file management, and job submission, while transfer nodes are for data movement.

## GPU discovery example

Do not assume that the partition named `gpu` represents every GPU resource on Bouchet. A query such as `sinfo -p gpu` is not sufficient for questions such as "where are the H200s?". To locate a requested GPU model, search the all-partition result rather than preselecting `gpu`, for example:

```bash
sinfo -N -h -o "%N %P %G" | grep -i h200
```

Do not infer that a GPU model does not exist on Bouchet merely because it is absent from the `gpu` partition.

## Development partition limits on Bouchet

Values read from live Slurm configuration on 2026-10-22 (recheck before relying on them):

| Partition | Per-user limit (all jobs together) | Jobs | Walltime |
| --- | --- | --- | --- |
| `devel` | 4 CPUs, 60G | 2 submitted | 6 h (default 1 h) |
| `gpu_devel` | 12 CPUs, 2 GPUs, 256G | 1 running, 1 submitted | 6 h (default 1 h) |

Both default to 5G of memory per CPU. To check the current values:

```bash
scontrol show partition devel        # QoS, default time and memory
sacctmgr -nP show qos where Name=part_devel,part_gpu_devel \
    format=Name,MaxTRESPU,MaxJobsPU,MaxSubmitJobsPU,MaxWall
```

A request beyond these limits is rejected (the QoS uses `DenyOnLimit`). Work that needs more belongs in a batch job on a standard partition, not in a larger development allocation.
