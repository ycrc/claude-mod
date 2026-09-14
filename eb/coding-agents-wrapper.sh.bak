#!/usr/bin/env bash
set -euo pipefail

launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
image="${launcher_dir}/coding-agents.sif"
bind_config="${launcher_dir}/coding-agents-bind.conf"
path_config="${launcher_dir}/coding-agents-path.conf"
exclude_config="${launcher_dir}/coding-agents-exclude.conf"
env_config="${launcher_dir}/coding-agents-env.conf"
provider_config="${launcher_dir}/coding-agents-provider.conf"
codex_config="${launcher_dir}/codex-config.toml"
pi_models_config="${launcher_dir}/pi-models.json"

agent="$(basename -- "$0")"
case "$agent" in
    claude|codex|copilot|pi) ;;
    *)
        echo "Error: launcher must be invoked as claude, codex, copilot, or pi (got: $agent)." >&2
        exit 1
        ;;
esac

# Derive identity from the account database rather than trusting mutable HOME/USER
# environment variables. These values are part of the filesystem security boundary.
user_name="$(id -un)"
passwd_entry="$(getent passwd "$user_name" || true)"
if [[ -z "$passwd_entry" ]]; then
    echo "Error: cannot resolve passwd entry for $user_name." >&2
    exit 1
