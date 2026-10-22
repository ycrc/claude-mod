---
name: bouchet-r
description: Use for R modules, R package availability and installation, external library dependencies, and R workflows on YCRC Bouchet.
---

# Bouchet R

- Use module-provided R when appropriate and check whether required packages/dependencies are already available before installing copies.
- Install user R packages on compute nodes into approved user-writable R library locations.
- If an R package needs an external library, check the YCRC module system first.
- For Conda-based R, follow the Conda workflow rather than mixing an unrelated module R stack into the same environment.
- For MPI-based R workloads, prefer the module-provided R stack.
- Agent shell calls are isolated; load R and execute the dependent command together.
- For projects using renv, the launcher sets `RENV_PATHS_CACHE` to `~/R/renv-cache` (unless the user has set it), because the agent container's home is temporary and only `~/R` persists. Use `renv::restore()` / `renv::snapshot()` as usual and keep `renv.lock` with the project.
- For production research runs, pin the R module version and keep `renv.lock` (or `sessionInfo()` output) with the results.

For supporting detail, read `references/r.md`.
