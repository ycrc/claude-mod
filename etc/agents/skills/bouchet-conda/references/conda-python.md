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

For environment creation or package installation, remain in a Slurm compute allocation. Do not move these operations to a login node.

Bouchet scratch has a 30-day retention policy. If older generic YCRC documentation mentions a different scratch retention period, follow the Bouchet 30-day policy established for this deployment.
