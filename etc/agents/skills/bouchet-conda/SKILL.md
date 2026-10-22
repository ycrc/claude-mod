---
name: bouchet-conda
description: Use for Miniconda, Conda environments, Python package installation, pip/Conda choices, activation, and Python environment workflows on YCRC Bouchet.
---

# Bouchet Conda and Python

Follow YCRC's Bouchet Conda workflow.

- Use the YCRC `miniconda` module for Conda workflows.
- Create Conda environments and install or update packages on a **compute node**, not a login node. Small environments can be built in the agent's own session; large solves (many packages, CUDA/ML stacks) should run as a batch job, since the session's allocation is small.
- Bouchet does **not** impose a site channel whitelist for Conda. Standard Conda channel behavior is available; use any channels required by the user's environment or package.
- YCRC configures `conda-forge` and `bioconda` as default channels in the Miniconda module.
- Prefer installing as much as practical with Conda first. If `pip` is needed, use it after the Conda packages are installed.
- Avoid mixing module-provided Python/R software with Conda-managed software. When using a Conda environment, `miniconda` should normally be the only software module loaded: start from `module reset`, which keeps the `StdEnv` base module (never unload `StdEnv`; it is not a software module and it sets the Conda environment and package locations).
- Agent shell calls are isolated. Load Miniconda, activate the environment, and run the dependent command in the same shell invocation.
- Conda state under the approved user `.conda` area is writable. Do not modify the administrator-managed container image or `/apps`.

Examples:

```bash
module load miniconda && conda create -n analysis python=3.12 numpy pandas
```

```bash
module load miniconda && conda activate analysis && python analysis.py
```

For production research runs, keep an environment record that can rebuild the environment: `conda env export --from-history` lists the Conda packages that were explicitly requested but **omits pip-installed packages**, so record those too (see `references/conda-python.md`). This is not needed for exploratory work.

For additional YCRC guidance, read `references/conda-python.md`.
