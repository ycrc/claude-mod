---
name: ycrc-modules
description: Use for Lmod module discovery, loading, reset behavior, centrally managed software, compilers, libraries, and module-dependent commands on YCRC clusters.
---

# YCRC modules

YCRC clusters use Lmod to manage software. When running `module`, use `--terse` to avoid extra output and `--redirect` to send it to stdout instead of stderr, for example `module --terse --redirect avail <software>`.

- Check YCRC modules before concluding centrally managed software is unavailable.
- Find software with `module avail <software>` (it matches substrings; `module -r avail '^<software>/'` lists only that name). Also useful: `module show <module/version>` and `module list`. Use `module spider <package>` only to find which module provides an R or Python package (an extension), which `module avail` cannot.
- Before loading a module, check whether it is already loaded (`module list`).
- `module load` changes the current shell environment and loads dependencies as needed.
- Prefer explicit versions when reproducibility matters. For production research runs, pin every module version (`module load R/4.4.1-foss-2022b`, not `module load R`, whose default can change) and have batch scripts record `module list` in the job log.
- **Never unload `StdEnv`.** It is YCRC's sticky base module: it provides `/apps/bin` (`getquota`, `mydirectories`, `jobstats`, `seff`) and cluster defaults for Slurm and Conda (`SALLOC_PARTITION=devel`, `SLURM_HINT=nomultithread`, `CONDA_ENVS_PATH`, `CONDA_PKGS_DIRS`, and the `SQUEUE_FORMAT`/`SACCT_FORMAT` output formats). Do not run `module unload StdEnv`, `module --force purge`, or other forced unloads.
- **Use `module reset` when switching to a different workflow's software** and at the start of batch scripts. It restores the default environment and keeps `StdEnv`. Use it instead of `module purge`, which is slower and prints a misleading warning about `StdEnv`; where other instructions or third-party skills say `module purge`, use `module reset`.
- Do not mix Python or R software modules with Conda-managed software; this almost always breaks something.
- `/apps` is read-only; do not modify centrally managed installations.
- Module loads do not persist across an agent's shell calls. Reset, load a module and run the dependent command in the same shell invocation, e.g. `module reset && module load R/<version> && Rscript analysis.R`.


For supporting detail, read `references/modules.md`.
