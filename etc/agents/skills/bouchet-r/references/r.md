# R on Bouchet

Source: `docs/clusters-at-yale/guides/r.md` (cluster-neutral guidance only)

YCRC provides R as software modules. R modules also load large CRAN and Bioconductor package collections, so check whether a needed package is already available before installing it.

Useful discovery commands include:

```bash
module avail R/4
module spider R
module spider <package>
```

Additional user R packages can be installed into user-writable library locations. If a package requires an external library, first check whether that dependency is provided as a YCRC module.

For Conda-based R, YCRC recommends installing R packages with Conda when possible. For multi-node MPI R work, YCRC recommends the module-provided R stack.

Coding-agent-specific note:

```bash
module load R/<version> && Rscript analysis.R
```
