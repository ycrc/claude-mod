#!/usr/bin/env bash
# =============================================================================
# claude-wrapper.sh -- the claude-mod launcher, installed by EasyBuild as `claude`.
#
# Runs Claude Code inside the claude-mod Apptainer image with safer defaults:
# Claude sees only the directory it was started from, administrator-chosen
# paths, and directories the user names with --bind; sensitive environment
# variables are removed first; and it cannot run on a login node.
# Full policy: docs/claude-wrapper.md.
#
# Launch sequence:
#   1. Locate the files; take out module options; --ycrc-help exits here.
#   2. Check required environment variables.
#   3. Login-node protection.
#   4. Environment scrubbing.
#   5. Claude state directories.
#   6. Admin binds (claude-bind.conf).
#   7. Container PATH (claude-path.conf).
#   8. Exclusions (claude-exclude.conf).
#   9. Working-directory policy.
#  10. Launch prerequisites (apptainer, image).
#  11. User binds (--bind).
#  12. GPU support.
#  13. Bind ordering, then launch.
#
# Files read, all beside this script:
#   claude-wrapper-functions.sh   shared helpers and the longer steps
#   claude-env.conf               sensitive environment-variable name patterns
#   claude-bind.conf              directories to bind and their modes
#   claude-path.conf              bound tool directories to prepend to PATH
#   claude-exclude.conf           directories that may not be the work dir
#   claude-mod.sif                the Apptainer image
# =============================================================================
set -euo pipefail

# --- Setup --------------------------------------------------------------------
# Everything is located relative to this script's real directory, so the
# user's current directory never affects which files are used.
launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
functions_file="${launcher_dir}/claude-wrapper-functions.sh"
if [[ ! -r "$functions_file" ]]; then
    echo "Error: launcher functions not found or not readable: $functions_file" >&2
    exit 1
fi
# shellcheck source=SCRIPTDIR/claude-wrapper-functions.sh
source "$functions_file"

image="${launcher_dir}/claude-mod.sif"
env_config="${launcher_dir}/claude-env.conf"
bind_config="${launcher_dir}/claude-bind.conf"
path_config="${launcher_dir}/claude-path.conf"
exclude_config="${launcher_dir}/claude-exclude.conf"

