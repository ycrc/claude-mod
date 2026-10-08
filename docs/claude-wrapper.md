# Claude Apptainer wrapper

## Purpose

`eb/claude-wrapper.sh` is the host-side launcher installed as the `claude`
command by EasyBuild. It applies cluster policy, constructs the permitted bind
mounts, and then starts `claude-mod.sif` with Apptainer.

The wrapper is responsible for:

- preventing Claude from running on login nodes;
- limiting the working directory to approved user storage (home, project,
  scratch, and PI space);
- rejecting hidden and administratively restricted working directories;
- exposing only configured host paths, plus directories the user names with
  `--bind`, inside the container;
- applying read-only or read-write permissions to binds;
- removing configured sensitive environment variables before launch;
- preserving selected Claude state;
- printing module usage with `claude --ycrc-help`; and
- forwarding all other command-line arguments to the container runscript.

The wrapper does not install Claude Code. Claude Code and its managed settings
are built into `claude-mod.sif` by `claude-mod.def`.

Quick reference for users: `claude --ycrc-help`.

## Installed layout

EasyBuild installs the following files together in one directory:

```text
claude                       # Executable copy of claude-wrapper.sh
claude-wrapper.sh            # Source wrapper retained for inspection
claude-wrapper-functions.sh  # Shared helpers and longer steps, sourced by the wrapper
claude-bind.conf             # Directories to bind and their permissions
claude-path.conf             # Bound tool directories to prepend to container PATH
claude-exclude.conf          # Directories forbidden as working directories
claude-env.conf              # Sensitive environment-variable name patterns
claude-mod.sif               # Apptainer image
```

The wrapper locates every supporting file relative to its own physical
directory. It does not depend on the user's current directory to locate the
image, the functions file, or the configuration.

`claude-wrapper.sh` reads as an ordered list of steps. Each step is a commented
block whose label matches a heading in this document (for example "User binds"),
so code and documentation can be searched for each other. Most steps are written
inline. `claude-wrapper-functions.sh` holds only the helpers used in more than
one place (path checks, config loading, bind queueing) and the longer steps that
would clutter the sequence (user binds, allowed storage roots, bind ordering,
and the help text). Sourcing it defines functions and has no other effect.

## Runtime requirements

The wrapper expects these environment variables:

- `HOME`: the user's host home directory;
- `USER`: the username; if unset, `id -un` is used; and
- `CLUSTER`: the YCRC cluster name.

It also expects `apptainer`, `hostname`, `realpath`, `groups`, `sort`, and
standard Bash utilities to be available on the host. It uses Bash-specific
features (arrays, namerefs, lowercase expansion) and must be run with Bash 4.4
or newer, not POSIX `sh`.

## Launch sequence

The wrapper performs these operations in order:

1. Enables `set -euo pipefail`, locates the image, configuration files and
   functions file, and sources the functions file.
2. Takes the module's own options out of the arguments (`--ycrc-help`,
   `--bind`, `-B`); everything else is kept for Claude. Scanning stops at `--`.
3. **Help:** with `--ycrc-help`, prints module usage and exits before any
   other check.
4. Requires `HOME` and `CLUSTER`.
5. **Login-node protection.**
6. **Environment scrubbing** (`claude-env.conf`).
7. **Claude state:** creates `$HOME/.claude` and `$HOME/.local/share/claude`.
8. **Admin binds** (`claude-bind.conf`).
9. **Container PATH** (`claude-path.conf`).
10. **Exclusions** (`claude-exclude.conf`).
11. **Working-directory policy:** selects storage bases from `CLUSTER`,
    resolves the invocation directory, and enforces the bind, exclusion,
    allowed-root, hidden-directory, and permission checks.
12. Verifies that Apptainer and the SIF are available, and queues the
    working-directory bind and the optional `~/.claude.json` bind.
13. **User binds** (`--bind`).
14. **GPU support.**
15. **Bind ordering**, then **launch** with `apptainer run`.

Any failed policy or validation check exits before Apptainer is started.
Errors and warnings are written to stderr.

## Help

