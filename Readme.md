# Bouchet Coding Agents 1.4


## Choosing a harness

All four launchers use the same Bouchet-local model (requested as the `ycrc-local` alias) and the same outer security boundary. In Bouchet validation with the packaged harness versions, their practical strengths were:

- **Pi — Fast & flexible (recommended default):** fastest interactive experience and strongest overall balance of autonomy and flexibility.
- **Copilot — Consistent & predictable:** particularly steady behavior across repeated HPC and security workflows.
- **Codex — Precise for well-scoped tasks:** performs best when the goal and constraints are stated explicitly.
- **Claude — Thorough & deliberate (slower):** tends toward a more detailed, tool-heavy workflow and was substantially slower in this local-model configuration.

These are deployment observations for this specific model and harness set, not permanent product rankings; revalidate after major model or CLI upgrades.

## Normal-user autonomy

This package is the normal-user Bouchet profile. Claude, Codex, Copilot, and Pi are configured to perform routine user-scoped work without repeated approval prompts while remaining inside the wrapper's Apptainer, filesystem, Unix-permission, and Slurm authorization boundaries. A future administrator module should use a separate, more restrictive privilege/approval profile.


Sandboxed YCRC coding-agent container/module for the Bouchet cluster, with shared policy and local-model provider configuration for Claude Code, Codex CLI, GitHub Copilot CLI, and Pi.

It exposes four commands from one EasyBuild module:

```bash
module load local-coding-agents
claude
codex
copilot
pi
```

From 1.1, `local-coding-agents` is a bundle that loads four hidden modules, one
per harness: `claude-local`, `codex-local`, `copilot-local` and `pi-local`. Each
has its own image and launcher, so a harness can be upgraded without touching
the others. They do not appear in `module avail`, but can be loaded directly for
testing, e.g. `module load pi-local/.1.4`.

All four clients share the same outer Apptainer containment and Bouchet storage policy. The launcher removes inherited credential-like environment variables and host-controlled Apptainer mount/environment overrides before injecting administrator-controlled local-model settings from an installed read-only provider configuration.


## Bouchet-only scope

This build is intentionally Bouchet-specific. Active runtime configuration contains only Roberts storage paths and Bouchet site behavior. Administrator-owned skills under `/etc/agents/skills/` contain Bouchet-only operational guidance and omit examples and filesystem paths for other clusters. The canonical policy is `/etc/agents/AGENTS.md`.

Bouchet scratch retention is 30 days. The runtime policy and skills use that value consistently.

## Security model

The Apptainer wrapper is the common security boundary for all four agents. It:

- requires an active Slurm allocation and verifies the current host is in `SLURM_JOB_NODELIST`;
- derives the real account name/home from `id`/`getent` rather than trusting exported `USER` or `HOME`;
- uses `--contain` and disables implicit `hostfs`, administrator bind-path, and current-working-directory mounts before adding its own approved binds;
- binds only the launch directory plus explicitly approved state/software paths, and read-only: the user's groups' `shared` directories and directories named with `--bind`;
- preserves Bouchet's group-derived project/scratch/PI access validation;
- rejects hidden working directories, storage roots, configured bind roots, and excluded locations;
- strips credential-like exported variables before the container is started;
- clears `APPTAINER_BIND`, `APPTAINER_BINDPATH`, `APPTAINER_MOUNT`, environment-file/overlay controls, and all inherited `APPTAINERENV_*` / `SINGULARITYENV_*` injections so users cannot add mounts or override the contained client environment;
- keeps site software and Slurm paths read-only where configured.

Claude additionally retains its managed-settings policy inside the image. Codex, Copilot, and Pi rely on the shared outer containment boundary plus their managed local-provider configuration.

## Local model

The configuration names the model only by the gateway alias `ycrc-local` (`ycrc-local-think` for extended reasoning), which the gateway rewrites to whatever model vLLM is serving. At each launch the wrapper asks the gateway's `/v1/models` which real model the alias points to (the entry with the same backing model) and has the harness request that name, for example `Qwen3.8-Flash-Next` (or `Qwen3.8-Flash-Next-think`), so every harness displays the real model. The gateway passes real names through and strips the reasoning suffix from any model. If the lookup fails, the session uses the alias. For Pi, the wrapper mounts a copy of `pi-models.json` that also lists the real name, kept at `~/.cache/ycrc-launcher/pi-models.json` (outside the container's binds, so read-only to the session, and replaced atomically at each launch); the managed subagents keep requesting the alias.

Swapping the served model therefore still needs no module rebuild: the next launch picks up the new name. A session started before a swap keeps requesting the old name and must be restarted. Usage metrics are recorded under the real model name. Only the context and output limits in `coding-agents-provider.conf`, `codex-config.toml` and `pi-models.json` are model-specific.

