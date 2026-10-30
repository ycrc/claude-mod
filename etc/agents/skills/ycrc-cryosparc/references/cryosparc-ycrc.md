# YCRC source notes: CryoSPARC

Derived from `docs/clusters-at-yale/guides/cryosparc.md` in the supplied YCRC documentation source.

- YCRC provides `ycrc_get_cryosparc_port.sh` and `ycrc_prepare_cryosparc.sh` (paths in SKILL.md's cluster notes); the docs say these setup steps may run from a login-node terminal.
- `ycrc_launch_cryosparc.sh` launches the master job and provides GUI connection instructions.
- Do not request GPUs for the master job; processing jobs spawned by CryoSPARC request them through compute lanes.
- Processing jobs must specify Maximum runtime.
- `OUT_OF_MEMORY` can be addressed with the CryoSPARC RAM multiplier; YCRC notes 2 may suffice and 4 is conservative.
- Inspect Slurm state plus `P*_J*_slurm.log`, `P*_J*_slurm.err`, `job.log`, and `queue_sub_script.sh`.
- YCRC documents database lock-file recovery only after stopping CryoSPARC, and recommends prompt support contact when snapshot recovery may be needed.
- Topaz integration uses YCRC's `topaz.sh` wrapper (path in SKILL.md's cluster notes).
