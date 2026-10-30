---
name: ycrc-gpu
description: Use for GPU jobs, GPU-memory sizing, multi-GPU requests, Jobstats, GPU utilization, low-utilization diagnosis, CUDA/module troubleshooting, and YCRC GPU enforcement on YCRC clusters.
---

# YCRC GPU workflows

## Size GPU requests from the workload, not from node totals

- Do not equate a requested amount of GPU memory with a whole-node allocation. Determine the minimum number of GPUs that can satisfy the workload.
- Distinguish **memory required on one GPU** from **aggregate memory that a multi-GPU workload can use**. GPU VRAM is not automatically pooled across devices.
- Before recommending multiple GPUs to satisfy a memory requirement, verify that the application/model can actually shard or distribute its state across GPUs (for example tensor parallelism, pipeline parallelism, FSDP/ZeRO, or another supported multi-GPU strategy).
- If the workload can shard, estimate the minimum GPU count as `ceil(required aggregate VRAM / usable VRAM per GPU)`, then allow reasonable headroom for runtime overhead. Do not jump directly to every GPU on a node.
- If the workload cannot shard, it must fit on a single GPU. Adding more GPUs does not solve a per-device VRAM requirement.
- Prefer the smallest practical GPU count and host-memory/CPU request that meets the workload. Recommend a whole node only when the workload, topology, software design, or measured scaling actually requires it.
- Do not assume that adding GPUs improves performance. For multi-GPU workloads, validate that the application uses every requested GPU and, when practical, test scaling before recommending a larger production allocation. `gpu_devel` is appropriate for interactive development/scaling tests when the user has access and the current cluster configuration supports the requested GPU type.
- Treat GPU model requirements separately from VRAM requirements. Consider precision/capability needs (for example FP64, BF16/FP16, tensor-core support), software/CUDA compatibility, and model-specific constraints rather than choosing hardware solely by memory size.
- Request a specific GPU type only when the workload actually requires that type or capability. Otherwise preserve scheduler flexibility rather than unnecessarily pinning the job to scarce hardware.

## Discover current GPU resources instead of inventing them

- GPU inventory, node state, and partition availability are live cluster facts. Query Slurm before making a concrete recommendation rather than hard-coding a remembered node, free-GPU count, or queue state.
- Useful discovery commands include:

```bash
sinfo -N -h -o "%N %P %G %t"
sinfo -h -o "%P %G %N"
scontrol show node <node>
```

- Use the `ycrc-slurm` skill for partition discovery and entitlement rules.
- Do not claim that a particular node currently has free GPUs unless current Slurm output supports that statement.
- Do not assume that all nodes of a GPU type have the same host-memory configuration unless verified from current cluster documentation or Slurm configuration.

## On Bouchet

- Bouchet's Standard Tier production GPU partitions are `gpu`, `gpu_rtx6000`, `gpu_h100`, `gpu_h200`, and `gpu_b200`. None of them is for interactive allocations: interactive GPU work on Bouchet must use `gpu_devel` (course accounts: `education_gpu` first, see below).
- Bouchet's GPU scavenge partition is `scavenge_gpu`, preemptable like `scavenge` and not the normal choice for an interactive debugging session.
- For Bouchet's GPU-partition documentation and Rules of Behavior, read `references/gpu-bouchet.md`.

### Course accounts

Course accounts (username `courseid_netid`) should use `education_gpu` first, for interactive and batch GPU work alike (`salloc -p education_gpu --gpus=1`), when it has a free GPU and the work fits: 1 job and 1 GPU per user, RTX 5000 Ada (32 GB), A5000 (24 GB) or A40 (48 GB), up to 1 day. If it's full, or the work needs several GPUs or more than 48 GB of GPU memory, use the public GPU partitions below. `education_gpu` also allows interactive jobs.

## Interactive GPU policy — mandatory

