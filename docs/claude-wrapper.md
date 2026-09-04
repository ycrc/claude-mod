# Claude Apptainer wrapper

## Purpose

`eb/claude-wrapper.sh` is the host-side launcher installed as the `claude`
command by EasyBuild. It applies cluster policy, constructs the permitted bind
mounts, and then starts `claude-mod.sif` with Apptainer.

The wrapper is responsible for:

- preventing Claude from running on login nodes;
- limiting the working directory to approved user storage;
- rejecting hidden and administratively restricted working directories;
- exposing only configured host paths inside the container;
- applying read-only or read-write permissions to configured binds;
- removing configured sensitive environment variables before launch;
- preserving selected Claude state; and
- forwarding command-line arguments to the container runscript.

The wrapper does not install Claude Code. Claude Code and its managed settings
are built into `claude-mod.sif` by `claude-mod.def`.

## Installed layout

EasyBuild installs the following files together in one directory:

```text
claude                  # Executable copy of claude-wrapper.sh
claude-wrapper.sh       # Source wrapper retained for inspection
claude-bind.conf        # Directories to bind and their permissions
claude-path.conf        # Bound tool directories to prepend to container PATH
claude-exclude.conf     # Directories forbidden as working directories
claude-env.conf         # Sensitive environment-variable name patterns
claude-mod.sif          # Apptainer image
```

The wrapper locates every supporting file relative to its own physical
directory. It does not depend on the user's current directory to locate the
image or configuration.

## Runtime requirements

The wrapper expects these environment variables:

- `HOME`: the user's host home directory;
- `USER`: the username; if unset, `id -un` is used; and
- `CLUSTER`: the YCRC cluster name.

It also expects `apptainer`, `hostname`, `realpath`, `groups`, and standard Bash
utilities to be available on the host.

The script uses Bash-specific features, including arrays and lowercase
parameter expansion. It must be run with Bash rather than POSIX `sh`.

## Launch sequence

The wrapper performs these operations in order:

1. Enables `set -euo pipefail` so unexpected command failures, unset
   variables, and pipeline failures stop the launch.
2. Locates the SIF and all four configuration files beside the wrapper.
3. Rejects a host whose short hostname contains `login`, case-insensitively.
4. Requires all configuration files to exist and be readable.
5. Loads `claude-env.conf`, validates its patterns, and unsets matching exported
   environment variables.
6. Creates the required persistent state directories:
   `$HOME/.claude` and `$HOME/.local/share/claude`.
7. Loads and validates `claude-bind.conf`.
8. Loads and validates `claude-path.conf`, retaining entries covered by binds.
9. Loads and validates `claude-exclude.conf`.
10. Selects project and scratch storage bases using `CLUSTER`.
11. Resolves the invocation directory with `realpath -e`.
12. Rejects the working directory if it is configured as a bind or exclusion.
13. Builds the user's allowed home, project, and scratch roots.
14. Enforces the allowed-root, non-hidden-directory, and filesystem-permission
    checks.
15. Verifies that Apptainer and the SIF are available.
16. Enables NVIDIA integration when GPU device nodes are available.
17. Prepends configured tool directories to the container PATH, constructs the
    final bind arguments, and executes `apptainer run`.

Any failed policy or validation check exits before Apptainer is started.

## Login-node protection

The short hostname is obtained with:

```bash
hostname -s
```

The launch is rejected if the lowercase hostname contains `login` anywhere:

```bash
[[ "${host_name,,}" == *login* ]]
```

This covers numbered names such as `login1` and `login2` without hardcoding
particular node numbers.

## Cluster storage mapping

`CLUSTER` determines the storage bases used to find a user's project and
scratch directories:

| Cluster | Project base | Scratch base |
| --- | --- | --- |
| `bouchet` | `/nfs/roberts/project` | `/nfs/roberts/scratch` |
| `grace` | `/gpfs/gibbs/project` | `/vast/palmer/scratch` |
| `mccleary` | `/gpfs/gibbs/project` | `/vast/palmer/scratch` |

An unset or unsupported `CLUSTER` stops the launch.

The wrapper runs `groups` and considers every returned group. It checks for a
user directory under both cluster storage bases using:

```text
<storage-base>/<group>/<username>
```

For example:

```text
/nfs/roberts/project/pi_example/alice
/nfs/roberts/scratch/support/alice
```

Missing group storage directories are ignored. Existing directories are
resolved with `realpath -e` before being used as allowed roots.

