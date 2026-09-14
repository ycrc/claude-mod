# Bouchet Coding Agents 1.0


## Choosing a harness

All four launchers use the same Bouchet-local `Qwen3.8-27B` model and the same outer security boundary. In Bouchet validation with the packaged harness versions, their practical strengths were:

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
module load coding-agents
claude
codex
copilot
pi
```

All four clients share the same outer Apptainer containment and Bouchet storage policy. The launcher removes inherited credential-like environment variables and host-controlled Apptainer mount/environment overrides before injecting administrator-controlled local-model settings from an installed read-only provider configuration.


## Bouchet-only scope

This build is intentionally Bouchet-specific. Active runtime configuration contains only Roberts storage paths and Bouchet site behavior. Administrator-owned skills under `/etc/agents/skills/` contain Bouchet-only operational guidance and omit examples and filesystem paths for other clusters. The canonical policy is `/etc/agents/AGENTS.md`.

Bouchet scratch retention is 30 days. The runtime policy and skills use that value consistently.

## Security model

The Apptainer wrapper is the common security boundary for all four agents. It:

- requires an active Slurm allocation and verifies the current host is in `SLURM_JOB_NODELIST`;
- derives the real account name/home from `id`/`getent` rather than trusting exported `USER` or `HOME`;
- uses `--contain` and disables implicit `hostfs`, administrator bind-path, and current-working-directory mounts before adding its own approved binds;
- binds only the launch directory plus explicitly approved state/software paths;
- preserves Bouchet's group-derived project/scratch/PI access validation;
- rejects hidden working directories, storage roots, configured bind roots, and excluded locations;
- strips credential-like exported variables before the container is started;
- clears `APPTAINER_BIND`, `APPTAINER_BINDPATH`, `APPTAINER_MOUNT`, environment-file/overlay controls, and all inherited `APPTAINERENV_*` / `SINGULARITYENV_*` injections so users cannot add mounts or override the contained client environment;
- keeps site software and Slurm paths read-only where configured.

Claude additionally retains its managed-settings policy inside the image. Codex, Copilot, and Pi rely on the shared outer containment boundary plus their managed local-provider configuration.

## Local model

The current Bouchet defaults use `Qwen3.8-27B` on the YCRC-local inference service.

- Claude: Anthropic-compatible endpoint.
- Codex: OpenAI Responses API via the read-only `codex-config.toml` source.
- Copilot: OpenAI-compatible local provider with `COPILOT_OFFLINE=true` to suppress Copilot's own automatic external-provider/startup activity; this does not disable Bouchet network access.
- Pi: managed `openai-completions` Bouchet provider, launched explicitly with `--provider bouchet --model Qwen3.8-27B`; Pi automatic startup/version-check activity and telemetry are disabled; this does not disable Bouchet network access.

The installed `coding-agents-provider.conf` owns the cluster, shared model/auth values, and Claude/Copilot endpoint values; the wrapper sources it after scrubbing inherited credentials. Codex's base URL remains in the administrator-owned `codex-config.toml`, while Pi's base URL remains in the administrator-owned `pi-models.json`; update those files together if the inference endpoint changes.

## Persistent state

The wrapper creates only explicitly approved user state/package directories before processing binds, including Claude, Codex, Copilot, Pi, Conda, and R state. The user's full home directory is never bound. Host `/tmp` and `/var/tmp` are also not bound; `--contain` supplies isolated temporary directories instead.

## Build

Build `coding-agents.sif` with `coding-agents.def`, then place the SIF and the files from `eb/` together as EasyBuild sources for `coding-agents.eb`.

Before production deployment:

1. pin tested Claude, Codex, and Copilot CLI versions (Pi is pinned to the validated 0.85.1 release);
2. populate EasyBuild checksums;
3. run the Bouchet sandbox regression tests for all four launchers;
4. verify local-model tool use for all four clients;
5. verify inherited credentials and user-supplied Apptainer/Singularity provider overrides do not enter the container.

## Slurm boundary caveat

The filesystem sandbox does **not** automatically extend to jobs submitted through Slurm. A submitted `sbatch`/`srun` workload executes outside this container under the user account and can therefore see whatever the destination node/partition normally exposes. Until agent-submitted jobs are constrained by a dedicated partition/storage policy or an equivalent Slurm-side control, treat Slurm submission as a deliberate privilege extension rather than part of the Apptainer sandbox. This matters especially for Codex, Copilot, and Pi because they do not inherit Claude's managed command-approval rules.

## Shared agent instructions

This release uses one canonical administrator policy, `AGENTS.md`. The image installs it as `/etc/agents/AGENTS.md`, and EasyBuild installs a host-visible read-only copy under `share/agents/AGENTS.md`. Claude receives `/etc/claude-code/CLAUDE.md` as a symlink to the image copy, while the launcher creates harness-specific symlinks in the dedicated Codex, Pi, and Copilot state directories that point to the host-visible module copy. This keeps Bouchet, shell-persistence, security, Slurm, and GPU-policy guidance identical across all four harnesses while allowing users to inspect the policy outside the container.

The policy explicitly states that each shell tool invocation is isolated, so module loads, Conda activation, exports, and sourced state must be combined with the dependent command in one shell invocation. It also prohibits attempts to evade YCRC idle-GPU enforcement, including `sleep` or artificial GPU activity used to retain otherwise idle GPU allocations.

## Shared Bouchet skills

The image contains one administrator-owned skill tree at `/etc/agents/skills`, and EasyBuild installs the same tree read-only under `share/agents/skills` so users can inspect the managed guidance from the host. The launcher exposes the managed skills without taking over a user's independent harness configuration:

- Claude: `$HOME/.claude-ycrc/skills` is a real writable user directory; each managed `bouchet-*` skill is a symlink to the host-visible `share/agents/skills/<skill>` tree. Users may create their own skills alongside those links.
- Codex: `/etc/codex/skills/<skill>` points to the canonical `/etc/agents/skills/<skill>` directories inside the image.
- Copilot: `COPILOT_SKILLS_DIRS=/etc/agents/skills`.
- Pi: `$PI_CODING_AGENT_DIR/skills` is a real writable user directory; each managed `bouchet-*` skill is a symlink to the host-visible module tree, and user skills may coexist alongside them.

Always-on security and environment invariants remain in `/etc/agents/AGENTS.md`; detailed operational workflows live in skills and are loaded on demand. The managed set covers storage, modules, Conda/Python, R, ordinary Slurm use, CPU/parallel resource layouts, Slurm job troubleshooting, dSQ/job arrays, and GPUs.
