# GPU partitions and resource policy on Bouchet

Sources:
- `docs/clusters/bouchet-rob.md`
- `snippets/bouchet_partitions.md`

Bouchet's Rules of Behavior require users to release idle resources and prohibit deliberately designing jobs to circumvent resource/fair-use policies. They state that accounts found circumventing resource policies may be locked immediately without advance notice.

Bouchet documentation describes `gpu_devel` as the partition for debugging GPU jobs and developing GPU-enabled code.

The Bouchet partition table describes `gpu`, `gpu_rtx6000`, `gpu_h100`, `gpu_h200`, and `gpu_b200` as GPU-job partitions, but that table does not label `gpu_b200` as batch-only. Do not invent such a restriction from the name.
