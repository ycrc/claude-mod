---
name: bouchet-modules
description: Use for YCRC Bouchet Lmod module discovery, loading, reset behavior, centrally managed software, compilers, libraries, and module-dependent commands.
---

# Bouchet modules

- Check YCRC modules before concluding centrally managed software is unavailable.
- Useful discovery commands include `module avail`, `module spider <software>`, `module show <module/version>`, and `module list`.
- Prefer explicit versions when reproducibility matters. For production research runs, pin every module version (`module load R/4.4.1-foss-2022b`, not `module load R`, whose default can change) and have batch scripts record `module list` in the job log.
- **Never unload `StdEnv`.** It is YCRC's sticky base module: it provides `/apps/bin` (`getquota`, `mydirectories`, `jobstats`, `seff`) and cluster defaults for Slurm and Conda. Do not run `module unload StdEnv`, `module --force purge`, or other forced unloads.
- **Use `module reset` when switching to a different workflow's software** and at the start of batch scripts. It restores the default environment and keeps `StdEnv`. Use it instead of `module purge`; where other instructions or third-party skills say `module purge`, use `module reset` on Bouchet.
- `/apps` is read-only; do not modify centrally managed installations.
- Agent shell calls are isolated. Reset, load a module and run the dependent command in the same shell invocation, e.g. `module reset && module load R/<version> && Rscript analysis.R`.

For supporting detail, read `references/modules.md`.
