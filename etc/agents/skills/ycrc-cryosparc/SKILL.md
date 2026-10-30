---
name: ycrc-cryosparc
description: Use for CryoSPARC setup, launch, compute lanes, runtime/memory settings, GPU/CUDA issues, Topaz, Slurm diagnosis, and CryoSPARC database troubleshooting on YCRC clusters.
---

# YCRC CryoSPARC workflows

Use YCRC's managed CryoSPARC workflow rather than inventing a generic standalone installation.

## Setup and launch

- A CryoSPARC license is required.
- Request the YCRC CryoSPARC port from a cluster terminal with YCRC's port-request helper (`ycrc_get_cryosparc_port.sh`; its path is in the cluster notes below).
- After the license and port are available, use YCRC's installer (`ycrc_prepare_cryosparc.sh`; path in the cluster notes below).
- YCRC documentation explicitly says the port request and setup/install helper may be run from a **login-node terminal**.
- Launch/reconnect with `ycrc_launch_cryosparc.sh`, following the helper's printed connection instructions.
- Do not replace this workflow with an ad-hoc CryoSPARC service installation.

## Master job versus compute jobs

- **Do not request GPUs for the CryoSPARC master job.** GPU resources are used by batch jobs spawned from the CryoSPARC process.
- Private partitions may be passed to the YCRC launch helper when the user actually has access; do not invent account/partition names.
- CryoSPARC processing jobs are submitted through YCRC-configured compute lanes.

## Compute-lane submissions

- Select the lane appropriate to the processing job.
- **Always specify a suitable `Maximum runtime`** in CryoSPARC's Cluster submission script variables. Missing/insufficient runtime is a common cause of `TIMEOUT`.
- CryoSPARC's memory estimate can be too small. If Slurm reports `OUT_OF_MEMORY`, increase the CryoSPARC `RAM multiplier`; YCRC notes that 2 often suffices and 4 is a conservative value.
- Large particle counts and large box sizes can increase memory pressure.
- Monitor both the CryoSPARC GUI and Slurm (`squeue --me`, accounting/job tools).

## Priority Tier

CryoSPARC can expose Priority Tier lanes for users who have purchased access. **Never select, submit to, or move a CryoSPARC job to a paid Priority Tier lane/partition without the explicit confirmation required by `ycrc-priority`.**

Moving a job to a Priority Tier partition with `scontrol update JobId=<jobid> Partition=<priority partition>` (the cluster notes below give the documented example) is a billable action and therefore requires confirmation first.

## Troubleshooting processing jobs

Diagnose from Slurm state and the CryoSPARC job directory rather than guessing:

- `TIMEOUT` -> increase/adjust Maximum runtime.
- `OUT_OF_MEMORY` -> increase RAM multiplier/resource request.
- Immediate accounting/QOS rejection -> requested runtime/memory may not fit the lane/partition; do not blindly change QOS to force acceptance.
- Inspect the job directory's Slurm logs, `job.log`, and `queue_sub_script.sh` for concrete evidence.
- For lightweight debugging of GPU processing, `gpu_devel` is the appropriate interactive/development partition; do not turn a production GPU lane into an interactive allocation.

## Database problems

If the CryoSPARC master job is running but components/database are not healthy:

1. Check `cryosparcm status` on the master compute node.
2. Try a clean `cryosparcm stop` then `cryosparcm start`.
3. If database lock corruption is indicated, follow the YCRC lock-file recovery procedure carefully and **stop CryoSPARC before removing lock files**.
4. If recovery is uncertain or snapshots may be needed, contact YCRC promptly at `research.computing@yale.edu`; snapshot retention makes delay undesirable.

Do not perform destructive database recovery casually or delete an existing database without preserving/recovering it according to YCRC guidance.

## Topaz

For YCRC's CryoSPARC integration, use the documented Topaz executable given in the cluster notes below.

## On Bouchet

- Port request helper, run from a cluster terminal (a login-node terminal is fine):

  ```bash
  /apps/services/cryosparc/ycrc_get_cryosparc_port.sh
  ```

- YCRC's installer, after the license and port are available:

  ```bash
  /apps/services/cryosparc/ycrc_prepare_cryosparc.sh
  ```

- Documented Topaz executable for YCRC's CryoSPARC integration:

  ```text
  /apps/services/cryosparc/topaz.sh
  ```

- The documented Priority Tier move is the following; it is a billable action and requires confirmation first (`ycrc-priority`):

  ```bash
  scontrol update JobId=<jobid> Partition=priority_gpu
  ```

- The production GPU lane is `gpu`; do not turn it into an interactive allocation (use `gpu_devel` for lightweight debugging).
- YCRC documentation notes newer Bouchet GPUs require CryoSPARC >= 5.0.0 for compatibility with affected GPU jobs.

For YCRC-derived detail, read `references/cryosparc-ycrc.md`.
