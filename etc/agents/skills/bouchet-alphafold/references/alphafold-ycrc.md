# YCRC source notes: AlphaFold

Derived from `docs/clusters-at-yale/guides/alphafold.md` in the supplied YCRC documentation source.

- AlphaFold should use batch scripts because of its duration/resource profile.
- YCRC requires splitting MSA generation (CPU-only) from model building/inference (GPU) to avoid idle-GPU enforcement.
- `afterok` dependencies can chain the CPU and GPU stages.
- AF2 uses FASTA input; the documented split uses `--msas_only` then `--use_precomputed_msas`.
- AF3 requires users to obtain their own model parameters under Google's terms and place them in a models folder.
- Bouchet AF3 uses JSON input; the split uses `--norun_inference` for the CPU/data-pipeline stage and `--norun_data_pipeline` for GPU inference.
- YCRC configures the AF3 database location through the environment/module.
- Module versions in examples are examples; discover current versions with `module avail AlphaFold/`.
