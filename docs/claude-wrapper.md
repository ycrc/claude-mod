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
- running Claude against a model hosted by YCRC instead of Anthropic's, with
  `claude --local-model`;
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
claude-local-model.conf      # Local model service (read only with --local-model)
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
the help text, and local mode). Sourcing it defines functions and has no
other effect.

## Runtime requirements

The wrapper expects these environment variables:

- `HOME`: the user's host home directory;
- `USER`: the username; if unset, `id -un` is used; and
- `CLUSTER`: the YCRC cluster name.

It also expects `apptainer`, `hostname`, `realpath`, `groups`, `sort`, and
standard Bash utilities to be available on the host; local mode also needs
`curl` and `id`. It uses Bash-specific
features (arrays, namerefs, lowercase expansion) and must be run with Bash 4.4
or newer, not POSIX `sh`.

## Launch sequence

The wrapper performs these operations in order:

1. Enables `set -euo pipefail`, locates the image, configuration files and
   functions file, and sources the functions file.
2. Takes the module's own options out of the arguments (`--ycrc-help`,
   `--bind`, `-B`, `--local-model`); everything else is kept for Claude.
   `--model`, `--fallback-model` and `--settings` stay in Claude's arguments
   but are noted for local mode. Scanning stops at `--`.
3. **Help:** with `--ycrc-help`, prints module usage and exits before any
   other check.
4. Requires `HOME` and `CLUSTER`.
5. **Login-node protection.**
6. **Environment scrubbing** (`claude-env.conf`).
7. **Local mode** (only with `--local-model`): loads and checks
   `claude-local-model.conf`, applies the local-mode argument rules, checks the
   cluster and `curl`, removes inherited provider settings, and exports the
   user-scoped credential.
8. **Claude state:** creates `$HOME/.claude` and `$HOME/.local/share/claude`.
9. **Admin binds** (`claude-bind.conf`).
10. **Container PATH** (`claude-path.conf`).
11. **Exclusions** (`claude-exclude.conf`).
12. **Working-directory policy:** selects storage bases from `CLUSTER`,
    resolves the invocation directory, and enforces the bind, exclusion,
    allowed-root, hidden-directory, and permission checks.
13. Verifies that Apptainer and the SIF are available, and queues the
    working-directory bind and the optional `~/.claude.json` bind.
14. **User binds** (`--bind`).
15. **GPU support.**
16. **Bind ordering.**
17. **Local session** (only with `--local-model`): checks that the
    local model service is up, then adds the session's environment, Claude
    options and banner.
18. **Launch** with `apptainer run`.

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

All the configuration files are sourced by Bash inside a function, so they are
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

Their bind permissions are controlled by `claude-bind.conf`. Local mode uses
the same state (see "Shared state" under "Local model mode").

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

## Local model mode

`claude --local-model` runs Claude Code against a model hosted by YCRC, *the
local model*, instead of Anthropic's. "Local" means hosted by YCRC on a shared
GPU server, not running on the user's own node. The model is requested by a
stable alias, `ycrc-local`, which the service maps to whatever it currently
serves (`Qwen3.8-Flash-Next` as of October 2026), so a model swap needs no
module rebuild. It is served by vLLM
on a Bouchet GPU node, behind a gateway that speaks Anthropic's Messages API.
The session's prompts, code and tool results go only to that service, not to
Anthropic.

It is meant to feel like a model switch, not a different environment: Claude
keeps the user's normal state, settings, skills, plugins, memory and sessions.

```bash
claude --local-model                      # interactive
claude --local-model -p "Summarize x.py"  # one-shot
claude --local-model --resume <id>        # continue a session on the local model
```

`--local-model` is recognized only before `--`. `--local-model=NAME` is
refused; that form is reserved for choosing among several local models.
Local mode is available only on the clusters listed in
`claude-local-model.conf` (currently Bouchet).

### Configuration

`claude-local-model.conf` is an administrator-controlled Bash file, read only in
local mode. A missing or broken file stops local mode and never affects
the default mode. It contains no secrets.

```bash
local_clusters=(bouchet)
local_base_url='http://a1127u31n01.mghpcc.ycrc.yale.edu:8008'
local_model='ycrc-local'         # stable alias; the service maps it to whichever model it serves
local_agent_label='claude-mod'   # credential is "<netid>.<label>"; the gateway knows claude-mod, claude, codex, copilot, pi
local_max_context='262000'
local_max_output='16384'
```

Every listed variable is unset before the file is sourced, so an inherited
environment variable (for example an exported `local_base_url`) cannot fill
a gap in the file. Each must then be set and non-empty, and:

- `local_clusters` must be an array;
- `local_base_url` must be `http(s)://host[:port][/path]`; a trailing `/` is
  removed;
- `local_model` may contain only letters, digits and `._:/@-`, and
  `local_agent_label` only letters, digits, `_` and `-`. Labels the gateway
  doesn't know are accounted as `unknown`;
- `local_max_context` and `local_max_output` must be positive integers.

### Preflight

The **Local mode** step runs right after environment scrubbing, before any
other work. In order, it:

1. loads and checks `claude-local-model.conf`;
2. applies the argument rules:
   - `--model` (either form) may name only the local model or `default`.
     Anything else, including Claude aliases such as `opus`, stops the launch
     with a message suggesting `claude` without `--local-model`;
   - `--effort` (either form) may be only `low`, `medium` or `xhigh`;
   - `--fallback-model` is refused, since there is only one model;
   - a user `--settings` is refused, because local mode passes its own
     `--settings` (see "Local session") and Claude accepts only one. User
     settings belong in `~/.claude/settings.json`;
3. requires `CLUSTER` to be in `local_clusters` and `curl` to be available;
4. unsets every exported `ANTHROPIC_*`, `CLAUDE_CODE_USE_*`,
   `CLAUDE_CODE_EXTRA_BODY` and `CLAUDE_CODE_EFFORT_LEVEL`, and the same names
   with an `APPTAINERENV_` or `SINGULARITYENV_` prefix, printing one warning per
   name. These could send the session to another server, add fields to its
   requests, or pin an effort level the service lacks. The default mode
   keeps them; setting them there is the user's own choice;
5. exports `ANTHROPIC_AUTH_TOKEN="<netid>.<label>"`, with the netid from
   `id -un` (not `USER`, which the user can change). Apptainer passes it on from
   the environment, so it never appears on a command line. It identifies the
   user to the gateway for accounting; it is not a password. When it is set,
   Claude Code uses it instead of the user's claude.ai login.

### Local session

The **Local session** step runs after every local check, so local mistakes
are reported without a network wait.

**Service check.** A quick request with the user's credential:

```bash
curl -sS --connect-timeout 3 -m 5 -w '\n%{http_code}' \
    -H "Authorization: Bearer <netid>.claude-mod" <base_url>/v1/models
```

It shows that the gateway answers, that vLLM behind it is up, and that the
configured model is offered (`"<model>"` must appear, with the quotes, so
`ycrc-local` does not match only `ycrc-local-think`). `GET` requests are not
counted as usage, and the check normally takes about 0.1 s. Each failure stops
the launch with its own message, followed by "Try again later, or contact
research.computing@yale.edu if it persists.":

| Result | Message |
| --- | --- |
| Connection fails or times out | YCRC's local model service (host:port) isn't reachable right now. |
| HTTP 502 | the local model service is up, but its model server isn't responding. |
| Another non-200 status | the local model service returned HTTP <code>. |
| 200, model not listed | the local model service doesn't offer <model>. (The conf may be out of date.) |

**Environment.** Each variable is passed both to Apptainer (`--env`) and in the
`env` block of the `--settings` argument below. Settings given on the command
line outrank project and user settings, so neither a project's nor the user's
own `settings.json` can redirect a local session or change these values.

| Variable | Value | Why |
| --- | --- | --- |
| `ANTHROPIC_BASE_URL` | `local_base_url` | Where requests go. |
| `ANTHROPIC_MODEL` | `local_model` | The session's model. |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`, `..._NAME` | the model; "<model> (hosted by YCRC)" | "Default" in `/model` resolves to the Opus tier. The other tiers are left unmapped, so they are refused (see "Choosing a model"). |
| `CLAUDE_CODE_SUBAGENT_MODEL` | the model | Default model for subagents (`_FORCE` is never set). |
| `CLAUDE_CODE_DISABLE_1M_CONTEXT` | `1` | Otherwise "Default" picks a 1M-context variant. |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | from the conf | Claude Code doesn't know the model's limits; without the output limit it asks for 32000 tokens. |
| `CLAUDE_CODE_AUTO_MODE_SERVER` | `0` | vLLM has no server-side auto-mode classifier (see "Auto mode in local mode"). |
| `CLAUDE_CODE_USE_BEDROCK`, `_VERTEX`, `_FOUNDRY` | `0` | No other provider. |
| `DISABLE_BUG_COMMAND` | `1` | `/bug` can upload the session to Anthropic. |

`CLAUDE_CONFIG_DIR` is not set: the state is shared (see "Shared state"). An
inherited `CLAUDE_CONFIG_DIR` applies in both modes.

**Claude options**, placed before `--add-dir` and the user's arguments:

- `--settings` with the `env` block above, plus
  `maxEffortLevel: "xhigh"` (see "Effort"), `availableModels: ["<model>"]`, a `modelPicker` with the local model as its
  only row (`replaceBuiltInOptions: true`), and `permissions.deny:
  ["WebSearch"]`, since web search is a server-side tool the service lacks;
- `--append-system-prompt`, telling the model that the session runs on YCRC's
  local model, that web search is unavailable, and that continuing the
  session without `--local-model` would send it to Anthropic.

**Banner** on stderr:

```text
Local model: ycrc-local, hosted by YCRC. This session's prompts and code are not sent to Anthropic.
Effort: low, medium or xhigh (/effort); high, the default, runs as medium.
Sessions, settings and memory are shared with your normal Claude; continuing this session
without --local-model sends it to Anthropic. See claude --ycrc-help.
```

### Choosing a model

The local model is the only choice. Asking for a Claude model gives a
clear refusal rather than silently running the local model:

| The user does | Result |
| --- | --- |
| `/model` (picker) | Rows: Default and the local model, both naming it |
| `/model default` or `/model opus` | "Set model to `ycrc-local (hosted by YCRC)` for this session only" |
| `/model sonnet`, `haiku`, `fable`, `opusplan`, or a Claude model ID | "Model '…' is not available. Your organization restricts model selection." The session stays on the local model. |
| `--model` with a Claude model at launch | Stopped by the wrapper (see "Preflight") |
| An agent, skill or teammate that names a Claude model | Claude Code warns and uses the session's model |

The "Your organization…" wording is Claude Code's. In local mode, Claude
Code applies a `/model` choice "for this session only". To use a Claude model, exit
and start `claude` without `--local-model`, optionally with `--resume <id>`
to continue the same conversation.

### Shared state

Both modes use the same Claude state, bound by the same configuration:
`~/.claude` (settings, skills, agents, commands, plugins, `CLAUDE.md`, sessions,
memory, prompt history), `~/.claude.json` and `~/.local/share/claude`. In
practice:

- the launch environment and `--settings` win over a saved `model`, so a
  commercial-mode setting cannot break a local launch. Claude Code saves
  effort per model, so a level saved for Opus never reaches the local model;
- a local session writes its transcript (and any memory the model saves).
  `/effort` saves its level under `modelSettings.ycrc-local` in
  `~/.claude/settings.json`, and later local sessions start at it. Other
  settings are unchanged;
- sessions move between modes in both directions with `--resume` or
  `--continue`: a commercial session continues on the local model, and an
  local session continues on Claude;
- the user's own MCP servers load in both modes. claude.ai connectors do not
  load in local mode: Claude Code turns them off when another credential is
  set, and prints a one-line notice saying so at startup, which is expected.

### When local-model content can reach Anthropic

A local session's own requests go only to YCRC's service. Because state is
shared, its content can reach Anthropic later, in a commercial session:

| Case | What reaches Anthropic | When |
| --- | --- | --- |
| Continuing a local session without `--local-model` (`claude --resume`, `--continue`, or picking it from the resume list) | the whole transcript so far | on the first commercial turn |
| Auto-memory written during a local session (the model saves memory on its own, for example when told to remember something) | that project's memory notes | whenever a later commercial session in the same project loads memory |
| Edits to a `CLAUDE.md` made during a local session | the edited text | every later commercial session that loads it |
| Files Claude wrote or changed | their content, if a later commercial session reads them | as for any file |
| Prompt history (`~/.claude/history.jsonl`) | a past prompt, if the user recalls and re-sends it | when re-sent |

To keep work away from Anthropic, start a new commercial session rather than continuing a
local one, and review the project's memory (`/memory`) before switching.

### Auto mode in local mode

Auto mode works in both modes. A tool call is decided in the same order:

1. the module's permission rules ("always ask" and "deny" rules apply as usual);
2. Claude Code's fast paths for read-only tools and edits inside the project,
   which need no classifier;
3. for everything else, a safety classifier. In the default mode, Anthropic's
   servers run it. In local mode, `CLAUDE_CODE_AUTO_MODE_SERVER=0` makes
   Claude Code run it itself, as one or two extra requests to **the local
   model**. Nothing about the decision goes to Anthropic.

What users notice: a command that needs judging takes a few seconds longer
(about 2.5 s when allowed, 5.5 s when blocked), and a blocked command comes with
a reason, such as "[Data Exfiltration]". The local model is a general model
doing a job Anthropic's classifier is tuned for, and its judgment has not been
evaluated as thoroughly. Users who want to approve every command themselves can
start with `--permission-mode default` or switch modes with Shift+Tab. Each
classified call sends a prompt of about 35k tokens to the shared server (mostly
served from its prefix cache), so auto mode adds load.

