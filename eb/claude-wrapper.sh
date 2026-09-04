#!/usr/bin/env bash
set -euo pipefail

launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
image="${launcher_dir}/claude-mod.sif"
bind_config="${launcher_dir}/claude-bind.conf"
path_config="${launcher_dir}/claude-path.conf"
exclude_config="${launcher_dir}/claude-exclude.conf"
env_config="${launcher_dir}/claude-env.conf"

host_home="${HOME:?Error: HOME is not set}"
user_name="${USER:-$(id -un)}"
cluster_name="${CLUSTER:?Error: CLUSTER is not set}"

# Claude must run on an allocated compute node, not on a login node.
if ! host_name="$(hostname -s)"; then
    echo "Error: cannot determine the current hostname." >&2
    exit 1
fi

if [[ "${host_name,,}" == *login* ]]; then
    echo "Error: Claude cannot be launched on a login node: $host_name" >&2
    echo "Allocate a compute node before running Claude." >&2
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

# Remove exported variables whose names match an administrator-configured Bash
# glob. Required wrapper variables are protected from overly broad patterns.
sensitive_env_patterns=()
# shellcheck source=claude-env.conf
source "$env_config"

if [[ "$(declare -p sensitive_env_patterns 2>/dev/null)" != "declare -a "* ]]; then
    echo "Error: $env_config must define an indexed array named sensitive_env_patterns." >&2
    exit 1
fi

required_env_names=(HOME USER PATH CLUSTER)
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

# These Claude state directories are required and must exist before the bind
# array is processed. Other configured directories are optional and may be absent.
claude_config_dir="${host_home}/.claude"
claude_data_dir="${host_home}/.local/share/claude"
claude_config_file="${host_home}/.claude.json"

mkdir -p -- "$claude_config_dir" "$claude_data_dir"

# This administrator-controlled file defines a Bash array named "binds".
binds=()
# shellcheck source=claude-bind.conf
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
# shellcheck source=claude-path.conf
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

# Project and scratch filesystems differ between clusters. Keep these as base
# paths; each user's permitted roots are derived from their group memberships.
case "${cluster_name,,}" in
    bouchet)
        storage_bases=(
            /nfs/roberts/project
            /nfs/roberts/scratch
        )
        ;;
    grace|mccleary)
        storage_bases=(
            /gpfs/gibbs/project
            /vast/palmer/scratch
        )
        ;;
    *)
        echo "Error: unsupported cluster: $cluster_name" >&2
        echo "Supported clusters: bouchet, grace, and mccleary." >&2
        exit 1
        ;;
esac

# Claude operates in the directory from which the user invoked this launcher.
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
# descendants) to become Claude's working tree.
blocked_work_roots=("${configured_bind_roots[@]}" "${excluded_work_roots[@]}")
for blocked_root in "${blocked_work_roots[@]}"; do
    if [[ "$work_dir" == "$blocked_root" || "$work_dir" == "${blocked_root}/"* ]]; then
        echo "Error: Claude cannot be launched from an administratively restricted directory:" >&2
        echo "  $blocked_root" >&2
        echo "Resolved current directory: $work_dir" >&2
        exit 1
    fi
done

# A valid work directory must be strictly below the user's home, project, or
# scratch root. Hidden directories at any level below those roots are rejected.
if ! home_root="$(realpath -e -- "$host_home")"; then
    echo "Error: cannot resolve the home directory: $host_home" >&2
    exit 1
fi

allowed_roots=("$home_root")

# Users may belong to multiple groups, and any group can provide separate
# project and scratch spaces. Users are not expected to have convenience links
# to these spaces in their home directory.
group_output="$(groups 2>/dev/null || true)"

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

    # Requiring root/ rather than accepting root itself ensures that Claude is
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
    echo "Error: Claude must be launched from a non-hidden subdirectory of:" >&2
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
    echo "Error: Claude container not found or not readable: $image" >&2
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

# Persist an existing legacy configuration file, but do not create or require it.
if [[ -f "$claude_config_file" ]]; then
    bind_opts+=(--bind "${claude_config_file}:${host_home}/.claude.json")
fi

bind_opts+=("${configured_bind_opts[@]}")

# claude-mod.def's %runscript executes /usr/bin/claude, so all
# arguments after the image are passed directly to Claude.
exec apptainer run \
    --contain \
    "${gpu_opts[@]}" \
    "${path_opts[@]}" \
    "${bind_opts[@]}" \
    --pwd "$work_dir" \
    "$image" \
    "$@"