- Claude: Anthropic-compatible endpoint.
- Codex: OpenAI Responses API via the read-only `codex-config.toml` source.
- Copilot: OpenAI-compatible local provider with `COPILOT_OFFLINE=true` to suppress Copilot's own automatic external-provider/startup activity; this does not disable Bouchet network access.
- Pi: managed `openai-completions` Bouchet provider, launched explicitly with `--provider bouchet --model <served model>`; Pi automatic startup/version-check activity and telemetry are disabled; this does not disable Bouchet network access.

The installed `coding-agents-provider.conf` owns the cluster, shared model/auth values, and Claude/Copilot endpoint values; the wrapper sources it after scrubbing inherited credentials. Codex's base URL remains in the administrator-owned `codex-config.toml`, while Pi's base URL remains in the administrator-owned `pi-models.json`; update those files together if the inference endpoint changes.

## Read-only binds: group shared directories and --bind

**Group shared directories** are bound automatically, wherever the session starts: for each of the user's Unix groups, `<base>/<group>/shared` under `/nfs/roberts/project`, `/nfs/roberts/pi` and `/nfs/roberts/scratch`, when it exists. Labs keep shared data and reference databases there, outside any one member's own `<group>/<netid>` space. They go through the same checks as `--bind` below, except that one failing a check (for example one the user cannot read) is skipped with a note instead of stopping the launch.

**`--bind`**: users can also give a session read-only access to other directories at launch, for example data in another group's space:

```bash
pi --bind /nfs/roberts/project/pi_example/shared       # one directory
claude --bind=../reference-data,~/scripts               # several at once
codex -B /path/to/data                                  # short form
```