# --- Module options -----------------------------------------------------------
# Take the module's own options out of the arguments; everything else is meant
# for Claude. Scanning stops at "--", which is passed on with everything after
# it. --bind values are only syntax-checked here; their paths are checked under
# "User binds". Sets: show_help, user_bind_specs, claude_args.
show_help=false
user_bind_specs=()
claude_args=()
while (( $# > 0 )); do
    case "$1" in
        --)
            claude_args+=("$@")
            break
            ;;
        --ycrc-help)
            show_help=true
            ;;
        --bind=*)
            add_user_bind_specs "${1#--bind=}"
            ;;
        --bind|-B)
            if (( $# < 2 )); then
                die "$1 requires a directory, e.g. $1 DIR or $1 DIR:rw"
            fi
            add_user_bind_specs "$2"
            shift
            ;;
        *)
            claude_args+=("$1")
            ;;
    esac
    shift
done

# --- Help ---------------------------------------------------------------------
# `claude --ycrc-help` prints module usage and exits before every other check,
# so it works anywhere: on a login node, without CLUSTER, in any directory.
if [[ "$show_help" == true ]]; then
    print_ycrc_help
    exit 0
fi

# --- Required environment -----------------------------------------------------
# HOME locates the user's home and Claude state; CLUSTER selects the storage
# layout. USER falls back to the account name.
if [[ -z "${HOME:-}" ]]; then
    die "HOME is not set"
fi
if [[ -z "${CLUSTER:-}" ]]; then
    die "CLUSTER is not set"
fi
host_home="$HOME"
user_name="${USER:-$(id -un)}"
cluster_name="$CLUSTER"

# --- Login-node protection ----------------------------------------------------
# Claude must run on an allocated compute node. Any short hostname containing
# "login" (case-insensitive) is refused.
if ! host_name="$(hostname -s)"; then
    die "cannot determine the current hostname."
fi
if [[ "${host_name,,}" == *login* ]]; then
    die "Claude cannot be launched on a login node: $host_name" \
        "Allocate a compute node before running Claude."
fi

# --- Environment scrubbing ----------------------------------------------------
# Unset exported variables whose names match the administrator's glob patterns
# (tokens, keys, passwords, ...) so the container never inherits them. Names
# are reported, values never. A pattern may not match a variable this script
# needs (HOME, USER, PATH, CLUSTER), so an overly broad pattern cannot break it.
# Reads: claude-env.conf. Sets: sensitive_env_patterns.
load_config_array "$env_config" sensitive_env_patterns "environment"
# shellcheck disable=SC2154  # filled by load_config_array
for pattern in "${sensitive_env_patterns[@]}"; do
    if [[ -z "$pattern" ]]; then
        die "empty environment-variable pattern in $env_config."
    fi
    for required_name in HOME USER PATH CLUSTER; do
        # shellcheck disable=SC2053  # the pattern is a glob on purpose
        if [[ "$required_name" == $pattern ]]; then
            die "environment pattern '$pattern' matches required variable $required_name."
        fi
    done
done

while IFS= read -r exported_name; do
    for pattern in "${sensitive_env_patterns[@]}"; do
        # shellcheck disable=SC2053  # the pattern is a glob on purpose
        if [[ "$exported_name" == $pattern ]]; then
            unset "$exported_name"
            warn "unset sensitive environment variable: $exported_name"
            break
        fi
    done
done < <(compgen -e)

# --- Claude state -------------------------------------------------------------
# Claude keeps its settings, sessions and installer data here; they must exist
# before they are bound. Their binds come from claude-bind.conf.
mkdir -p -- "${host_home}/.claude" "${host_home}/.local/share/claude"

# --- Admin binds --------------------------------------------------------------
# Mount the administrator-configured directories; missing ones are skipped. A
# symlinked entry is mounted at both its configured and its resolved path.
# Reads: claude-bind.conf. Sets: binds, bind_entries, configured_bind_paths,
# configured_bind_roots.
bind_entries=()
configured_bind_paths=()
configured_bind_roots=()
load_config_array "$bind_config" binds "bind"
# shellcheck disable=SC2154  # filled by load_config_array
for entry in "${binds[@]}"; do
    split_bind_mode "$entry" "" "$bind_config"
    require_bindable_path "$bind_path" "configured bind"

    # Missing paths, including dangling symlinks, are optional and skipped.
    [[ -e "$bind_path" ]] || continue
    resolved="$(resolve_directory "$bind_path" "configured bind path")" || exit 1

    add_bind_with_alias "$bind_path" "$resolved" "$bind_mode"
    configured_bind_paths+=("$bind_path")
    configured_bind_roots+=("$resolved")
done

# --- Container PATH -----------------------------------------------------------
# Prepend bound tool directories (Slurm, /apps, ...) to PATH in the container.
# Each entry must lie inside an admin bind, or it would not exist there.
# Missing entries are skipped and duplicates removed.
# Reads: claude-path.conf. Sets: path_entries, path_opts.
load_config_array "$path_config" path_entries "PATH"
container_path=()
declare -A seen_path_entries=()
# shellcheck disable=SC2154  # filled by load_config_array
for entry in "${path_entries[@]}"; do
    require_bindable_path "$entry" "configured PATH entry"
    [[ -e "$entry" ]] || continue
    resolved="$(resolve_directory "$entry" "configured PATH entry")" || exit 1
    if ! is_within_configured_bind "$entry" "$resolved"; then
        die "configured PATH entry is not covered by a configured bind: $entry"
    fi

    # Keep the logical path so symlinked prefixes appear in PATH as configured.
    entry="${entry%/}"
    if [[ -z "${seen_path_entries[$entry]+x}" ]]; then
        container_path+=("$entry")
        seen_path_entries["$entry"]=1
    fi
done

path_opts=()
if (( ${#container_path[@]} > 0 )); then
    path_opts+=(--env "PREPEND_PATH=$(IFS=:; printf '%s' "${container_path[*]}")")
fi

# --- Exclusions ---------------------------------------------------------------
# Directories that may never be the working directory, or be bound with
# --bind. An exclusion does not hide anything that an admin bind exposes.
# Missing entries are skipped with a warning.
# Reads: claude-exclude.conf. Sets: excluded_workdirs, excluded_work_roots.
load_config_array "$exclude_config" excluded_workdirs "exclusion"
excluded_work_roots=()
# shellcheck disable=SC2154  # filled by load_config_array
for entry in "${excluded_workdirs[@]}"; do
    require_bindable_path "$entry" "excluded path"
    if [[ ! -e "$entry" ]]; then
        warn "skipping missing excluded path: $entry"
        continue
    fi
    resolved="$(resolve_directory "$entry" "excluded path")" || exit 1
    excluded_work_roots+=("$resolved")
done

# --- Working-directory policy -------------------------------------------------
# Claude works in the directory it was launched from, resolved to its real
# path. It must not be inside an admin bind or exclusion; it must be a
# non-hidden subdirectory (not the root itself) of the user's home or of one of
# their group's project, scratch or PI spaces (<base>/<group>/<user>); and it
# must be readable, writable and searchable.
# Sets: storage_bases, work_dir, allowed_roots.
set_storage_bases "$cluster_name"
work_dir="$(resolve_directory . "current working directory")" || exit 1

for root in "${configured_bind_roots[@]}" "${excluded_work_roots[@]}"; do
    if path_is_within "$work_dir" "$root"; then
        die "Claude cannot be launched from an administratively restricted directory:" \
            "  $root" "Resolved current directory: $work_dir"
    fi
done

collect_allowed_roots
work_dir_allowed=false
for root in "${allowed_roots[@]}"; do
    if is_non_hidden_subdirectory "$work_dir" "$root"; then
        work_dir_allowed=true
        break
    fi
done
if [[ "$work_dir_allowed" != true ]]; then
    die "Claude must be launched from a non-hidden subdirectory of:" \
        "$(printf '  %s\n' "${allowed_roots[@]}")" "Resolved current directory: $work_dir"
fi

if [[ ! -r "$work_dir" || ! -w "$work_dir" || ! -x "$work_dir" ]]; then
    die "the working directory must be readable, writable, and searchable: $work_dir"
fi

# --- Launch prerequisites -----------------------------------------------------
if ! command -v apptainer >/dev/null 2>&1; then
    die "apptainer is not available. Load the Apptainer module first."
fi
if [[ ! -r "$image" ]]; then
    die "Claude container not found or not readable: $image"
fi

# The working directory is always mounted read-write at its real path.
add_bind "$work_dir" "$work_dir" ""

# An existing ~/.claude.json (legacy Claude state) is persisted; it is never
# created here.
if [[ -f "${host_home}/.claude.json" ]]; then
    add_bind "${host_home}/.claude.json" "${host_home}/.claude.json" ""
fi

# --- User binds ---------------------------------------------------------------
# Mount the directories the user named with --bind (read-only unless ":rw")
# and tell Claude about them with --add-dir. System, hidden, excluded and home
# paths are refused; paths that are already mounted (the work dir, admin binds)
# are skipped with a note. A symlinked directory is mounted under both names.
# Reads: user_bind_specs, work_dir. Adds to: bind_entries. Sets: add_dir_opts.
add_user_binds

# --- GPU support --------------------------------------------------------------
# Enable NVIDIA integration only when the node has the NVIDIA control device
# and at least one GPU device; CPU-only nodes omit --nv.
gpu_opts=()
if [[ -c /dev/nvidiactl ]] && compgen -G '/dev/nvidia[0-9]*' >/dev/null; then
    gpu_opts+=(--nv)
fi

# --- Bind ordering ------------------------------------------------------------
# Emit the binds parent-first, so a nested bind is mounted on top of its
# parent. Reads: bind_entries. Sets: bind_opts.
build_bind_opts

# --- Launch -------------------------------------------------------------------
# --contain hides the host's home and /tmp; only the binds below are visible.
# Argument groups, in order:
#   gpu_opts     GPU support (--nv or nothing)
#   path_opts    Container PATH (--env PREPEND_PATH=... or nothing)
#   bind_opts    admin binds, the work dir, Claude state and user binds,
#                parent-first
#   image        the image's runscript runs /usr/bin/claude ...
#   add_dir_opts ... with --add-dir=DIR for each user bind (the "=" form, since
#                --add-dir takes several values and would swallow the prompt),
#   claude_args  ... and every argument meant for Claude
exec apptainer run \
    --contain \
    "${gpu_opts[@]}" \
    "${path_opts[@]}" \
    "${bind_opts[@]}" \
    --pwd "$work_dir" \
    "$image" \
    "${add_dir_opts[@]}" \
    "${claude_args[@]}"
