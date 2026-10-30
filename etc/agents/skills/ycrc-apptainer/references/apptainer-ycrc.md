# YCRC source notes: Apptainer

Derived from `docs/clusters-at-yale/guides/containers.md` in the supplied YCRC documentation source.

- Apptainer is not installed on login nodes; use compute nodes.
- Images are normally read-only `.sif` files.
- YCRC examples use `apptainer build`, `shell`, and `exec`.
- `APPTAINER_CACHEDIR` can relocate the image cache away from home.
- GPU applications use `--nv` for host NVIDIA driver integration.
- `--contain` changes normal home visibility and may require explicit `--bind`.
- Host variables can be passed with the `APPTAINERENV_` prefix.
- Definition files use sections such as `%labels`, `%files`, `%post`, `%environment`.
- MPI in Apptainer requires compatible MPI versions inside the image and on the cluster.