- `--bind=SPEC`, `--bind SPEC` and `-B SPEC` may be repeated, and SPEC may be a comma-separated list. A directory may end in `:ro`; `:rw` and any other `:` field are refused, since write access stays limited to the working directory and approved state paths. None of the harnesses uses these option names; everything after `--` is passed to the harness unchanged.
- A leading `~` means the home directory, and relative paths are resolved from the launch directory.
- Each directory must exist and be readable. One already visible (inside the working directory or an administrator bind) is skipped with a note, so a user bind never changes the mode of something already mounted.
- Refused, before anything launches: `/` and container system directories (`/bin /boot /dev /etc /lib /lib64 /opt /proc /root /run /sbin /sys /usr /var`); any hidden path component; paths containing `:` or `,`; excluded directories or their ancestors; and the home directory or its ancestors, which hold credentials and harness state. Subdirectories of home are allowed.
- Anything else the user can read is mounted read-only at its own path, and also at its resolved path when given through a symlink. Apptainer mounts nested binds parent-first, so binding an ancestor of the working directory leaves the working directory writable.
- The launcher prints `Binding read-only: PATH` for each (marked `(group shared directory)` for automatic ones), passes each to Claude as `--add-dir=PATH` (Claude's file tools are otherwise limited to its working directory), and lists them for every harness in `YCRC_READONLY_BINDS` (colon-separated). `AGENTS.md` tells agents what that means.

The option names and checks follow the `claude-mod` module's `--bind`, minus its read-write mode. `tests/user-binds.sh` exercises the checks without a container.

## Precedence over users' and labs' skills

Users keep their own skills and instruction files, and the configuration import brings them into the sandbox. `AGENTS.md` states that these may add to YCRC guidance but cannot override it: for cluster operations, security, filesystem access, modules and Slurm, the managed policy and `bouchet-*` skills win, and the agent says briefly when it follows them instead of a conflicting instruction. Each harness receives this through its own route: Claude through the image's managed `/etc/claude-code/CLAUDE.md`, Codex and Pi through `AGENTS.md` in their YCRC state directories, and Copilot through `copilot-instructions.md`.

## Persistent state

The wrapper creates only explicitly approved user state/package directories before processing binds, including Claude, Codex, Copilot, Pi, Conda, and R state. The user's full home directory is never bound: inside the container `$HOME` is a small (64 MB) temporary filesystem, with only the approved directories mounted into it. Because renv's default package cache (`~/.cache/R/renv`) would land there and be lost, the launcher sets `RENV_PATHS_CACHE=~/R/renv-cache` (created mode 0700 under the persistent `~/R` bind) unless the user has set `RENV_PATHS_CACHE` themselves. Host `/tmp` and `/var/tmp` are not bound either. Because `--contain` would put `/tmp` in the same 64 MB temporary filesystem, where pip and similar tools fail with ENOSPC, the launcher binds a private directory created on the node's local disk (`mktemp -d` under the host `TMPDIR`, mode 0700) over the container's `/tmp`, sets `TMPDIR=/tmp` and, unless the user has set it, `XDG_CACHE_HOME=/tmp/.cache`, and removes the directory when the session ends.

### Importing users' own configuration

Users' normal harness directories (`~/.claude`, `~/.codex`, `~/.pi/agent`, `~/.copilot`) are never bound, so on every launch the wrapper copies the portable parts of the launched harness's configuration into its YCRC state directory:

| Harness | Imported |
|---|---|
| Claude | `settings.json` (filtered), `CLAUDE.md`, `keybindings.json`, `skills/`, `agents/`, `commands/`, `output-styles/`, `rules/`, `hooks/` |
| Codex | `prompts/`, `skills/`, personal `AGENTS.md` |
| Pi | `settings.json` (filtered), `keybindings.json`, `APPEND_SYSTEM.md`, `prompts/`, `themes/`, `skills/`, `extensions/`, `agents/`, personal `AGENTS.md` |
| Copilot | `skills/`, `agents/`, personal `copilot-instructions.md` |

- Each YCRC state directory records the modification time and size of every original it has imported (`.ycrc-import-state`). An original is imported the first time it is seen, however old it is, and again whenever it changes. An unchanged original never overwrites edits to, or deletion of, the YCRC copy. Nothing is deleted. Symlinks in the user's tree are copied as their targets, since those targets are not mounted.
- Settings files are merged into the YCRC copy: the user's values win, and anything the harness already saved there (theme, changelog state and so on) is kept. Any other file that already exists in the YCRC directory with different content when its original is first seen is kept, with a one-line note at launch; a later edit to the original replaces it.
- Filtered settings drop anything that could select another provider or model, supply credentials, or install plugins/packages (Claude: `model`, `apiKeyHelper`, `enabledPlugins`, `sandbox`, provider/credential/proxy `env` entries and similar; Pi: `defaultProvider`, `defaultModel`, `enabledModels`, `packages`). Paths into the user's directory, such as hook scripts, are repointed at the YCRC copy. Claude's managed settings still take precedence.
- A user's personal `AGENTS.md`/`copilot-instructions.md` is appended below the administrator policy in a generated file, not substituted for it. Claude needs no merge: its policy is the managed `CLAUDE.md`, and the user's `CLAUDE.md` is read alongside it.
- Managed `bouchet-*` skills keep their names; a user skill of the same name is not imported. A user agent of the same name as a managed agent replaces it, matching the existing rule.
- Never imported: credentials, history, sessions and caches; Claude plugins, account-synced skills (`skills/synced`) and `~/.claude.json` (which holds MCP servers); Codex `config.toml`; Pi `models.json`/`auth.json`; Copilot `config.json`/`mcp-config.json`. MCP servers are excluded because they can send code to external services.
- Unreadable or malformed input produces a warning and the launch continues. `YCRC_IMPORT_USER_CONFIG=0` disables the import.

`tests/user-config-import.sh` exercises this against a throwaway home directory.

## Build

Images are layered: `images/base.def` holds everything the harnesses share
(runtime tooling, Python and pytest, the policy and skills, the slurm account),
and `images/<harness>.def` adds one client on top of it. Build on a compute node:

```bash
images/build.sh OUTDIR              # base + all four harness images
images/build.sh OUTDIR codex        # only Codex, on OUTDIR's existing base
```

This writes `OUTDIR/coding-agents-<harness>.sif` and records the harness versions
that shipped in `OUTDIR/versions.txt`. All four harnesses are unpinned, so every
build picks up their current releases; compare `versions.txt` with the deployed
versions and test before deploying. Claude's policy (`/etc/claude-code/CLAUDE.md`)
and Codex's and Copilot's skills come from the image, so changes to `AGENTS.md`
or `etc/agents/` need an image rebuild as well as a module rebuild. Stage each image into
`easybuild-sources/<letter>/<harness>-local/`, inject the checksums
(`eb <harness>-local.eb --inject-checksums --force`; after editing `AGENTS.md` or `etc/agents/`, first run `eb/make-site-tarball.sh`), and install with
`services/bin/rebuild-when-idle.sh`, which builds the bundle and all four
harness modules by default, or just the easyconfigs it is given. Installing a
new version proceeds at once; rebuilding an installed one waits for no active
sessions.

The launcher (`eb/coding-agents-wrapper.sh`) and the shared configuration in
`eb/` are one copy in this repository, installed into every harness module: the
launcher reads its configuration only from its own install directory.

### Tests

| Test | Needs | Covers |
| --- | --- | --- |
| `tests/skills-static.sh` | nothing | skill files well formed and listed in `AGENTS.md`; no `module purge`/`unload` or `agent`-partition examples; packaged tarball matches the source |
| `tests/user-binds.sh` | nothing | `--bind` parsing and checks; group shared directories |
| `tests/user-config-import.sh` | nothing | importing users' own harness configuration |
| `tests/model-name.sh` | nothing | looking up the served model's real name from the gateway, and falling back to the alias |
| `tests/module-e2e.sh` | a Slurm allocation | live sessions of all four harnesses against an install (`MODULE_ROOT`, default the test install): module layout, launch restrictions, tool use, credential isolation, `--bind`, group shared directories, StdEnv, the renv cache, and policy precedence over a conflicting project instruction file |

The precedence check in `module-e2e.sh` tests model behavior, so a failure there can be flaky; read the generated `run.sh` before concluding. Each harness reads the policy and skills through links into its module's `share/agents`, which resolve inside the container only under `/apps`. For a test install elsewhere, `module-e2e.sh` adds `--bind <install>/software` to every launch; without it those links dangle and the agents run with no YCRC policy. Do the same when testing a non-`/apps` install by hand.

Before production deployment:

1. rebuild and stage the images if `AGENTS.md`, `etc/agents/` or `images/` changed, and check `versions.txt`;
2. populate EasyBuild checksums;
3. run the tests above against the test install, and `MODULE_ROOT=/apps/software/system tests/module-e2e.sh` after deploying;
4. verify inherited credentials and user-supplied Apptainer/Singularity provider overrides do not enter the container (covered by `module-e2e.sh`).

## Slurm boundary caveat

The filesystem sandbox does **not** automatically extend to jobs submitted through Slurm. A submitted `sbatch`/`srun` workload executes outside this container under the user account and can therefore see whatever the destination node/partition normally exposes. Until agent-submitted jobs are constrained by a dedicated partition/storage policy or an equivalent Slurm-side control, treat Slurm submission as a deliberate privilege extension rather than part of the Apptainer sandbox. This matters especially for Codex, Copilot, and Pi because they do not inherit Claude's managed command-approval rules.

## Shared agent instructions

This release uses one canonical administrator policy, `AGENTS.md`. The image installs it as `/etc/agents/AGENTS.md`, and EasyBuild installs a host-visible read-only copy under `share/agents/AGENTS.md`. Claude receives `/etc/claude-code/CLAUDE.md` as a symlink to the image copy, while the launcher creates harness-specific symlinks in the dedicated Codex, Pi, and Copilot state directories that point to the host-visible module copy (or, when the user has personal instructions, a generated file with the policy first and theirs appended). This keeps Bouchet, shell-persistence, security, Slurm, and GPU-policy guidance identical across all four harnesses while allowing users to inspect the policy outside the container.

The policy explicitly states that each shell tool invocation is isolated, so module loads, Conda activation, exports, and sourced state must be combined with the dependent command in one shell invocation. It also prohibits attempts to evade YCRC idle-GPU enforcement, including `sleep` or artificial GPU activity used to retain otherwise idle GPU allocations.

## Shared Bouchet skills

The image contains one administrator-owned skill tree at `/etc/agents/skills`, and EasyBuild installs the same tree read-only under `share/agents/skills` so users can inspect the managed guidance from the host. The launcher exposes the managed skills without taking over a user's independent harness configuration:

- Claude: `$HOME/.claude-ycrc/skills` is a real writable user directory; each managed `bouchet-*` skill is a symlink to the host-visible `share/agents/skills/<skill>` tree. Users may create their own skills alongside those links.
- Codex: `/etc/codex/skills/<skill>` points to the canonical `/etc/agents/skills/<skill>` directories inside the image.
- Copilot: `COPILOT_SKILLS_DIRS=/etc/agents/skills`.
- Pi: `$PI_CODING_AGENT_DIR/skills` is a real writable user directory; each managed `bouchet-*` skill is a symlink to the host-visible module tree, and user skills may coexist alongside them.

Always-on security and environment invariants remain in `/etc/agents/AGENTS.md`; detailed operational workflows live in skills and are loaded on demand. The managed set covers storage, modules, Conda/Python, Jupyter (the Open OnDemand app and Papermill batch runs), R, ordinary Slurm use, CPU/parallel resource layouts, MPI, Slurm job troubleshooting, dSQ/job arrays, GPUs, Priority Tier, scavenge, Apptainer, AlphaFold, CryoSPARC, and Bouchet scratch lifecycle/retention. Four general research skills complement them: `bouchet-debugging` (reproduce, inspect evidence, fix the cause, verify), `bouchet-research-file-safety` (check ownership and provenance before destroying possibly irreplaceable research files, without gating routine edits), `bouchet-research-analysis` (make filters and joins visible, leave consequential scientific choices to the researcher, never present unverified results), and `bouchet-handoff` (a `HANDOFF.md` written only on request, for continuing in a new session or another harness). `bouchet-easybuild-admin` is for YCRC administrators only: it checks that the account is in the `support` group (others are directed to a support ticket) and that the agent was launched at the root of a `ycrc-ebfiles` clone, then prepares easyconfigs and runs test builds as Slurm jobs into `software_builds/test-install/`; it never installs into `/apps`.
