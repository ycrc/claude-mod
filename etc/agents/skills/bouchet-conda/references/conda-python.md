# Conda and Python reference for Bouchet

Source material supplied with this build:
- `docs/clusters-at-yale/guides/conda.md`
- `docs/clusters-at-yale/guides/python.md`

YCRC provides Miniconda as a module. Environment creation and package installation can perform substantial dependency resolution and must be done on a compute node rather than a login node.

The recommended workflow for Python packages keeps Conda minimal: create the environment with only Python and `uv` from Conda, then install every Python package with `uv pip install` in the activated environment, which is much faster and cleaner than `conda install` or `pip`. Use `conda install` only for what PyPI cannot provide (non-Python software such as bioconda tools, or system libraries), and avoid plain `pip`.

```bash
module load miniconda && conda create -y -n myenv python=3.12 uv
module load miniconda && conda activate myenv && uv pip install numpy pandas matplotlib
```

If an existing environment has no `uv`, add it with `conda install -y uv` first. YCRC also warns that mixing normal software modules with Conda-managed software is almost never appropriate; `miniconda` should normally be the only software module loaded for a Conda workflow.

The YCRC Miniconda configuration includes `conda-forge` and `bioconda` as default channels. Bouchet does not impose a site channel whitelist; other Conda channels may be used when the workflow requires them.

Because coding-agent Bash invocations do not preserve shell state, keep setup and execution together. For example:

```bash
module load miniconda && conda activate myenv && python analysis.py
```

For environment creation or package installation, use an interactive session on a compute node (`salloc`, or an Open OnDemand Remote Desktop), as YCRC's Conda guide recommends; not a login node and not a batch job. The coding agent's own session counts and suits small environments; for large builds, give the user the commands to run in a larger `salloc` session (for example `salloc --partition=devel --cpus-per-task=4 --mem=15G --time=2:00:00`).

## Recording an environment for production runs

For results that will be kept or published, record the environment in files kept with the project: the exact Python packages from `uv`, and the Python version (plus any Conda-only packages) the environment was created with:

```bash
module load miniconda && conda activate <env> && uv pip freeze > requirements.txt
module load miniconda && conda env export -n <env> --from-history > environment.yml
```

To rebuild it: `conda create -y -n <env> python=<version> uv` (plus any Conda-only packages from `environment.yml`), then `conda activate <env> && uv pip install -r requirements.txt`.

When updating existing hand-maintained files, merge new packages into them rather than overwriting them, and remove any machine-specific `prefix:` line from `environment.yml`. Exploratory work does not need this.

Bouchet scratch has a 30-day retention policy. If older generic YCRC documentation mentions a different scratch retention period, follow the Bouchet 30-day policy established for this deployment.
