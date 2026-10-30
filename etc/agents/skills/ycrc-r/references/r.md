# R on YCRC clusters

Source: `docs/clusters-at-yale/guides/r.md`

YCRC provides R as software modules. R modules also load large CRAN and Bioconductor package collections, so check whether a needed package is already available before installing it.

Useful discovery commands include:

```bash
module avail R/4
module -r avail '^R/'      # all R versions
module spider <package>    # which R module provides a package
```

Additional user R packages can be installed into user-writable library locations. If a package requires an external library, first check whether that dependency is provided as a YCRC module.

For Conda-based R, YCRC recommends installing R packages with Conda when possible. For multi-node MPI R work, YCRC recommends the module-provided R stack.

## renv in the coding-agent sandbox

This applies only in the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`). There, the home directory is a small temporary filesystem: anything written there outside the bound state directories is lost when the session ends. renv's default package cache (`~/.cache/R/renv`) would therefore be rebuilt every session and could fill that space. The launcher sets `RENV_PATHS_CACHE=~/R/renv-cache`, inside the persistent `~/R` directory, unless the user has already set `RENV_PATHS_CACHE`. A user-set location must itself be visible in the container (for example under the working directory) to persist.

```bash
module load R/<version> && Rscript analysis.R
```