## Environment-variable scrubbing

### Why Bash globs are used

`claude-env.conf` uses Bash glob patterns rather than regular expressions.
Globs directly support readable patterns such as `*API*`, require less escaping
than regular expressions, and are sufficient for matching environment-variable
names.

Matching is case-sensitive. For example, `*API*` matches `OPENAI_API_KEY` but
does not match a lowercase name containing `api`. Add a separate lowercase
pattern if both forms should be removed.

### Format

The administrator-controlled file defines an indexed array named
`sensitive_env_patterns`:

```bash
sensitive_env_patterns=(
    '*API*'
    '*TOKEN*'
    '*SECRET*'
    '*PASSWORD*'
    '*PASSWD*'
    '*CREDENTIAL*'
    '*_KEY'
    '*_KEY_*'
    '*COOKIE*'
    '*JWT*'
    '*WEBHOOK*'
    '*CONNECTION_STRING*'
    '*DATABASE_URL*'
    '*DATABASE_URI*'
    '*DSN*'
    '*_PASS'
    '*_PWD'
    'SSH_AUTH_SOCK'
    'KRB5CCNAME'
    'X509_USER_PROXY'
    'KUBECONFIG'
    'DOCKER_AUTH_CONFIG'
)
```

Patterns must be quoted. Without quotes, the shell could expand `*` against
filenames while loading the configuration.

Because this configuration is sourced by Bash, it is executable shell code and
must not be writable by ordinary users.

### Scrubbing process

The wrapper uses the Bash builtin `compgen -e` to enumerate exported
environment-variable names. For each name, it tests every configured glob using
Bash pattern matching:

```bash
[[ "$exported_env_name" == $sensitive_pattern ]]
```

When a name matches, the wrapper:

1. unsets the variable in the wrapper process;
2. prints a warning to standard output containing the variable name; and
3. stops testing additional patterns for that variable.

Example output:

```text
Warning: unset sensitive environment variable: OPENAI_API_KEY
```

Values are never inspected or printed. Since Apptainer is executed from the
same wrapper process, unset variables are not inherited by the container.

Only exported variables are examined. Non-exported shell variables are not
part of a child process's environment and would not be inherited by Apptainer
anyway.

The wrapper rejects an empty pattern. It also rejects any pattern that matches
one of these variables required for correct launcher behavior:

```text
HOME
USER
PATH
CLUSTER
```

This prevents an accidentally broad pattern such as `*` from disabling the
launcher itself. Pattern matching and required-variable protection are both
case-sensitive.

## Bind configuration

### Format

`claude-bind.conf` is an administrator-controlled Bash file that defines an
indexed array named `binds`:

```bash
binds=(
    "$HOME/.claude:rw"
    "$HOME/.local/share/claude:rw"
    "$HOME/.conda:rw"
    "$HOME/.conda/envs:rw"
    "$HOME/.conda/pkgs:rw"
    "$HOME/R:rw"
    "/apps:ro"
    "/tmp"
    "/var/tmp"
)
```

Each element has one of these forms:

```text
/absolute/path
/absolute/path:rw
/absolute/path:ro
```

- No suffix uses Apptainer's default bind mode, which is read-write.
- `:rw` explicitly requests read-write access.
- `:ro` requests read-only access.
- Variables such as `$HOME` are expanded when the file is sourced.

Because the configuration is sourced by Bash, it is executable shell code. It
must be installed in an administrator-controlled location that ordinary users
cannot modify.

### Validation

For each bind entry, the wrapper:

1. separates an optional `ro` or `rw` suffix;
2. requires an absolute path other than `/`;
3. rejects commas because Apptainer treats commas as bind separators;
4. silently skips a missing path, including a dangling symlink;
5. resolves the path with `realpath -e`; and
6. requires the resolved object to be a directory.

Configuring a broad directory has two effects: it exposes that directory in the
container and prevents Claude from starting anywhere in that directory tree.
For example, binding an entire project base would make every project beneath it
invalid as a working directory.

### Symlinks

For a normal directory, the wrapper mounts the resolved host source at the
configured container path.

For a symlink, the wrapper mounts the same host directory twice:

1. at the configured logical path; and
2. at the resolved physical path.

For example, if:

```text
/home/alice/.conda/envs
  -> /nfs/roberts/project/pi_example/alice/conda/envs
```

then this configuration:

```bash
"$HOME/.conda/envs:rw"
```