fi
host_home="$(cut -d: -f6 <<< "$passwd_entry")"
if [[ -z "$host_home" || "$host_home" != /* ]]; then
    echo "Error: invalid home directory for $user_name: $host_home" >&2
    exit 1
fi
# Force configuration files that reference $HOME to use the canonical account home.
export HOME="$host_home"
export USER="$user_name"

# Coding agents must run on a node that belongs to the active Slurm allocation.
# Do not rely on hostname conventions to distinguish login and compute nodes.
if ! host_name="$(hostname -s)"; then
    echo "Error: cannot determine the current hostname." >&2
    exit 1
fi

if [[ -z "${SLURM_JOB_ID:-}" || -z "${SLURM_JOB_NODELIST:-}" ]]; then
    echo "Error: $agent must be launched from within a Slurm compute allocation." >&2
    echo "Allocate a compute node and run $agent there (for example with srun --pty bash)." >&2
    exit 1
fi

if [[ ! -x /opt/slurm/current/bin/scontrol ]]; then
    echo "Error: cannot verify the Slurm allocation because scontrol is unavailable." >&2
    exit 1
fi

current_host_is_allocated=false
while IFS= read -r allocated_host; do
    if [[ "$host_name" == "$allocated_host" ]]; then
        current_host_is_allocated=true
        break
    fi
done < <(/opt/slurm/current/bin/scontrol show hostnames "$SLURM_JOB_NODELIST")

if [[ "$current_host_is_allocated" != true ]]; then
    echo "Error: $agent cannot run on $host_name because it is not a node in Slurm allocation $SLURM_JOB_ID." >&2
    echo "Enter an allocated compute node (for example with srun --pty bash) and retry." >&2
    exit 1
fi

if [[ ! -r "$bind_config" ]]; then
    echo "Error: bind configuration not found or not readable: $bind_config" >&2
    exit 1
fi

if [[ ! -r "$path_config" ]]; then
    echo "Error: PATH configuration not found or not readable: $path_config" >&2
    exit 1
fi

if [[ ! -r "$exclude_config" ]]; then
    echo "Error: exclusion configuration not found or not readable: $exclude_config" >&2
    exit 1
fi

if [[ ! -r "$env_config" ]]; then
    echo "Error: environment configuration not found or not readable: $env_config" >&2
    exit 1
fi

if [[ ! -r "$provider_config" ]]; then
    echo "Error: provider configuration not found or not readable: $provider_config" >&2
    exit 1
fi

# Remove exported variables whose names match an administrator-configured Bash
# glob. Required wrapper variables are protected from overly broad patterns.
sensitive_env_patterns=()
# shellcheck source=coding-agents-env.conf
source "$env_config"

if [[ "$(declare -p sensitive_env_patterns 2>/dev/null)" != "declare -a "* ]]; then
    echo "Error: $env_config must define an indexed array named sensitive_env_patterns." >&2
    exit 1
fi

required_env_names=(HOME USER PATH)
for sensitive_pattern in "${sensitive_env_patterns[@]}"; do
    if [[ -z "$sensitive_pattern" ]]; then
        echo "Error: empty environment-variable pattern in $env_config." >&2
        exit 1
    fi

    for required_env_name in "${required_env_names[@]}"; do
        if [[ "$required_env_name" == $sensitive_pattern ]]; then
            echo "Error: environment pattern '$sensitive_pattern' matches required variable $required_env_name." >&2
            exit 1
        fi
    done
done

while IFS= read -r exported_env_name; do
    for sensitive_pattern in "${sensitive_env_patterns[@]}"; do
        if [[ "$exported_env_name" == $sensitive_pattern ]]; then
            unset "$exported_env_name"
            printf 'Warning: unset sensitive environment variable: %s\n' "$exported_env_name"
            break
        fi
    done
done < <(compgen -e)

# Load administrator-owned provider/site settings after inherited credential-like
# variables have been removed. The installed file, not the user environment, is
# authoritative for cluster/model/endpoint selection.
# shellcheck source=coding-agents-provider.conf
source "$provider_config"
: "${YCRC_CLUSTER:?Error: YCRC_CLUSTER missing from $provider_config}"
: "${YCRC_AGENT_MODEL:?Error: YCRC_AGENT_MODEL missing from $provider_config}"
: "${YCRC_AGENT_AUTH:?Error: YCRC_AGENT_AUTH missing from $provider_config}"
: "${YCRC_AGENT_MAX_CONTEXT:?Error: YCRC_AGENT_MAX_CONTEXT missing from $provider_config}"
: "${YCRC_AGENT_MAX_OUTPUT:?Error: YCRC_AGENT_MAX_OUTPUT missing from $provider_config}"
: "${YCRC_AGENT_MAX_PROMPT:?Error: YCRC_AGENT_MAX_PROMPT missing from $provider_config}"
: "${YCRC_CLAUDE_BASE_URL:?Error: YCRC_CLAUDE_BASE_URL missing from $provider_config}"
: "${YCRC_CLAUDE_EFFORT:?Error: YCRC_CLAUDE_EFFORT missing from $provider_config}"
: "${YCRC_COPILOT_BASE_URL:?Error: YCRC_COPILOT_BASE_URL missing from $provider_config}"
cluster_name="$YCRC_CLUSTER"

# Persistent client state directories. They are deliberately separate from
# users' normal Codex/Copilot/Pi homes so the module can enforce local-provider defaults.
claude_config_dir="${host_home}/.claude"
claude_data_dir="${host_home}/.local/share/claude"
claude_config_file="${host_home}/.claude.json"
codex_home="${host_home}/.codex-ycrc"
pi_home="${host_home}/.pi-ycrc"
copilot_home="${host_home}/.copilot-ycrc"
copilot_cache_home="${host_home}/.cache/copilot-ycrc"

conda_state_dir="${host_home}/.conda"
r_library_dir="${host_home}/R"

mkdir -p -- \
    "$claude_config_dir" \
    "$claude_data_dir" \
    "$codex_home" \
    "$pi_home" \
    "$copilot_home" \
    "$copilot_cache_home" \
    "$conda_state_dir" \
    "$r_library_dir"

# All harnesses consume the same administrator-owned instruction policy from
# /etc/agents/AGENTS.md inside the image. Refresh the dedicated-state symlinks
# on every launch to prevent policy drift.
ln -sfn /etc/agents/AGENTS.md "${codex_home}/AGENTS.md"
ln -sfn /etc/agents/AGENTS.md "${pi_home}/AGENTS.md"
ln -sfn /etc/agents/AGENTS.md "${copilot_home}/copilot-instructions.md"

# Skills are maintained once at /etc/agents/skills inside the image. Claude and
# Pi discover skills from their normal state locations. For Claude, preserve a
# pre-existing real ~/.claude/skills directory and add the Bouchet skills as
# per-skill symlinks; otherwise use a single root symlink. Never delete user
# skill content.
link_skill_tree_non_destructive() {
    local target_root="$1"
    local skill_name target_skill

    if [[ -L "$target_root" || ! -e "$target_root" ]]; then
        ln -sfn /etc/agents/skills "$target_root"
        return
    fi

    if [[ ! -d "$target_root" ]]; then
        echo "Error: skill path exists but is not a directory or symlink: $target_root" >&2
        exit 1
    fi

    for skill_name in bouchet-storage bouchet-modules bouchet-conda bouchet-r bouchet-slurm bouchet-gpu; do
        target_skill="${target_root}/${skill_name}"
        if [[ -L "$target_skill" || ! -e "$target_skill" ]]; then
            ln -sfn "/etc/agents/skills/${skill_name}" "$target_skill"
        elif [[ -d "$target_skill" ]]; then
            echo "Error: existing user skill conflicts with administrator skill: $target_skill" >&2
            exit 1
        else
            echo "Error: existing path conflicts with administrator skill: $target_skill" >&2
            exit 1
        fi
    done
}

link_skill_tree_non_destructive "${claude_config_dir}/skills"
ln -sfn /etc/agents/skills "${pi_home}/skills"

# Seed Codex with the administrator provider configuration on first use. Codex
# persists project trust entries in config.toml, so this file must remain writable.
# The surrounding CODEX_HOME is already a dedicated YCRC state directory.
if [[ ! -s "${codex_home}/config.toml" ]]; then
    install -m 0600 -- "$codex_config" "${codex_home}/config.toml"
fi
# Keep model sizing metadata current for existing Codex state while preserving
# project trust entries and other Codex-managed state.
codex_user_config="${codex_home}/config.toml"
if grep -qE '^[[:space:]]*model_context_window[[:space:]]*=' "$codex_user_config"; then
    sed -i -E "s|^[[:space:]]*model_context_window[[:space:]]*=.*$|model_context_window = ${YCRC_AGENT_MAX_CONTEXT}|" "$codex_user_config"
else
    sed -i "/^model_provider[[:space:]]*=/a model_context_window = ${YCRC_AGENT_MAX_CONTEXT}" "$codex_user_config"
fi
if grep -qE '^[[:space:]]*model_max_output_tokens[[:space:]]*=' "$codex_user_config"; then
    sed -i -E "s|^[[:space:]]*model_max_output_tokens[[:space:]]*=.*$|model_max_output_tokens = ${YCRC_AGENT_MAX_OUTPUT}|" "$codex_user_config"
else
    sed -i "/^model_context_window[[:space:]]*=/a model_max_output_tokens = ${YCRC_AGENT_MAX_OUTPUT}" "$codex_user_config"
fi
# Normal-user autonomy profile: Codex does not prompt and does not add an
# inner filesystem/process sandbox. The administrator-managed Apptainer
# container remains the execution boundary.
if grep -qE '^[[:space:]]*approval_policy[[:space:]]*=' "$codex_user_config"; then
    sed -i -E 's|^[[:space:]]*approval_policy[[:space:]]*=.*$|approval_policy = "never"|' "$codex_user_config"
else
    sed -i '/^model_max_output_tokens[[:space:]]*=/a approval_policy = "never"' "$codex_user_config"
fi
if grep -qE '^[[:space:]]*sandbox_mode[[:space:]]*=' "$codex_user_config"; then
    sed -i -E 's|^[[:space:]]*sandbox_mode[[:space:]]*=.*$|sandbox_mode = "danger-full-access"|' "$codex_user_config"
else
    sed -i '/^approval_policy[[:space:]]*=/a sandbox_mode = "danger-full-access"' "$codex_user_config"
fi
chmod 0600 "$codex_user_config"
# Pi's managed models file is overlaid read-only at launch.
touch -- "${pi_home}/models.json"

# This administrator-controlled file defines a Bash array named "binds".
binds=()
# shellcheck source=coding-agents-bind.conf
source "$bind_config"

if [[ "$(declare -p binds 2>/dev/null)" != "declare -a "* ]]; then
    echo "Error: $bind_config must define an indexed array named binds." >&2
    exit 1
fi

configured_bind_opts=()
configured_bind_roots=()
configured_bind_paths=()

for bind_entry in "${binds[@]}"; do
    configured_mode=""

    case "$bind_entry" in
        *:ro)
            configured_path="${bind_entry%:ro}"
            configured_mode="ro"
            ;;
        *:rw)
            configured_path="${bind_entry%:rw}"
            configured_mode="rw"
            ;;
        *:*)
            echo "Error: invalid bind mode in $bind_config: $bind_entry" >&2
            exit 1
            ;;
        *)
            configured_path="$bind_entry"
            ;;
    esac

    if [[ "$configured_path" != /* || "$configured_path" == / ]]; then
        echo "Error: configured bind must be an absolute directory other than /: $configured_path" >&2
        exit 1
    fi

    if [[ "$configured_path" == *,* ]]; then
        echo "Error: configured bind path cannot contain ',': $configured_path" >&2
        exit 1
    fi

    # Missing paths, including dangling symlinks, are optional and are skipped.
    if [[ ! -e "$configured_path" ]]; then
        continue
    fi

    if ! resolved_bind_path="$(realpath -e -- "$configured_path")"; then
        echo "Error: cannot resolve configured bind path: $configured_path" >&2
        exit 1
    fi

    if [[ ! -d "$resolved_bind_path" ]]; then
        echo "Error: configured bind path is not a directory: $configured_path" >&2
        exit 1
    fi

    # Resolve the host source, but preserve the configured path as the path
    # visible inside the container. This makes entries containing $HOME and
    # entries that are symlinks behave as their configuration suggests.
    bind_spec="${resolved_bind_path}:${configured_path}"
    if [[ -n "$configured_mode" ]]; then
        bind_spec+=":${configured_mode}"
    fi

    configured_bind_opts+=(--bind "$bind_spec")

    # Also expose a symlink target at its physical path. Conda environments in
    # particular may record and use their resolved absolute prefix.
    # This is important to accomodate references to logical or physical paths in users code
    if [[ "$resolved_bind_path" != "$configured_path" ]]; then
        physical_bind_spec="${resolved_bind_path}:${resolved_bind_path}"
        if [[ -n "$configured_mode" ]]; then
            physical_bind_spec+=":${configured_mode}"
        fi
        configured_bind_opts+=(--bind "$physical_bind_spec")
    fi

    configured_bind_roots+=("$resolved_bind_path")
    configured_bind_paths+=("$configured_path")
done

# Add configured tool directories to the container PATH. Each PATH entry must
# be covered by a configured bind so that it exists in the contained filesystem.
path_entries=()
# shellcheck source=coding-agents-path.conf
source "$path_config"

if [[ "$(declare -p path_entries 2>/dev/null)" != "declare -a "* ]]; then
    echo "Error: $path_config must define an indexed array named path_entries." >&2
    exit 1
fi

container_path_entries=()
declare -A seen_path_entries=()

for path_entry in "${path_entries[@]}"; do
    if [[ "$path_entry" != /* || "$path_entry" == / ]]; then
        echo "Error: configured PATH entry must be an absolute directory other than /: $path_entry" >&2
        exit 1
    fi

    if [[ "$path_entry" == *:* || "$path_entry" == *,* ]]; then
        echo "Error: configured PATH entry cannot contain ':' or ',': $path_entry" >&2
        exit 1
    fi

    if [[ ! -e "$path_entry" ]]; then
        continue
    fi

    if ! resolved_path_entry="$(realpath -e -- "$path_entry")"; then
        echo "Error: cannot resolve configured PATH entry: $path_entry" >&2
        exit 1
    fi

    if [[ ! -d "$resolved_path_entry" ]]; then
        echo "Error: configured PATH entry is not a directory: $path_entry" >&2
        exit 1
    fi

    path_entry_is_bound=false
    for bind_index in "${!configured_bind_paths[@]}"; do
        bind_path="${configured_bind_paths[$bind_index]}"
        bind_root="${configured_bind_roots[$bind_index]}"

        if [[ "$path_entry" == "$bind_path" ||
              "$path_entry" == "${bind_path}/"* ||
              "$resolved_path_entry" == "$bind_root" ||
              "$resolved_path_entry" == "${bind_root}/"* ]]; then
            path_entry_is_bound=true
            break
        fi
    done

    if [[ "$path_entry_is_bound" != true ]]; then
        echo "Error: configured PATH entry is not covered by a configured bind: $path_entry" >&2
        exit 1
    fi

    # Keep the logical path so symlinked prefixes such as /opt/slurm/current
    # appear in PATH exactly as configured.
    path_entry="${path_entry%/}"
    if [[ -z "${seen_path_entries[$path_entry]+x}" ]]; then
        container_path_entries+=("$path_entry")
        seen_path_entries["$path_entry"]=1
    fi
done

path_opts=()
if (( ${#container_path_entries[@]} > 0 )); then
    container_prepend_path="$(IFS=:; printf '%s' "${container_path_entries[*]}")"
    path_opts+=(--env "PREPEND_PATH=${container_prepend_path}")
fi

# This file lists directories that are neither bound nor permitted as a working
# directory. It is separate from binds so exclusion never grants visibility.
excluded_workdirs=()
# shellcheck source=claude-exclude.conf
source "$exclude_config"

if [[ "$(declare -p excluded_workdirs 2>/dev/null)" != "declare -a "* ]]; then
    echo "Error: $exclude_config must define an indexed array named excluded_workdirs." >&2
    exit 1
fi

excluded_work_roots=()
for excluded_path in "${excluded_workdirs[@]}"; do
    if [[ "$excluded_path" != /* || "$excluded_path" == / ]]; then
        echo "Error: excluded path must be an absolute directory other than /: $excluded_path" >&2
        exit 1
    fi

    if [[ ! -e "$excluded_path" ]]; then
        echo "Warning: skipping missing excluded path: $excluded_path" >&2
        continue
    fi

    if ! resolved_excluded_path="$(realpath -e -- "$excluded_path")"; then
        echo "Error: cannot resolve excluded path: $excluded_path" >&2
        exit 1
    fi

    if [[ ! -d "$resolved_excluded_path" ]]; then
        echo "Error: excluded path is not a directory: $excluded_path" >&2
        exit 1
    fi

    excluded_work_roots+=("$resolved_excluded_path")
done

# This module is Bouchet-specific. Each user's permitted project, scratch,
# and PI roots are derived from their Unix group memberships below.
if [[ "${cluster_name,,}" != "bouchet" ]]; then
    echo "Error: unsupported cluster: $cluster_name" >&2
    echo "This coding-agents build is for Bouchet only." >&2
    exit 1
fi
storage_bases=(
    /nfs/roberts/project
    /nfs/roberts/scratch
    /nfs/roberts/pi
)

# The agent operates in the directory from which the user invoked this launcher.
# Resolve it before binding so sessions use one canonical path even when the
# user entered the directory through a symlink.
if ! work_dir="$(realpath -e -- .)"; then
    echo "Error: cannot resolve the current working directory: $PWD" >&2
    exit 1
fi

if [[ ! -d "$work_dir" ]]; then
    echo "Error: the current working directory is not a directory: $work_dir" >&2
    exit 1
fi

# Never allow a configured bind or explicitly excluded directory (or any of its
# descendants) to become the agent's working tree.
blocked_work_roots=("${configured_bind_roots[@]}" "${excluded_work_roots[@]}")
for blocked_root in "${blocked_work_roots[@]}"; do
    if [[ "$work_dir" == "$blocked_root" || "$work_dir" == "${blocked_root}/"* ]]; then
        echo "Error: $agent cannot be launched from an administratively restricted directory:" >&2
        echo "  $blocked_root" >&2
        echo "Resolved current directory: $work_dir" >&2
        exit 1
    fi
done

# A valid work directory must be strictly below the user's home, project,
# scratch, or PI root. Hidden directories at any level below those roots are rejected.
if ! home_root="$(realpath -e -- "$host_home")"; then
    echo "Error: cannot resolve the home directory: $host_home" >&2
    exit 1
fi

allowed_roots=("$home_root")

# Users may belong to multiple groups, and any group can provide separate
# project, scratch, and PI spaces. Users are not expected to have convenience links
# to these spaces in their home directory.
group_output="$(id -Gn "$user_name" 2>/dev/null || true)"

for group_name in $group_output; do
    for storage_base in "${storage_bases[@]}"; do
        storage_path="${storage_base}/${group_name}/${user_name}"

        # A group space is optional: users may not have a directory provisioned
        # under every group to which they belong.
        [[ -d "$storage_path" ]] || continue

        if ! storage_root="$(realpath -e -- "$storage_path")"; then
            echo "Error: cannot resolve storage directory: $storage_path" >&2
            exit 1
        fi

        allowed_roots+=("$storage_root")
    done
done

is_non_hidden_subdirectory() {
    local path="$1"
    local root="$2"
    local relative_path
    local component
    local -a components

    # Requiring root/ rather than accepting root itself ensures that the agent is
    # launched only from a subdirectory, never from an entire storage root.
    [[ "$path" == "${root}/"* ]] || return 1
    relative_path="${path#"${root}/"}"
    IFS='/' read -r -a components <<< "$relative_path"

    for component in "${components[@]}"; do
        [[ "$component" == .* ]] && return 1
    done

    return 0
}

work_dir_allowed=false
for allowed_root in "${allowed_roots[@]}"; do
    if is_non_hidden_subdirectory "$work_dir" "$allowed_root"; then
        work_dir_allowed=true
        break
    fi
done

if [[ "$work_dir_allowed" != true ]]; then
    echo "Error: $agent must be launched from a non-hidden subdirectory of:" >&2
    printf '  %s\n' "${allowed_roots[@]}" >&2
    echo "Resolved current directory: $work_dir" >&2
    exit 1
fi

if [[ ! -r "$work_dir" || ! -w "$work_dir" || ! -x "$work_dir" ]]; then
    echo "Error: the working directory must be readable, writable, and searchable: $work_dir" >&2
    exit 1
fi

if ! command -v apptainer >/dev/null 2>&1; then
    echo "Error: apptainer is not available. Load the Apptainer module first." >&2
    exit 1
fi

if [[ ! -r "$image" ]]; then
    echo "Error: coding-agents container not found or not readable: $image" >&2
    exit 1
fi

# Enable NVIDIA integration only when the host exposes both the NVIDIA control
# device and at least one numbered GPU device. CPU-only nodes omit --nv.
gpu_opts=()
if [[ -c /dev/nvidiactl ]] &&
   compgen -G '/dev/nvidia[0-9]*' >/dev/null; then
    gpu_opts+=(--nv)
fi

bind_opts=(
    --bind "${work_dir}:${work_dir}"
)

# --no-mount bind-paths intentionally disables site/system default binds. Re-add
# only the host name-resolution files required to resolve the internal YCRC
# inference-service hostname from inside the contained environment.
for resolver_file in /etc/resolv.conf /etc/hosts /etc/nsswitch.conf; do
    if [[ -r "$resolver_file" ]]; then
        bind_opts+=(--bind "${resolver_file}:${resolver_file}:ro")
    fi
done

# Persist an existing legacy configuration file, but do not create or require it.
if [[ -f "$claude_config_file" ]]; then
    bind_opts+=(--bind "${claude_config_file}:${host_home}/.claude.json")
fi

bind_opts+=("${configured_bind_opts[@]}")

# Remove host-controlled Apptainer mechanisms that can add mounts or inject
# container environment variables. In particular, APPTAINER_BIND/BINDPATH/MOUNT
# would otherwise bypass the wrapper's approved bind list.
for runtime_env_name in $(compgen -e); do
    case "$runtime_env_name" in
        APPTAINERENV_*|SINGULARITYENV_*) unset "$runtime_env_name" ;;
    esac
done
unset \
    APPTAINER_BIND APPTAINER_BINDPATH APPTAINER_MOUNT APPTAINER_ENV_FILE \
    APPTAINER_CONFIG_FILE APPTAINER_OVERLAY APPTAINER_OVERLAYIMAGE APPTAINER_HOME \
    SINGULARITY_BIND SINGULARITY_BINDPATH SINGULARITY_MOUNT SINGULARITY_ENV_FILE \
    SINGULARITY_CONFIG_FILE SINGULARITY_OVERLAY SINGULARITY_OVERLAYIMAGE SINGULARITY_HOME \
    || true


client_env_opts=()
client_args=()
case "$agent" in
    claude)
        client_bin=claude
        client_env_opts+=(
            --env "DISABLE_BUG_COMMAND=1"
            --env "ANTHROPIC_TELEMETRY_DISABLED=1"
            --env "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
            --env "ANTHROPIC_BASE_URL=${YCRC_CLAUDE_BASE_URL}"
            --env "ANTHROPIC_MODEL=${YCRC_AGENT_MODEL}"
            --env "ANTHROPIC_SMALL_FAST_MODEL=${YCRC_AGENT_MODEL}"
            --env "ANTHROPIC_AUTH_TOKEN=${YCRC_AGENT_AUTH}"
            --env "CLAUDE_CODE_EFFORT_LEVEL=${YCRC_CLAUDE_EFFORT:-xhigh}"
            --env "CLAUDE_CODE_MAX_CONTEXT_TOKENS=${YCRC_AGENT_MAX_CONTEXT}"
        )
        ;;
    codex)
        client_bin=codex
        [[ -r "$codex_config" ]] || { echo "Error: missing Codex config: $codex_config" >&2; exit 1; }
        client_env_opts+=(
            --env "CODEX_HOME=${codex_home}"
            --env "BOUCHET_API_KEY=${YCRC_AGENT_AUTH}"
        )
        ;;
    pi)
        client_bin=pi
        [[ -r "$pi_models_config" ]] || { echo "Error: missing Pi models config: $pi_models_config" >&2; exit 1; }
        bind_opts+=(--bind "${pi_models_config}:${pi_home}/models.json:ro")
        client_env_opts+=(
            --env "PI_CODING_AGENT_DIR=${pi_home}"
            --env "PI_OFFLINE=true"
            --env "PI_SKIP_VERSION_CHECK=1"
            --env "PI_TELEMETRY=0"
            --env "YCRC_PI_API_KEY=${YCRC_AGENT_AUTH}"
        )
        # Explicit selection prevents Pi from restoring a previously selected
        # non-Bouchet provider/model from persistent session state.
        client_args+=(--approve --provider bouchet --model "${YCRC_AGENT_MODEL}")
        ;;
    copilot)
        client_bin=copilot
        client_env_opts+=(
            --env "COPILOT_HOME=${copilot_home}"
            --env "COPILOT_CACHE_HOME=${copilot_cache_home}"
            --env "COPILOT_PROVIDER_TYPE=openai"
            --env "COPILOT_PROVIDER_BASE_URL=${YCRC_COPILOT_BASE_URL}"
            --env "COPILOT_PROVIDER_API_KEY=${YCRC_AGENT_AUTH}"
            --env "COPILOT_MODEL=${YCRC_AGENT_MODEL}"
            --env "COPILOT_PROVIDER_MAX_PROMPT_TOKENS=${YCRC_AGENT_MAX_PROMPT}"
            --env "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=${YCRC_AGENT_MAX_OUTPUT}"
            --env "COPILOT_SKILLS_DIRS=/etc/agents/skills"
            --env "COPILOT_ALLOW_ALL=true"
            --env "COPILOT_OFFLINE=true"
        )
        client_args+=(--disable-builtin-mcps)
        ;;
esac

exec apptainer exec \
    --contain \
    --no-mount hostfs,bind-paths,cwd \
    "${gpu_opts[@]}" \
    "${path_opts[@]}" \
    "${client_env_opts[@]}" \
    "${bind_opts[@]}" \
    --pwd "$work_dir" \
    "$image" \
    "$client_bin" \
    "${client_args[@]}" \
    "$@"
