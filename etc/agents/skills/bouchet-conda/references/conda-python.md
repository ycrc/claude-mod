# Conda and Python reference for Bouchet

Source material supplied with this build:
- `docs/clusters-at-yale/guides/conda.md`
- `docs/clusters-at-yale/guides/python.md`

YCRC provides Miniconda as a module. Environment creation and package installation can perform substantial dependency resolution and must be done on a compute node rather than a login node.

YCRC recommends against heavily mixing Conda and pip. Install as much as practical with Conda first, then use pip when needed. YCRC also warns that mixing normal software modules with Conda-managed software is almost never appropriate; `miniconda` should normally be the only software module loaded for a Conda workflow.

The YCRC Miniconda configuration includes `conda-forge` and `bioconda` as default channels. Bouchet does not impose a site channel whitelist; other Conda channels may be used when the workflow requires them.

Because coding-agent Bash invocations do not preserve shell state, keep setup and execution together. For example:

```bash
module load miniconda && conda activate myenv && python analysis.py
```

For environment creation or package installation, remain in a Slurm compute allocation. Do not move these operations to a login node. The coding agent's own allocation is small; submit large environment builds with `sbatch`.

## Recording an environment for production runs

For results that will be kept or published, record the environment in a file such as `environment.yml` kept with the project:

```bash
module load miniconda && conda env export -n <env> --from-history > environment.yml
module load miniconda && conda list -n <env> | awk '$NF == "pypi" {print $1 "==" $2}'
```

`--from-history` records the Conda packages that were explicitly requested, without platform-specific builds, but leaves out anything installed with pip. Add the packages from the second command under a `pip:` subsection (with `pip` listed as a dependency):

```yaml
dependencies:
  - python=3.12
  - numpy
  - pip
  - pip:
      - some-pip-only-package==1.2.3
```

When updating an existing hand-maintained `environment.yml`, merge new packages into it rather than overwriting it, and remove any machine-specific `prefix:` line. Exploratory work does not need this.

Bouchet scratch has a 30-day retention policy. If older generic YCRC documentation mentions a different scratch retention period, follow the Bouchet 30-day policy established for this deployment.
