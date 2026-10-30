---
name: ycrc-r
description: Use for R modules, R package availability and installation, external library dependencies, and R workflows on YCRC clusters.
---

# R on YCRC clusters

Load the `ycrc-modules` skill too: its rules for finding, loading and resetting modules apply here.

- R and many preinstalled packages are available as modules; users can also install R in Conda environments (follow `ycrc-conda`).
- Prefer module-provided R when appropriate. If a task needs R and none is loaded, load the most recent module version.
- Check whether required packages and dependencies are already available before installing copies.
- Install user R packages on compute nodes into user-writable library locations (`R_LIBS_USER` or another user-writable path).
- If an R package needs an external library, check the YCRC module system first.
- For Conda-based R, follow the Conda workflow rather than mixing an unrelated module R stack into the same environment.
- For MPI-based R workloads, prefer the module-provided R stack.
- Agent shell calls are isolated; load R and run the dependent command together.
- For production research runs, pin the R module version and keep `renv.lock` (or `sessionInfo()` output) with the results.

## R module structure

- `R/<version>` actually loads `R/<version>-meta`, which loads `-bare` (EasyBuild's plain R), `-bundle-cran` and `-bundle-bioconductor` (the preinstalled packages).
- Only return or suggest modules that `module avail` shows, and never those ending in `-meta` or `-bare`.

## Which R versions are available, and which is loaded

```bash
module -t --redirect avail R/ | grep '^R/' | grep -vE '(-bare|-meta)$'
```

A new session has no R loaded; the versions available are not the version loaded. `R --version` shows the loaded R; if R is not found, none is loaded.

## Packages

- Find which R module provides a package with `module -t --redirect spider <package>` (the one use of `spider`: packages are module extensions, which `module avail` does not list).
- Packages installed in a Conda environment apply only to the R in that environment, not to the modules.
- Before installing a package, check whether it is already available in a loaded R module or Conda environment, and don't install it unless a newer version is needed.
- If no CRAN repository is set, use https://cloud.r-project.org.
- In the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`), the launcher sets `RENV_PATHS_CACHE` to `~/R/renv-cache` (unless the user has set it), because the container's home is temporary and only `~/R` persists. Use `renv::restore()` / `renv::snapshot()` as usual and keep `renv.lock` with the project.

For supporting detail, read `references/r.md`.