produces binds equivalent to:

```bash
--bind \
  /nfs/roberts/project/pi_example/alice/conda/envs:/home/alice/.conda/envs:rw

--bind \
  /nfs/roberts/project/pi_example/alice/conda/envs:/nfs/roberts/project/pi_example/alice/conda/envs:rw
```

The first path supports tools using `$HOME/.conda/envs`. The second supports
Conda scripts, metadata, and environment prefixes containing the resolved
absolute project or scratch path. No files are copied; the same host directory
is visible at two container paths.

## Container PATH configuration

`claude-path.conf` defines host tool directories that are prepended to the
container PATH:

```bash
path_entries=(
    "/apps/bin"
    "/opt/slurm/current/bin"
    "/share/admins/bin"
    "/gpfs/gibbs/pi/support/software/bin"
    "/gpfs/gibbs/public/getusage/script"
)
```

Each entry must be an absolute directory other than `/`, must not contain `:`
or `,`, and must be located at or beneath a directory configured in
`claude-bind.conf`. This last check prevents PATH from advertising a host
directory that is absent from the contained filesystem.

Missing entries are silently skipped so one configuration can be used on
multiple clusters without routine warnings. Existing entries are resolved and
must be directories.
Duplicates are removed while preserving configuration order.

The wrapper joins accepted entries with `:` and passes them to Apptainer as:

```bash
--env "PREPEND_PATH=<configured entries>"
```

Apptainer prepends these entries to its standard container PATH. A PATH entry
does not create a bind mount by itself; its installation prefix must also be
present in `claude-bind.conf`. Complete software prefixes are bound read-only
where possible so binaries can access sibling `lib`, `lib64`, `share`, and
configuration directories.

## Working-directory exclusion configuration

`claude-exclude.conf` defines directories that must not be bound and must not be
used as Claude's working directory:

```bash
excluded_workdirs=(
    "$HOME/ondemand"
)
```

Entries must be absolute directories other than `/`. Variables such as `$HOME`
are expanded when the file is sourced.

For each entry, the wrapper:

- skips a missing path with a warning;
- resolves symlinks using `realpath -e`;
- requires the resolved object to be a directory; and
- adds the resolved path only to the blocked working-directory roots.

Excluded paths are never added to the Apptainer bind arguments. Like the bind
configuration, this file is sourced Bash and must be administrator-controlled.

An exclusion is a working-directory policy and the absence of an explicit bind;
it is not an Apptainer negative mount. If `claude-bind.conf` contains a parent
directory of an excluded path, the parent bind will still make the excluded
directory visible inside the container. Administrators must avoid overlaps
between the bind and exclusion configurations when non-visibility is required.

## Working-directory policy

The working directory is the directory from which the user invokes `claude`.
The wrapper resolves it using:

```bash
work_dir="$(realpath -e -- .)"
```

This canonicalization prevents a symlinked path from bypassing directory
policy. All subsequent checks and the Apptainer `--pwd` value use the resolved
path.

A working directory is accepted only when all of these conditions hold:

1. It is a directory.
2. It is not equal to or beneath any path in `claude-bind.conf`.
3. It is not equal to or beneath any path in `claude-exclude.conf`.
4. It is a strict subdirectory of the user's home or one of the user's existing
   group project/scratch roots. The storage root itself is not accepted.
5. No path component below the allowed root begins with `.`.
6. It is readable, writable, and searchable by the user.

Examples:

| Path | Result | Reason |
| --- | --- | --- |
| `$HOME` | Rejected | An allowed root is not a strict subdirectory of itself. |
| `$HOME/project1` | Accepted | Non-hidden subdirectory of home, unless otherwise restricted. |
| `$HOME/.private/project` | Rejected | Contains a hidden path component. |
| `$HOME/ondemand` | Rejected | Listed in `claude-exclude.conf`. |
| `/tmp/project` | Rejected | `/tmp` is a configured bind and an invalid working tree. |
| A group project root | Rejected | The root itself is not a strict subdirectory. |
| A project beneath a group root | Accepted | Provided it is writable and not otherwise restricted. |

## Claude state

The wrapper creates these directories if they do not exist:

```text
$HOME/.claude
$HOME/.local/share/claude
```

Their bind permissions are controlled by `claude-bind.conf`.

`$HOME/.claude.json` is optional. The wrapper does not create it. If it already
exists as a regular file or a valid symlink to a regular file, it is bound into
the container at the same path. If it is absent, Claude launches without that
bind.

