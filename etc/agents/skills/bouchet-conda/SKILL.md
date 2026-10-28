---
name: bouchet-conda
description: Use for Miniconda, Conda environments, Python package installation, pip/Conda choices, activation, and Python environment workflows on YCRC Bouchet.
---

# Bouchet Conda and Python

Follow YCRC's Bouchet Conda workflow.

- Use the YCRC `miniconda` module for Conda workflows.
- Create Conda environments and install or update packages in an **interactive session on a compute node**, never on a login node and not as a batch job; this is YCRC's recommended workflow. The agent's own session is such an interactive session, so build small environments there. For a large environment (many packages, CUDA/ML stacks) that needs more than the session's ~1 CPU and 8 GB, give the user the commands to run in a larger interactive session of their own, for example `salloc --partition=devel --cpus-per-task=4 --mem=15G --time=2:00:00`, then `module load miniconda` and the `conda create` line.
- Bouchet does **not** impose a site channel whitelist for Conda. Standard Conda channel behavior is available; use any channels required by the user's environment or package.
- YCRC configures `conda-forge` and `bioconda` as default channels in the Miniconda module.
- **Python packages: Conda for Python and `uv`, then `uv` for everything else.** Create the environment with only Python and `uv` from Conda, activate it, and install all Python packages with `uv pip install`, which is much faster and cleaner than `conda install` or `pip`. Use `conda install` only for what PyPI cannot provide (non-Python software such as bioconda tools, or system libraries). Don't use plain `pip`.
- Use Conda for all Python work. Python and its library modules (Python, SciPy-bundle, PyTorch, and similar) exist as dependencies of other modules, not for users to load directly; don't recommend them. Avoid mixing module-provided Python/R software with Conda-managed software. When using a Conda environment, `miniconda` should normally be the only software module loaded: start from `module reset`, which keeps the `StdEnv` base module (never unload `StdEnv`; it is not a software module and it sets the Conda environment and package locations).
- Agent shell calls are isolated. Load Miniconda, activate the environment, and run the dependent command in the same shell invocation.
- Conda state under the approved user `.conda` area is writable. Do not modify the administrator-managed container image or `/apps`.

Examples:

```bash
module load miniconda && conda create -y -n analysis python=3.12 uv
```

```bash
module load miniconda && conda activate analysis && uv pip install numpy pandas
```

```bash
module load miniconda && conda activate analysis && python analysis.py
```

For production research runs, keep a record that can rebuild the environment: `uv pip freeze > requirements.txt` lists the exact Python packages, alongside the Python version (and any Conda-only packages) used to create it (see `references/conda-python.md`). This is not needed for exploratory work.

For additional YCRC guidance, read `references/conda-python.md`.
