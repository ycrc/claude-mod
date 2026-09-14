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

For supporting detail, read `references/r.md`.