`claude --ycrc-help` prints a summary of the module, where Claude can be
started (including the current cluster's storage bases when `CLUSTER` is set),
the module's options, and a link to the YCRC documentation. It runs before
every other check, so it works on login nodes, without `CLUSTER`, and from any
directory. After `--`, `--ycrc-help` is passed to Claude unchanged.
`claude --help` is Claude's own help.

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

`CLUSTER` determines the storage bases used to find a user's project, scratch,
and PI directories:

| Cluster | Project base | Scratch base | PI bases |
| --- | --- | --- | --- |
| `bouchet` | `/nfs/roberts/project` | `/nfs/roberts/scratch` | `/nfs/roberts/pi` |
| `grace` | `/gpfs/gibbs/project` | `/vast/palmer/scratch` | `/gpfs/gibbs/pi`, `/vast/palmer/pi` |
| `mccleary` | `/gpfs/gibbs/project` | `/vast/palmer/scratch` | `/gpfs/gibbs/pi`, `/vast/palmer/pi` |

An unset or unsupported `CLUSTER` stops the launch.

The wrapper runs `groups` and considers every returned group, except:

- the group whose name equals the username (the user's personal group); and
- the groups listed in `ignored_storage_groups` in
  `claude-wrapper-functions.sh` (currently `gaussian`).

Skipping them avoids pointless lookups on network filesystems. For each
remaining group, it checks for a user directory under every storage base:

```text
<storage-base>/<group>/<username>
```

For example:

```text
/nfs/roberts/project/pi_example/alice
/nfs/roberts/pi/pi_example/alice
/nfs/roberts/scratch/support/alice
```

Missing group storage directories are ignored, so users without PI storage see
no difference. Existing directories are resolved with `realpath -e` before being
used as allowed roots.

## Environment scrubbing

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
    # ...
    'SSH_AUTH_SOCK'
    'KRB5CCNAME'
)
```

Patterns must be quoted. Without quotes, the shell could expand `*` against
filenames while loading the configuration.

All four configuration files are sourced by Bash inside a function, so they are
executable shell code: they must use plain assignments (`name=( ... )`, never
`declare` or `local`) and must not be writable by ordinary users.

### Scrubbing process

The wrapper uses the Bash builtin `compgen -e` to enumerate exported
environment-variable names and tests every configured glob against each name.
When a name matches, the wrapper:

1. unsets the variable in the wrapper process;
2. prints a warning to **stderr** containing the variable name; and
3. stops testing additional patterns for that variable.

Example output:

```text
Warning: unset sensitive environment variable: OPENAI_API_KEY
```

Values are never inspected or printed. Since Apptainer is executed from the
same wrapper process, unset variables are not inherited by the container.
Warnings go to stderr so they cannot mix into Claude's own output, for example
with `claude -p ... > out.txt`.

The wrapper rejects an empty pattern, and any pattern that matches one of the
variables it needs: `HOME`, `USER`, `PATH`, and `CLUSTER`. This prevents an
accidentally broad pattern such as `*` from disabling the launcher itself.

## Admin binds

### Format

`claude-bind.conf` is an administrator-controlled Bash file that defines an
indexed array named `binds`:

```bash
binds=(
    "$HOME/.claude:rw"
    "$HOME/.local/share/claude:rw"
    "$HOME/.conda:rw"
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

### Validation

For each bind entry, the wrapper:

1. separates an optional `ro` or `rw` suffix (any other suffix is an error);
2. requires an absolute path other than `/`;
3. rejects `:` and `,` in the path, because Apptainer uses them as bind-spec
   separators;
4. silently skips a missing path, including a dangling symlink;
5. resolves the path with `realpath -e`; and
6. requires the resolved object to be a directory.

Configuring a broad directory has two effects: it exposes that directory in the
container and prevents Claude from starting anywhere in that directory tree.

### Symlinks

For a normal directory, the wrapper mounts the resolved host source at the
configured container path. For a symlink, it mounts the same host directory
twice: at the configured logical path and at the resolved physical path. For
example, if `/home/alice/.conda/envs` is a symlink to
`/nfs/roberts/project/pi_example/alice/conda/envs`, the entry
`"$HOME/.conda/envs:rw"` produces binds equivalent to:

```bash
--bind /nfs/roberts/project/pi_example/alice/conda/envs:/home/alice/.conda/envs:rw
--bind /nfs/roberts/project/pi_example/alice/conda/envs:/nfs/roberts/project/pi_example/alice/conda/envs:rw
```

The first path supports tools using `$HOME/.conda/envs`; the second supports
Conda metadata and environment prefixes containing the resolved path. No files
are copied.

## Container PATH

`claude-path.conf` defines host tool directories that are prepended to the
container PATH:

```bash
path_entries=(
    "/apps/bin"
    "/opt/slurm/current/bin"
    "/share/admins/bin"
)
```

Each entry must be an absolute directory other than `/`, must not contain `:`
or `,`, and must be located at or beneath a directory configured in
`claude-bind.conf`. Missing entries are skipped, existing entries must be
directories, and duplicates (including a trailing `/` variant) are removed while
preserving order. Accepted entries are joined with `:` and passed as:

```bash
--env "PREPEND_PATH=<configured entries>"
```

A PATH entry does not create a bind mount by itself; its installation prefix
must also be present in `claude-bind.conf`.

## Exclusions

`claude-exclude.conf` defines directories that must not be used as Claude's
working directory, and that users may not `--bind`:

```bash
excluded_workdirs=(
    "$HOME/ondemand"
)
```

Entries must be absolute directories other than `/`. A missing path produces a
warning and is skipped; an existing path must be a directory. Excluded paths are
never added to the bind arguments.

An exclusion is a policy, not an Apptainer negative mount. If `claude-bind.conf`
contains a parent of an excluded path, the parent bind still makes the excluded
directory visible. Avoid overlaps between the bind and exclusion configurations
when non-visibility is required.

## Working-directory policy

The working directory is the directory from which the user invokes `claude`,
resolved with `realpath -e`. All checks and the Apptainer `--pwd` value use the
resolved path. A working directory is accepted only when all of these hold:

1. It is not equal to or beneath any path in `claude-bind.conf`.
2. It is not equal to or beneath any path in `claude-exclude.conf`.
3. It is a strict subdirectory of the user's home or one of the user's existing
   group project, scratch, or PI roots. The root itself is not accepted.
4. No path component below the allowed root begins with `.`.
5. It is readable, writable, and searchable by the user.

| Path | Result | Reason |
| --- | --- | --- |
| `$HOME` | Rejected | An allowed root is not a strict subdirectory of itself. |
| `$HOME/project1` | Accepted | Non-hidden subdirectory of home. |
| `$HOME/.private/project` | Rejected | Contains a hidden path component. |
| `$HOME/ondemand` | Rejected | Listed in `claude-exclude.conf`. |
| `/tmp/project` | Rejected | `/tmp` is a configured bind. |
| `/nfs/roberts/pi/pi_example/alice` | Rejected | A PI root itself is not a strict subdirectory. |
| `/nfs/roberts/pi/pi_example/alice/analysis` | Accepted | Non-hidden subdirectory of a PI root. |

## Claude state

The wrapper creates these directories if they do not exist:

```text
$HOME/.claude
$HOME/.local/share/claude
```

Their bind permissions are controlled by `claude-bind.conf`.

`$HOME/.claude.json` is optional and never created. If it exists as a regular
file (or a valid symlink to one), it is bound into the container at the same
path. The working directory and `.claude.json` binds stay in the wrapper rather
than `claude-bind.conf` because the former is determined at launch and the
latter is a file.

## User binds

Users can give Claude access to more directories at launch:

```bash
claude --bind=/nfs/roberts/project/pi_example/shared        # read-only
claude --bind=/nfs/roberts/project/pi_example/shared:rw     # read-write
claude --bind=../reference-data,~/scripts:rw                # several at once
claude -B /path/to/data                                     # short form
```

### Syntax

- `--bind=SPEC`, `--bind SPEC`, and `-B SPEC` are accepted and may be repeated.
- A spec may be a comma-separated list. Each element is `DIR`, `DIR:ro` or
  `DIR:rw`; the default is **read-only**.
- Any other `:` field is refused ("custom container destinations are not
  supported"). Directories are always mounted at their own paths, so a bind can
  never be placed over a container path such as `/etc/claude-code`.
- A leading `~` or `~/` means `$HOME` (the shell does not expand `--bind=~/x`).
  Relative paths are resolved from the launch directory.
- Options are only recognized before a `--`; everything after `--` goes to
  Claude unchanged.

### Checks

Each directory is checked in this order; the first matching outcome applies.

1. **Must be usable.** It must exist, be a directory, and be readable and
   searchable by the user.
2. **Already available: skipped with a note.** A directory equal to or inside
   the working directory, or inside an admin bind, is already visible. The bind
   is skipped, so `--bind=.` cannot make the session read-only and a user bind
   cannot override an administrator's mode.
3. **Refused: error, nothing launches.** These checks apply to both the path as
   given and its resolved path:
   - `/`, or inside a container system directory (`/bin /boot /dev /etc /lib
     /lib64 /opt /proc /root /run /sbin /sys /usr /var`); binding over these
     would replace the image's own files, including its managed settings;
   - any path component starting with `.`, such as `~/.ssh`;
   - equal to, inside, or containing an excluded directory;
   - equal to or containing the home directory, which holds credentials and
     Claude's own state; and
   - a path containing `:` or `,`, which Apptainer cannot express.
4. **Allowed:** anything else the user can read, including group, shared and
   other PI spaces, and ancestors of the working directory.

### Mounting

- Each allowed directory is mounted at the path as given (made absolute) and,
  when that is a symlink, also at its resolved path, as with admin binds.
- Each mounted path is passed to Claude as `--add-dir=PATH`, so Claude knows it
  may use it. The `=` form is used because `--add-dir` accepts several values
  and would otherwise consume the prompt; these options come before the user's
  own arguments.
- One line per bind is printed to stderr, for example
  `Binding read-only: /nfs/roberts/project/pi_example/shared`.

## Bind ordering

All binds (admin, state, working directory, and user) are collected first and
then emitted parent-first: sorted by the depth of the container path, keeping
the original order for equal depths. A nested bind is therefore mounted after,
and on top of, its parent. As a result:

- a read-only bind of an ancestor of the working directory keeps the working
  directory read-write;
- an ancestor of an admin bind keeps the admin mode; and
- correctness does not depend on the line order of `claude-bind.conf`.

## GPU support

The wrapper conditionally enables Apptainer's NVIDIA integration. It requires
both the NVIDIA control character device and at least one numbered GPU device:

```bash
[[ -c /dev/nvidiactl ]] && compgen -G '/dev/nvidia[0-9]*'
```

On a GPU node, `--nv` exposes the NVIDIA devices and binds compatible host
driver libraries into the container; this is necessary because `--contain`
otherwise creates a minimal `/dev`. On a CPU-only node `--nv` is omitted.
Detection uses device availability rather than node names; the scheduler
remains responsible for assigning GPUs.

## Launch

The final command is structurally:

```bash
apptainer run \
    --contain \
    <optional --nv> \
    <optional --env PREPEND_PATH=...> \
    <ordered --bind arguments> \
    --pwd "$work_dir" \
    "$image" \
    <--add-dir=DIR for each user bind> \
    <arguments for Claude>
```

`--contain` prevents the normal host home, `/tmp`, and `/var/tmp` mounts; the
wrapper then binds only the paths required by policy. In the current
configuration `/tmp` and `/var/tmp` are added back as explicit read-write binds.
The SIF runscript executes `exec /usr/bin/claude "$@"`, so remaining arguments
are passed directly to Claude Code (`claude --resume`, `claude -p "..."`, ...).

## Permission implications

A read-only bind prevents processes in the container from changing files below
that mount. A read-write bind permits the same writes the host user could make
outside the container. The working-directory bind is always read-write. Claude
state, Conda, and R paths are configured read-write; `/apps` is read-only. User
binds are read-only unless the user asks for `:rw`. Nested binds are handled by
the parent-first ordering described in "Bind ordering".

## Failure behavior

The wrapper exits nonzero without starting Claude when it encounters:

- a malformed module option (`--bind` without a value, a custom destination or
  unknown mode);
- an unset `HOME`, or an unset or unsupported `CLUSTER`;
- a login node;
- a missing or unreadable functions or configuration file;
- a malformed configuration array or entry;
- an empty environment pattern or one matching a required wrapper variable;
- a configured object that exists but is not a directory;
- an administratively restricted working directory;
- a working directory outside the approved storage roots;
- a hidden working-directory component;
- insufficient working-directory permissions;
- a `--bind` directory that is missing, unreadable, or refused by the checks
  in "User binds";
- a missing `apptainer` command; or
- a missing or unreadable `claude-mod.sif`.

Missing optional bind and PATH entries are silently skipped. Missing exclusion
paths produce warnings and are skipped. `--bind` directories that are already
available are skipped with a note.

## EasyBuild integration

`eb/claude.eb` installs the wrapper, the functions file, all four configuration
files, and the SIF. It copies the wrapper to the user-facing command name
`claude` and adds the installation directory to `PATH`. Its load message points
users to `claude --ycrc-help`.

Reinstall the EasyBuild module after changing these files; editing the source
repository does not update an already installed `claude` command. To confirm
which launcher is active:

```bash
type -a claude
```

## Basic validation

The wrapper has an automated test suite in `tests/` (bats), which runs the real
wrapper against stub `apptainer`, `hostname`, `groups` and `timeout` commands.
See `tests/README.md` for how to set up an environment, run the tests, and lint
the scripts with shellcheck.

Then test on an allocated compute node:

```bash
# Expected to start or print the installed Claude version.
cd /path/to/an/allowed/project
/path/to/installed/claude --version

# Expected to fail because ondemand is excluded.
cd "$HOME/ondemand"
/path/to/installed/claude --version

# Module usage; works anywhere, including login nodes.
/path/to/installed/claude --ycrc-help
```

Also test a symlinked Conda layout if the deployed configuration includes
`.conda/envs` or `.conda/pkgs`, and a `--bind` of the working directory's parent
(the working directory must stay writable).