### Effort

The service has three reasoning levels, `low`, `medium` and `xhigh`, and the
model reasons at every level. Claude Code has five (`low`, `medium`, `high`,
`xhigh`, `max`) and sends one with every request. claude-mod lines them up as far as
Claude Code allows:

- The wrapper doesn't set a level. A session starts at the level the user saved
  for this model with `/effort` ("saved as your default for new sessions"), or
  else at Claude Code's default, `high`, which the service runs as `medium`.
- `maxEffortLevel: "xhigh"` takes `max` out of `/effort`. Asking for it gives
  "Effort 'max' exceeds the cap for ycrc-local …; set to 'xhigh' instead".
- `--effort high` and `--effort max` at launch are refused, as is an inherited
  `CLAUDE_CODE_EFFORT_LEVEL`.
- **`/effort high` can't be refused.** Claude Code has no setting that removes a
  single level, and hooks don't run for `/effort`. The service treats `high` as
  `medium`.
- The auto-mode classifier sends no effort level, so it reasons at the
  service's default, `low`, whatever the session's level is.

### Limits

- **Best effort.** Anthropic does not support non-Claude models in Claude Code.
  Web search is unavailable, and other features may behave differently. Claude
  Code prints `[claude-code:unrecognized_model]` for the model ID; it is
  harmless.
- **Effort** starts at the level saved with `/effort`, or at `high` (run as
  `medium`). `/effort low`, `/effort medium` and `/effort xhigh` change it.
  `/effort max` is capped to `xhigh`, with a message (see "Effort").
- **The model reasons on every turn**, at the effort level. This adds output
  tokens and latency. Claude Code shows no thinking-token count, because the
  service doesn't report one.
- **Ignore the dollar cost** Claude Code shows for the local model; it is an
  estimate with no price behind it.
- **Usage is recorded per netid.** The gateway records token counts per netid
  and model, not prompts or code.
- **Shared capacity.** One server is shared by every user. Each Claude Code
  request carries about 17k tokens of system prompt and tool definitions, and
  every turn resends the conversation; the server's prefix cache absorbs most of
  this. Subagents and auto mode add requests.
- **Internet access remains.** Claude's tools can still reach the internet
  (`curl`, `pip`, `git push`), so the promise is only that the session's prompts
  and code are not sent to Anthropic.
- **The service uses plain `http`** inside the cluster network; `https` URLs are
  accepted if the service adds TLS.

### Service contract

The gateway and its configuration belong to the local model service, not to this
module. The wrapper relies on these behaviors; if they change, the conf or the
wrapper must follow:

- the Anthropic Messages API at `<base_url>/v1/messages`, and `GET /v1/models`
  listing the served models;
- credentials of the form `<netid>.<label>`, with `claude-mod` among the known
  labels;
- the `ycrc-local` alias listed by `GET /v1/models` and mapped to the served
  model;
- the effort levels `low`, `medium` and `xhigh`, and requests with no effort
  (the auto-mode classifier's) being accepted;
- HTTP 502 from the gateway when vLLM is down.

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
    <local mode: --env NAME=VALUE for the session environment> \
    <ordered --bind arguments> \
    --pwd "$work_dir" \
    "$image" \
    <local mode: --settings JSON --append-system-prompt TEXT> \
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
  unknown mode, `--local-model=NAME`);
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
- a missing `apptainer` command;
- a missing or unreadable `claude-mod.sif`; or
- in local mode only: a missing or invalid `claude-local-model.conf`, an
  unsupported cluster, a missing `curl`, a refused `--model`,
  `--fallback-model` or `--settings`, or a failed service check (see
  "Local model mode").

Missing optional bind and PATH entries are silently skipped. Missing exclusion
paths produce warnings and are skipped. `--bind` directories that are already
available are skipped with a note.

## EasyBuild integration

`eb/claude.eb` installs the wrapper, the functions file, all five configuration
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
wrapper against stub `apptainer`, `hostname`, `groups` and `curl` commands.
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

For local mode, on a Bouchet compute node:

```bash
# Expected to answer, naming the local model and YCRC.
claude --local-model -p "Which model are you, and who hosts you?"

# Your request appears in the gateway's accounting under your netid.
curl -s http://a1127u31n01.mghpcc.ycrc.yale.edu:9103/metrics | grep "netid=\"$(id -un)\""

# Expected to stop: local mode offers one model.
claude --local-model --model opus
```

Inside a local session, `/model` should list only Default and the local
model, and `/model sonnet` should be refused.
