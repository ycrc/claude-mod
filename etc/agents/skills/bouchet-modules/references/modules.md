# Software modules on Bouchet

Source: `docs/applications/modules.md` (Bouchet-relevant guidance only)

YCRC uses Lmod modules for centrally managed software.

Useful commands:

```bash
module avail
module spider <software>
module help <module/version>
module show <module/version>
module list
```

`module load` modifies the current shell environment and loads dependencies as needed. Use explicit module versions for reproducibility when appropriate.

## StdEnv and resetting the environment

`StdEnv` is a sticky module loaded for every user. It puts `/apps/bin` on `PATH` (YCRC utilities such as `getquota`, `getusage`, `mydirectories`, `jobstats`, `seff`) and sets defaults including `SALLOC_PARTITION=devel`, `SLURM_HINT=nomultithread`, `CONDA_ENVS_PATH`, `CONDA_PKGS_DIRS` and the `SQUEUE_FORMAT`/`SACCT_FORMAT` output formats. Removing it breaks those tools and silently changes Slurm and Conda behavior, so it must never be unloaded: no `module unload StdEnv`, `module --force purge`, or `module --force unload`.

Use `module reset` whenever a command needs a different set of modules from the current environment, such as switching between workflows, and at the start of batch scripts. It returns to the system default, which keeps `StdEnv` loaded (and restores it if it was ever removed). YCRC recommends it over `module purge`, which is slower, prints a misleading warning about `StdEnv`, and cannot restore it. Where other instructions or third-party skills say `module purge`, use `module reset` on Bouchet.

```bash
module reset && module load <module>/<version> && <command>
```

## Recording the environment of production runs

For runs whose results will be kept or published, pin explicit module versions and let the job log record what was actually loaded, for example at the top of a batch script:

```bash
module reset
module load <module>/<version>
module list 2>&1
<tool> --version
```

This is for production runs; exploratory commands do not need it.

Do not normally mix Python or R software modules with Conda-managed software; YCRC warns this will almost always break something.

Coding-agent-specific note: every shell tool call is isolated, so combine module setup and execution in the same call, for example:

```bash
module reset && module load R/<version> && Rscript analysis.R
```
