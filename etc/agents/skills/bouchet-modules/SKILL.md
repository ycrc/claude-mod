---
name: bouchet-modules
description: Use for YCRC Bouchet Lmod module discovery, loading, reset behavior, centrally managed software, compilers, libraries, and module-dependent commands.
---

# Bouchet modules

- Check YCRC modules before concluding centrally managed software is unavailable.
- Useful discovery commands include `module avail`, `module spider <software>`, `module show <module/version>`, and `module list`.
- Prefer explicit versions when reproducibility matters.
- YCRC recommends `module reset` rather than `module purge` when resetting the environment.
- `/apps` is read-only; do not modify centrally managed installations.
- Agent shell calls are isolated. Load a module and run the dependent command in the same shell invocation, e.g. `module load R/<version> && Rscript analysis.R`.

For supporting detail, read `references/modules.md`.
