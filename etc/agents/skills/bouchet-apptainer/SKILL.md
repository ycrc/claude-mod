---
name: bouchet-apptainer
description: Use for Apptainer/Singularity containers on YCRC Bouchet, including SIF images, build/exec/shell, GPU --nv, bind/contain, environment variables, cache placement, definition files, and container MPI compatibility.
---

# Bouchet Apptainer workflows

Use YCRC's Bouchet container policy and workflow rather than generic Docker assumptions.

## Hard location rule

- **Apptainer is not installed on YCRC login nodes. Run Apptainer commands on compute nodes.**
- If a user tries `apptainer` on a login node, direct them to obtain a Slurm compute allocation or submit a batch job; do not troubleshoot the resulting login-node permission error as a broken installation.
- The coding agent itself already runs inside an administrator-managed Apptainer container. Do **not** use nested Apptainer/Singularity to alter, escape, or work around that containment.
- It is fine to write an Apptainer definition file, inspect an existing recipe, prepare a Slurm script that will invoke Apptainer in the submitted job, or otherwise help the user's normal compute-node workflow.

## Images and basic execution

- Apptainer images are normally single read-only `.sif` files.
- Use an existing image when it satisfies the workload; images may be built/pulled from registries such as Docker Hub or NVIDIA's container registry.
- Common forms on a compute node:

```bash
apptainer build image.sif docker://repository/image:tag
apptainer shell --shell /bin/bash image.sif
apptainer exec image.sif command args...
```

- Container images can be large. If cache use would pressure home storage, use an appropriate persistent/scratch location and set `APPTAINER_CACHEDIR` deliberately; use `bouchet-storage` for Bouchet storage policy.

## GPUs

- GPU applications need the appropriate software stack inside the image and the host driver integration supplied by `--nv`.

```bash
apptainer exec --nv image.sif python gpu_program.py
```

- A container flag does not allocate a GPU. The Slurm job must separately request GPU resources. Use `bouchet-gpu` for GPU sizing and partition policy.
- Interactive GPU work follows the Bouchet GPU policy in `bouchet-gpu`; do not use Apptainer as a reason to route interactive work to a production GPU partition.

## Home, containment, and binds

- By default, ordinary user Apptainer runs normally expose the user's home. `--contain` changes that behavior.
- When `--contain` is needed, explicitly bind only the paths the workload requires with `--bind`.
- Do not infer that the coding-agent container's restricted bind policy applies to a separately submitted user Slurm job. Conversely, do not use user Apptainer options to weaken the coding-agent container's administrator-managed restrictions.

## Environment variables

To pass a host environment variable into an ordinary Apptainer container, YCRC documents the `APPTAINERENV_` prefix:

```bash
export APPTAINERENV_BLASTDB=/path/to/db
apptainer exec image.sif env | grep BLAST
```

Inside the container the variable is named `BLASTDB`.

The coding-agent launcher intentionally scrubs `APPTAINERENV_*` and related variables before launching its own managed container. Do not try to bypass that control.

## Definition files

- Definition files can specify the bootstrap image plus sections such as `%labels`, `%files`, `%post`, and `%environment`.
- Build a definition file on a compute node:

```bash
apptainer build my_app.sif my_app.def
```

- Do not modify `/apps`; it is YCRC-managed and read-only for this agent.

## MPI in containers

YCRC notes that MPI use with Apptainer requires compatible MPI versions inside the container and on the cluster. Do not assume an arbitrary container MPI stack will work across nodes. Route MPI-specific resource and compatibility questions to `bouchet-mpi`.

For YCRC-derived detail, read `references/apptainer-ycrc.md`.
