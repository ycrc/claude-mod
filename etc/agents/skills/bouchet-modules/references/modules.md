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

YCRC recommends `module reset` to unload/reset the module environment; `module purge` is slower and produces a misleading warning about the sticky `StdEnv` module.

Do not normally mix Python or R software modules with Conda-managed software; YCRC warns this will almost always break something.

Coding-agent-specific note: every shell tool call is isolated, so combine module setup and execution in the same call, for example:

```bash
module load R/<version> && Rscript analysis.R
```