The working directory and optional `.claude.json` bind remain in the wrapper
rather than `claude-bind.conf` because the former is determined at launch and
the latter is a file while the configuration accepts directories only.

## GPU support

The wrapper conditionally enables Apptainer's NVIDIA integration. It requires
both the NVIDIA control character device and at least one numbered GPU device:

```bash
gpu_opts=()
if [[ -c /dev/nvidiactl ]] &&
   compgen -G '/dev/nvidia[0-9]*' >/dev/null; then
    gpu_opts+=(--nv)
fi
```

On a GPU node, `--nv` exposes the NVIDIA devices and binds compatible host
driver libraries into the container. This is necessary because `--contain`
otherwise creates a minimal `/dev` tree.

On a CPU-only node, `gpu_opts` remains empty. Omitting `--nv` avoids unnecessary
NVIDIA library discovery and avoids warnings or failures on hosts without an
NVIDIA driver installation.

Detection uses device availability rather than cluster names or GPU-node
naming conventions. It determines whether NVIDIA integration can be enabled;
the scheduler remains responsible for assigning and restricting GPU resources.

## Apptainer invocation

The final command is structurally:

```bash
apptainer run \
    --contain \
    <optional --nv> \
    <optional --env PREPEND_PATH=...> \
    <generated bind arguments> \
    --pwd "$work_dir" \
    "$image" \
    "$@"
```

`--contain` prevents the normal host home, `/tmp`, and `/var/tmp` mounts and
uses minimal container-side locations instead. The wrapper then explicitly
binds only the paths required by policy. In the current configuration, `/tmp`
and `/var/tmp` are intentionally added back as explicit read-write binds.

The SIF runscript executes:

```bash
exec /usr/bin/claude "$@"
```

Therefore wrapper arguments are forwarded directly to Claude Code. Examples:

```bash
claude
claude --resume
claude --version
```

## Permission implications

A read-only bind prevents processes in the container from changing files below
that mount. A read-write bind permits the same writes the host user could make
outside the container.

Nested binds can supersede a parent mount. For example, a read-only parent does
not guarantee that a separately mounted read-write child is read-only. Review
the complete generated bind set when combining parent and child directories.

The working-directory bind is always read-write because Claude must be able to
edit the selected project. Claude state, Conda, and R paths are currently
configured read-write. `/apps` is configured read-only.

## Failure behavior

The wrapper exits nonzero without starting Claude when it encounters:

- a login node;
- an unset or unsupported `CLUSTER`;
- a missing configuration file;
- a malformed configuration array or entry;
- an empty environment pattern or one matching a required wrapper variable;
- a configured object that exists but is not a directory;
- an administratively restricted working directory;
- a working directory outside the approved storage roots;
- a hidden working-directory component;
- insufficient working-directory permissions;
- a missing `apptainer` command; or
- a missing or unreadable `claude-mod.sif`.

Missing optional bind and PATH entries are silently skipped. Missing exclusion
paths produce warnings and are skipped.

## EasyBuild integration

`eb/claude.eb` installs the wrapper, all four configuration files, and the
SIF. It copies the wrapper to the user-facing command name `claude` and adds
the installation directory to `PATH`.

Whenever the wrapper or a configuration file changes, regenerate its SHA-256
checksum and update the matching entry in `claude.eb`:

```bash
sha256sum \
    eb/claude-wrapper.sh \
    eb/claude-bind.conf \
    eb/claude-path.conf \
    eb/claude-exclude.conf \
    eb/claude-env.conf
```

The SIF checksum must likewise be updated whenever the image is rebuilt.
Reinstall the EasyBuild module after changing these files; editing the source
repository does not update an already installed `claude` command.

To confirm which installed launcher is active:

```bash
type -a claude
```

## Basic validation

Validate shell syntax before installing:

```bash
bash -n eb/claude-wrapper.sh
bash -n eb/claude-bind.conf
bash -n eb/claude-path.conf
bash -n eb/claude-exclude.conf
bash -n eb/claude-env.conf
```

Test policy from an allocated compute node:

```bash
# Expected to start or print the installed Claude version.
cd /path/to/an/allowed/project
/path/to/installed/claude --version

# Expected to fail because ondemand is excluded.
cd "$HOME/ondemand"
/path/to/installed/claude --version
```

Also test a symlinked Conda layout if the deployed configuration includes
`.conda/envs` or `.conda/pkgs`.
