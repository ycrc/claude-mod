---
name: bouchet-conda
description: Use for Miniconda, Conda environments, Python package installation, pip/Conda choices, activation, and Python environment workflows on YCRC Bouchet.
---

# Bouchet Conda and Python

Follow YCRC's Bouchet Conda workflow.

- Use the YCRC `miniconda` module for Conda workflows.
- Create Conda environments and install or update packages on a **compute node**, not a login node.
- Bouchet does **not** impose a site channel whitelist for Conda. Standard Conda channel behavior is available; use any channels required by the user's environment or package.
- YCRC configures `conda-forge` and `bioconda` as default channels in the Miniconda module.
- Prefer installing as much as practical with Conda first. If `pip` is needed, use it after the Conda packages are installed.
- Avoid mixing module-provided Python/R software with Conda-managed software. When using a Conda environment, `miniconda` should normally be the only software module loaded.
- Agent shell calls are isolated. Load Miniconda, activate the environment, and run the dependent command in the same shell invocation.
- Conda state under the approved user `.conda` area is writable. Do not modify the administrator-managed container image or `/apps`.

Examples:

```bash
module load miniconda && conda create -n analysis python=3.12 numpy pandas
```

```bash
module load miniconda && conda activate analysis && python analysis.py
```

For additional YCRC guidance, read `references/conda-python.md`.
