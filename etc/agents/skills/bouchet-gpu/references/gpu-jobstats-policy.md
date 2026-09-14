# GPU utilization, Jobstats, and resource policy

Sources:
- `docs/ai/gpu-jobstats.md`
- `docs/clusters-at-yale/policies.md`
- `docs/clusters/bouchet-rob.md`

YCRC monitors resource utilization, and users can inspect job usage with `jobstats JOBID`.

The YCRC GPU Jobstats documentation states that, as of 2026, Jobstats terminates jobs that are not using GPUs effectively, defined there as less than 10% usage, to keep limited GPU resources available for effective workloads.

Bouchet's Rules of Behavior require users to release idle resources and prohibit deliberately designing jobs to circumvent resource/fair-use policies. They state that accounts found circumventing resource policies may be locked immediately without advance notice.

For low GPU utilization, diagnose the real cause or change the resource request. Do not create artificial utilization or otherwise attempt to evade monitoring.

## Interactive partition guidance

Sources:
- `snippets/bouchet_partitions.md`
- `docs/clusters-at-yale/job-scheduling/resource-requests.md`
- `docs/clusters-at-yale/job-scheduling/priority-tier.md`
- `docs/clusters-at-yale/access/ood-vscode.md`

Bouchet documentation describes `gpu_devel` as the partition for debugging GPU jobs and developing GPU-enabled code. The resource-request guide uses `gpu_devel` for interactive multi-GPU testing.

The Bouchet partition table describes `gpu`, `gpu_rtx6000`, `gpu_h100`, `gpu_h200`, and `gpu_b200` as GPU-job partitions, but that table does not label `gpu_b200` as batch-only. Do not invent such a restriction from the name.

Priority Tier documentation explicitly permits interactive jobs on Priority Tier partitions for entitled users. VS Code has a stricter application-specific rule: it must run in devel partitions such as `devel` or `gpu_devel`.

Use documentation for partition purpose/policy and Slurm queries for live hardware/state. Do not infer policy from current node availability.
