---
name: ycrc-easybuild-admin
description: Use when asked to build, install, update, or test centrally provided software or modules on YCRC clusters with EasyBuild (easyconfigs, eb, ycrc-ebfiles, /apps modules). For YCRC administrators only; checks the account and working directory first.
---

# YCRC EasyBuild (YCRC administrators)

## Step 1: gate (always, before anything else)

This skill's scripts are in its `scripts/` directory, next to this `SKILL.md`; below, `<skill-dir>` is the directory this skill was loaded from (your harness shows it when it loads the skill, and the cluster facts below may give it). Run, in the agent's working directory:

```bash
<skill-dir>/scripts/check-admin-env.sh
```

- **Exit 10 (`NOT-SUPPORT`)**: stop. Central software on YCRC clusters is installed by YCRC.
  Tell the user to request it by emailing a ticket to **research.computing@yale.edu**
  (software name, version, and any build requirements). Do not attempt the build.
  For personal installs, the conda/Python and R skills cover user-space options.
- **Exit 11 (`NOT-EBFILES`)**: stop. A sandboxed agent only sees the directory it was
  launched from, so EasyBuild cannot reach the YCRC hooks and configs from here. Tell
  the user to exit, `cd` to their clone of `github.com/ycrc/ycrc-ebfiles` (the
  repository root), and relaunch the coding agent there. If they have no clone:
  `git clone git@github.com:ycrc/ycrc-ebfiles.git` first.
- **Exit 0 (`OK`)**: continue.

## On Bouchet

### In the local-coding-agents sandbox (`YCRC_LOCAL_CODING_AGENTS=1`)

- `<skill-dir>` is `/etc/agents/skills/ycrc-easybuild-admin`.

## Step 2: hard rules

- **Never install into `/apps`.** It is read-only in agent sandboxes; agents prepare and
  test-build only. The final production build is run by the administrator, outside the
  agent. Give them the exact command (see references).
- **Never edit files under `easyconfigs/`.** EasyBuild copies each successfully built
  easyconfig there automatically (`repositorypath`). Work in `software_builds/<name>/`.
- Toolchain generation for new builds is **2024a** (e.g. `foss/2024a`,
  `GCCcore-13.3.0`). Lmod, Lua module syntax.
- Agent shell calls are isolated: `source` the test environment and run `eb` in the
  **same** command. Never pipe `module load` (a pipe runs it in a subshell and the load
  is lost).

## Step 3: workflow

1. **Search** this clone first (`easyconfigs/`, `grep -ril <name> easyconfigs`), then the
   community repository bundled with EasyBuild (`eb --search <name>` after sourcing the
   test environment). A config from another cluster may need adapting to 2024a.
2. **Copy** the starting point to `software_builds/<name>/` and adapt it there.
3. **Dry run** here, then **test build as a Slurm job**:

   ```bash
   source <skill-dir>/scripts/eb-test-env.sh && \
     eb software_builds/<name>/<file>.eb --robot -D
   source <skill-dir>/scripts/eb-test-env.sh && \
     SBATCH_PARTITION=day eb software_builds/<name>/<file>.eb --robot \
       --job --job-backend=Slurm --job-cores 5 --job-max-walltime 24
   ```

   Never compile inside the agent shell: an agent sandbox image lacks the compute nodes' OS
   development packages, so builds fail there that would succeed on a node. `--job`
   runs each build on a real node (one job per easyconfig, chained by dependency).
   Use `day` (or `devel` for quick ones); `admintest` is not an allowed target for
   agents.
   Watch with `squeue --me`. Job output is in `software_builds/test-install/job-output/`;
   logs of failed builds stay in `software_builds/test-install/logs/` (successful builds
   keep theirs under the install's `easybuild/` directory). Everything installs
   under `software_builds/test-install/` (kept out of git); nothing touches `/apps` or
   `easyconfigs/`.
4. **Verify** from the test tree: `module use software_builds/test-install/modules/all`,
   load it, run the software, and confirm `sanity_check_commands` check the version.
5. **Hand off**: summarise the easyconfig, test results, and the production command for
   the administrator to run outside the agent.

For easyconfig conventions, checksums, hidden modules and bundles, rebuilding software
that is in use, and the production hand-off, read `references/easybuild-admin.md`.