- **Interactive GPU work must use `gpu_devel`** (exceptions for this cluster, if any, are listed above).
- Standard Tier production GPU partitions (this cluster's are listed above) are not for interactive allocations. Do not use `salloc`, `srun --pty`, an alternate QOS, or other scheduler options to obtain interactive access in those production GPU partitions.
- If an interactive request to a production GPU partition is rejected, **do not troubleshoot it by changing QOS or other Slurm settings to make it schedulable**. Direct the user to `gpu_devel`.
- A command being accepted by Slurm, `sbatch --test-only`, `salloc`, or another scheduler validation does not establish that the workflow complies with YCRC policy.
- Do not change QOS merely to make a rejected job succeed. Use a different QOS only when managed YCRC guidance explicitly establishes that it is appropriate.
- Priority Tier is a documented exception: interactive jobs may use Priority Tier partitions for entitled users, but Priority Tier is paid. Route to `ycrc-priority` and obtain explicit confirmation before launching the billable allocation.
- Interactive VS Code must use devel partitions such as `devel` or `gpu_devel`.
- `scavenge` and the other scavenge partitions are preemptable and are not the normal choice for an interactive debugging session.

For ordinary interactive GPU development, debugging, environment setup, GPU detection, profiling, and scaling tests, use `gpu_devel`. It allows one job per user, and a second submission is rejected at once (`QOSMaxSubmitJobPerUserLimit`): if the user already has one (for example an Open OnDemand session), end it or run the new work as a batch job on a production GPU partition.

### Correct interactive Slurm forms

```bash
salloc --partition=gpu_devel \
  --gpus=<gpu_count> \
  --cpus-per-task=<cpu_count> \
  --mem=<host_memory> \
  --time=<walltime>
```

or:

```bash
srun --partition=gpu_devel \
  --gpus=<gpu_count> \
  --cpus-per-task=<cpu_count> \
  --mem=<host_memory> \
  --time=<walltime> \
  --pty bash -i
```

- Do not write `salloc ... --pty`; `--pty` belongs to `srun --pty`.
- Do not automatically request a whole node for interactive work.

## Keep host RAM and GPU VRAM separate

- `--mem`, `--mem-per-cpu`, and CPU-memory requests refer to **host RAM**, not GPU VRAM. They do not increase the memory available on a GPU.
- GPU VRAM is a property of the allocated GPU model. If a workload needs more VRAM, choose a GPU with sufficient per-device memory or, only when the software supports it, shard the workload across multiple GPUs.
- Do not use `--mem-per-gpu`; YCRC documentation states that it does not currently work as intended. Use `--mem` or `--mem-per-cpu` for host RAM.

## Construct valid Slurm GPU requests

For a single-process interactive workload using multiple GPUs on one node, prefer a request shaped like:

```bash
srun -p <partition> \
  --nodes=1 \
  --ntasks=1 \
  --gpus=<gpu_count> \
  --cpus-per-task=<cpu_count> \
  --mem=<host_memory> \
  --time=<walltime> \
  --pty bash -i
```

- `-n` is an alias for `--ntasks`; it is **not** a CPU-count option. Never combine `--ntasks=1` with `-n <cpu_count>` expecting the latter to request CPUs.
- Use `--cpus-per-task` (or `-c`) for CPUs assigned to a task. When CPU requirements naturally scale with GPU count, `--cpus-per-gpu` can be clearer; do not request large CPU counts without a workload reason.
- For distributed launch patterns with multiple Slurm tasks, choose `--ntasks`, `--ntasks-per-node`, `--gpus-per-task`, and CPU counts to match the application's launcher. Do not blindly reuse the single-process example.
- Use `--gpus=<N>` when the important requirement is the total GPU count. Use `--gpus-per-node` when node layout/topology actually matters. Do not add `--nodes=1` or force a whole-node layout merely because GPUs were requested.
- A GPU partition does not itself allocate a GPU. A GPU job must explicitly request the required GPU resources.
- Do not assume `CUDA_VISIBLE_DEVICES` will contain physical GPU IDs such as `0-7`. Slurm controls GPU visibility for the allocation; inspect `CUDA_VISIBLE_DEVICES` and `nvidia-smi` inside the job when device mapping matters.

## Policy uncertainty and support

- Do not infer whether interactive use is permitted from a partition name, GPU model, or current `sinfo` availability.
- If the managed YCRC documentation does not establish whether a requested GPU workflow is permitted, say that the policy needs confirmation rather than guessing.
- For YCRC policy, access, allocation, or system questions requiring administrator assistance, direct the user to the Yale Center for Research Computing (YCRC) at `research.computing@yale.edu`. Do not invent or substitute support contacts.

## GPU utilization and Jobstats policy

- YCRC Jobstats documentation states that, as of 2026, GPU jobs below 10% GPU utilization are terminated.
- Diagnose low utilization rather than evading enforcement: verify GPU visibility/configuration, CUDA/modules/application settings, preprocessing placement, GPU count, and whether the workload needs a GPU at all.
- Do not create fake GPU activity, dummy kernels, busy loops, sleeps, or other behavior intended to retain an idle GPU allocation.
- `sleep` remains legitimate for ordinary polling/backoff/coordination when it is not being used to evade resource enforcement.
- Use `jobstats JOBID` when appropriate to inspect utilization.

For supporting detail and policy context, read `references/gpu-jobstats-policy.md` and the Slurm resource guidance in the `ycrc-slurm` skill.
