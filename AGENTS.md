# YCRC Bouchet coding-agent instructions

These are administrator-provided instructions for coding agents running on the Yale Center for Research Computing (YCRC) Bouchet cluster. Follow them unless a YCRC administrator provides newer instructions.

## Bouchet skills

Detailed Bouchet workflows are installed as administrator-owned skills under `/etc/agents/skills/`. Use the relevant skill when a task involves storage, modules, Conda/Python, R, Slurm, or GPUs. Do not load every skill at startup.

Available skills include:
- `bouchet-storage`
- `bouchet-modules`
- `bouchet-conda`
- `bouchet-r`
- `bouchet-slurm`
- `bouchet-gpu`

## Mandatory coding-agent controls

- You are running on YCRC Bouchet inside an administrator-managed Apptainer container.
- Respect the container, filesystem, scheduler, and resource boundaries. Do not weaken, bypass, escape, or work around them.
- Do not read or expose credentials, SSH keys, token files, shell histories, or unrelated users' or projects' data.
- Do not attempt to circumvent YCRC resource policies or monitoring.
- Do not keep an otherwise idle GPU allocation alive with `sleep`, dummy work, artificial GPU activity, busy loops, or similar evasion techniques.
- Do not artificially extend scratch-file lifetime by touching timestamps, repeatedly copying files, or similar techniques solely to defeat expiration.
- `/apps` is centrally managed and must be treated as read-only. Do not modify it.

These coding-agent restrictions supplement YCRC policy. If a requested action conflicts with them, do not perform it; explain the constraint and suggest a compliant workflow.

## Normal-user autonomy profile

This module is for ordinary Bouchet user accounts and is intentionally configured for high autonomy inside the administrator-managed containment boundary. Routine user-scoped operations such as file deletion, process termination, Slurm submission, and cancellation of jobs the user is authorized to cancel may run without an approval prompt.

Autonomy does not expand privileges. Unix permissions, Slurm authorization, the launcher bind policy, read-only mounts, and the rules in this file still apply. Never act on another user's jobs or data. Privileged YCRC administrator workflows require a separate administrative agent profile and are not part of this module.

## Shell tool calls are isolated

Assume each shell/Bash tool invocation starts in a fresh shell. Environment changes from one tool call do not persist into later tool calls. This includes module changes, `conda activate`, `source`, `export`, aliases, shell functions, and shell-local directory changes.

Always perform environment setup and the dependent command in the same shell invocation, preferably chained with `&&`.

Correct:

```bash
module load R/<version> && Rscript analysis.R
```

```bash
module load miniconda && conda activate myenv && python analysis.py
```

Incorrect: load a module or activate an environment in one tool call and assume it remains active in a later call.

## Filesystem boundaries

Bouchet home directories are `/home/<netid>`. The interactive coding agent intentionally does not expose the user's general home directory; only explicitly approved state/software locations and the selected working directory are bound into the container.

Writable Roberts workspaces are restricted by this launcher to user-specific paths under project, scratch, or PI storage whose path contains the user's NetID after an authorized group directory. Do not traverse or write another user's sibling directory even if a broader group directory is visible. Use the `bouchet-storage` skill for storage discovery and path guidance.

Bouchet scratch files are subject to a 30-day purge. Do not manipulate timestamps or otherwise evade scratch expiration.

Missing paths can be intentional containment boundaries. Do not search for alternate mounts or try to bypass containment. Writes to unbound locations inside the container may be ephemeral; do not claim work is durably saved unless it is written to a persistent bound location.

## Network access

Bouchet provides Internet access, and this coding-agent policy does not prohibit normal user-level Internet access. Network tools may be used when appropriate and permitted by YCRC policy. Do not attempt to bypass network controls or expose credentials.

The launcher may disable a harness's own telemetry, update checks, or automatic external-provider traffic. Those harness-specific settings do not mean that Bouchet itself is offline and do not prohibit ordinary network access from allowed shell commands.

## Slurm execution boundary

The coding-agent launcher requires an active Slurm allocation and verifies that the current host belongs to it. Use Slurm for computational work; do not perform compute-heavy work on login or transfer nodes.

`sbatch` and `srun` use is intentional. A Slurm job launched by an agent runs under the user's normal cluster account outside the interactive agent's Apptainer filesystem sandbox. Do not assume the interactive container's filesystem restrictions carry into that job. Use the `bouchet-slurm` skill for resource requests and job workflows.

Never kill or signal jobs or processes belonging to another user.

For this normal-user deployment, `admintest` is never an allowed Slurm target. Do not recommend it, test against it, or submit jobs to it. Priority partitions may be recommended when appropriate, but confirm the current user is entitled to use a priority partition before actually submitting there.

## GPU utilization and enforcement

Do not defeat, delay, or interfere with YCRC GPU-utilization enforcement. In particular, do not add `sleep`, fake GPU work, dummy kernels, busy loops, or other activity whose purpose is to make an idle allocation appear productive.

`sleep` itself is not prohibited when it serves a legitimate workflow purpose such as polling, backoff, or coordination. It is prohibited when used to evade resource enforcement.

Use the `bouchet-gpu` skill for Jobstats thresholds, diagnostics, and compliant remediation.

## Container lifecycle

The coding-agent image is administrator managed. Do not self-update or reinstall the agent harnesses, modify `/etc` or `/usr`, invoke nested Apptainer/Singularity to escape restrictions, or add unauthorized host binds.

If centrally managed software is missing, use supported modules or user-environment workflows rather than altering the image. Use the relevant Bouchet skill for detailed guidance.
