# YCRC EasyBuild reference (Bouchet)

EasyBuild docs: https://docs.easybuild.io. YCRC as-built configs, easyblocks, hooks and
site configs: `github.com/ycrc/ycrc-ebfiles`. Community configs:
`github.com/easybuilders/easybuild-easyconfigs` (also bundled with each EasyBuild
module and on the default robot path). Cluster docs: `github.com/ycrc/ycrc.github.io`.

## Configuration and layout

- Site config: `siteconfigs/bouchet.cfg` (copied to `~/.config/easybuild/config.cfg`
  on admin accounts). Lua modules, Lmod, `minimal-toolchains`, `use-existing-modules`,
  `optarch` x86-64-v4, sources in `/apps/sources`, build in `/dev/shm/$USER`.
- `hooks/ycrc_hooks.py` routes installs by toolchain generation: the configured
  `installpath` base `/apps/software` plus `2024a/`, `2022b/`, or `system/` (SYSTEM
  toolchain, e.g. binary and bundle modules). After a production build its end hook
  rebuilds the Lmod cache (`/apps/custom/lmod/bin/update-cache.sh`).
- **Testing mode**: when `EASYBUILD_INSTALLPATH` is set in the environment the hooks skip
  generation routing and the cache rebuild. `scripts/eb-test-env.sh` uses this, and also
  redirects `repositorypath` and source downloads, so a test build writes nothing to
  `/apps` or `easyconfigs/`. (Passing `--installpath` on the command line instead keeps
  routing, but still copies the easyconfig into `easyconfigs/` and rebuilds the
  production Lmod cache. Avoid it for tests.)
- Inside the coding-agent sandbox the user's `~/.config/easybuild` is not visible;
  EasyBuild would silently fall back to defaults under `~/.local/easybuild`. Always use
  `eb-test-env.sh`. It also:
  - runs `module reset` first, keeping `StdEnv` (as `testing()` cleans up): with `detect-loaded-modules = purge`
    EasyBuild otherwise purges the agent's own module and its own `PATH` with it, and
    `--job` builds then fail with `eb: command not found`;
  - keeps EasyBuild logs in `software_builds/test-install/logs/`, because the
    container's `/tmp` and `/dev/shm` vanish when the agent exits;
  - falls back to `LC_ALL=C.UTF-8` if the session's locale is missing (a `setlocale`
    warning on stderr breaks EasyBuild's `ulimit -u` check).
- Compile only through `--job`. The sandbox image is not a build host: it lacks the
  compute nodes' development packages (even `C compiler cannot create executables`
  for GCCcore builds). Dry runs (`-D`), `--search`, checksum injection and editing are
  fine in the sandbox.

## Easyconfig conventions

- File names `<name>-<version>[-<toolchain>][<suffix>].eb`; the robot finds
  dependencies only by that name (or when all needed files are passed on one command).
- Version-specific source filenames, so cached generic downloads cannot collide:

  ```python
  sources = [{
      'filename': '%(name)s-%(version)s-x86_64-unknown-linux-gnu.tar.gz',
      'download_filename': '%(name)s-x86_64-unknown-linux-gnu.tar.gz',
  }]
  ```

- Sanity checks must prove the installed version:

  ```python
  sanity_check_commands = ["uv --version | grep %(version)s"]
  ```

- Checksums: `eb <file>.eb --inject-checksums --force` (alias `ebinject`). It writes a
  `<file>.eb.bak_<timestamp>` backup beside the file; delete only the backups that run
  created, never a wildcard over older `.bak` files. If verification fails because a
  cached source has the wrong checksum, re-download with `--force` or fix the filename.

## Hidden modules and bundles

- `hidden = True` installs the module as `<name>/.<version>.lua`: absent from
  `module avail`, still loadable by full name (`module load name/.1.0`).
- A visible bundle over hidden parts (`easyblock = 'Bundle'`) must list them in
  `dependencies` AND `hiddendependencies` (`hiddendependencies = dependencies`), or
  EasyBuild errors with "Hidden deps ... not in list of (build)dependencies".
- To hide an existing installed module without deleting it (administrator, outside the
  agent): rename `…/modules/all/<name>/<version>.lua` to `.<version>.lua`, then run
  `/apps/custom/lmod/bin/update-cache.sh`.

## Rebuilding software that is in use

`--rebuild` of an installed version rewrites files that running jobs and sessions may
have open or mounted. Prefer a new version installed alongside (the old one stays for
rollback and Lmod's default moves to the newest). If an in-place rebuild is required,
the administrator must first confirm nothing is using it; for `local-coding-agents` use
`/apps/services/coding-agents/bin/agents-in-use.sh` (or `rebuild-when-idle.sh`).

## Production hand-off (administrator, outside the agent)

From the ycrc-ebfiles clone on a host shell (never from inside the agent):

```bash
module load EasyBuild/5.4.0
eb software_builds/<name>/<file>.eb --robot            # interactive, small builds
build software_builds/<name>/<file>.eb                 # siteconfigs/bashrc alias: Slurm job on admintest
```

Do not set `EASYBUILD_INSTALLPATH` (that is testing mode). On success EasyBuild copies
the easyconfig into `easyconfigs/` and the hook rebuilds the Lmod cache; commit the
as-built easyconfig from there.
