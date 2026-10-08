# shellcheck shell=bash
# Functions used by claude-wrapper.sh, the claude-mod launcher.
#
# Only helpers used in more than one place, and the longer steps that would
# clutter the launch sequence (user binds, allowed roots, bind ordering, help
# text), live here; everything else is inline in claude-wrapper.sh. Sourcing
# this file defines functions and one constant, and has no other effect.
# Functions share state through the global variables named in their comments;
# those that validate input stop the launch with die() on failure.
#
# SC2034/SC2154: globals are set here and read in claude-wrapper.sh, or the
# reverse, which shellcheck cannot see when checking this file on its own.
# shellcheck disable=SC2034,SC2154

# --- Messaging ----------------------------------------------------------------

# die MESSAGE [MORE_LINES...]: print an error to stderr and exit 1.
die() {
    printf 'Error: %s\n' "$1" >&2
    shift
    if (( $# > 0 )); then
        printf '%s\n' "$@" >&2
    fi
    exit 1
}

# warn MESSAGE: print a warning to stderr.
warn() {
    printf 'Warning: %s\n' "$1" >&2
}

# --- Path helpers -------------------------------------------------------------

# path_is_within PATH ROOT: true if PATH equals ROOT or lies below it.
path_is_within() {
    [[ "$1" == "$2" || "$1" == "$2/"* ]]
}

# require_bindable_path PATH LABEL: PATH must be absolute, not /, and free of
# ':' and ',' (Apptainer uses them as bind-spec separators).
require_bindable_path() {
    local path="$1" label="$2"
    if [[ "$path" != /* || "$path" == / ]]; then
        die "$label must be an absolute directory other than /: $path"
    fi
    if [[ "$path" == *:* ]]; then
        die "$label cannot contain ':' or ',': $path"
    fi
    if [[ "$path" == *,* ]]; then
        die "$label cannot contain ',': $path"
    fi
}

# resolve_directory PATH LABEL: print the resolved PATH; die unless it is a directory.
# Use as: x="$(resolve_directory ...)" || exit 1
resolve_directory() {
    local path="$1" label="$2" resolved
    if ! resolved="$(realpath -e -- "$path")"; then
        die "cannot resolve $label: $path"
    fi
    if [[ ! -d "$resolved" ]]; then
        die "$label is not a directory: $path"
    fi
    printf '%s\n' "$resolved"
}

# is_non_hidden_subdirectory PATH ROOT: true if PATH is strictly below ROOT and
# no component below ROOT starts with '.'.
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

# --- Configuration ------------------------------------------------------------

# load_config_array FILE ARRAY LABEL: source an administrator-controlled config
# file and require that it define the indexed array ARRAY. The array is reset
# first so an inherited value cannot survive. Config files are sourced inside
# this function, so they must use plain assignments (no declare/local).
load_config_array() {
    local config_file="$1" array_name="$2" label="$3"
    if [[ ! -r "$config_file" ]]; then
        die "$label configuration not found or not readable: $config_file"
    fi

    local -n config_array_ref="$array_name"
    config_array_ref=()
    # shellcheck source=/dev/null
    source "$config_file"

    if [[ "$(declare -p "$array_name" 2>/dev/null)" != "declare -a "* ]]; then
        die "$config_file must define an indexed array named $array_name."
    fi
}

# --- Binds --------------------------------------------------------------------

# is_within_configured_bind LOGICAL RESOLVED: true if the directory is equal to
# or inside an admin bind, by its configured or its resolved path.
# Reads: configured_bind_paths, configured_bind_roots.
is_within_configured_bind() {
    local logical="$1" resolved="$2" index
    for index in "${!configured_bind_paths[@]}"; do
        if path_is_within "$logical" "${configured_bind_paths[index]}" ||
           path_is_within "$resolved" "${configured_bind_roots[index]}"; then
            return 0
        fi
    done
    return 1
}

# add_bind HOST DEST MODE: queue a bind of HOST at DEST (MODE: ro, rw or empty
# for Apptainer's default). Entries are "depth<TAB>spec" so build_bind_opts can
# order them. Appends to: bind_entries.
add_bind() {
    local host="$1" dest="$2" mode="$3" spec slashes
    spec="${host}:${dest}"
    if [[ -n "$mode" ]]; then
        spec+=":${mode}"
    fi
    slashes="${dest//[^\/]/}"
    bind_entries+=("${#slashes}"$'\t'"${spec}")
}

# add_bind_with_alias LOGICAL RESOLVED MODE: bind RESOLVED at LOGICAL and, when
# they differ (a symlink), also at RESOLVED, so code using either path works.
add_bind_with_alias() {
    local logical="$1" resolved="$2" mode="$3"
    add_bind "$resolved" "$logical" "$mode"
    if [[ "$resolved" != "$logical" ]]; then
        add_bind "$resolved" "$resolved" "$mode"
    fi
}

# split_bind_mode ENTRY DEFAULT_MODE LABEL: split "PATH[:ro|:rw]".
# Sets: bind_path, bind_mode.
split_bind_mode() {
    local entry="$1" default_mode="$2" label="$3"
    case "$entry" in
        *:ro) bind_path="${entry%:ro}"; bind_mode=ro ;;
        *:rw) bind_path="${entry%:rw}"; bind_mode=rw ;;
        *:*) die "invalid bind mode in $label: $entry" ;;
        *) bind_path="$entry"; bind_mode="$default_mode" ;;
    esac
}

# --- Storage roots ------------------------------------------------------------

# Groups that never hold <base>/<group>/<user> storage. The user's personal
# group (named after the user) is skipped as well. Skipping them avoids
# pointless lookups on network filesystems; Bouchet users are often in many
# groups. (docs/spec.md spells this "guassian"; the group is "gaussian".)
ignored_storage_groups=(gaussian)

# set_storage_bases CLUSTER: project, scratch and PI storage bases for the
# cluster. Sets: storage_bases.
set_storage_bases() {
    case "${1,,}" in
        bouchet)
            storage_bases=(/nfs/roberts/project /nfs/roberts/scratch /nfs/roberts/pi)
            ;;
        grace|mccleary)
            storage_bases=(/gpfs/gibbs/project /vast/palmer/scratch
                           /gpfs/gibbs/pi /vast/palmer/pi)
            ;;
        *)
            die "unsupported cluster: $1" "Supported clusters: bouchet, grace, and mccleary."
            ;;
    esac
}

# collect_allowed_roots: the user's home plus every existing
# <storage base>/<group>/<user> directory, skipping the personal group and
# ignored_storage_groups. Reads: host_home, user_name, storage_bases.
# Sets: allowed_roots.
collect_allowed_roots() {
    local home_root group_name storage_base storage_path storage_root ignored skip
    if ! home_root="$(realpath -e -- "$host_home")"; then
        die "cannot resolve the home directory: $host_home"
    fi
    allowed_roots=("$home_root")

    # Users may belong to several groups, each with its own spaces.
    for group_name in $(groups 2>/dev/null || true); do
        skip=false
        [[ "$group_name" == "$user_name" ]] && skip=true
        for ignored in "${ignored_storage_groups[@]}"; do
            [[ "$group_name" == "$ignored" ]] && skip=true
        done
        [[ "$skip" == true ]] && continue

        for storage_base in "${storage_bases[@]}"; do
            storage_path="${storage_base}/${group_name}/${user_name}"
            [[ -d "$storage_path" ]] || continue
            if ! storage_root="$(realpath -e -- "$storage_path")"; then
                die "cannot resolve storage directory: $storage_path"
            fi
            allowed_roots+=("$storage_root")
        done
    done
}

# --- Module options and help --------------------------------------------------

# add_user_bind_specs LIST: split a comma-separated --bind value into specs of
# the form PATH, PATH:ro or PATH:rw. Appends to: user_bind_specs.
add_user_bind_specs() {
    local list="$1" spec dir
    local -a specs
    if [[ -z "$list" ]]; then
        die "--bind requires a directory, e.g. --bind=DIR or --bind=DIR:rw"
    fi
    IFS=',' read -r -a specs <<< "$list"
    for spec in "${specs[@]}"; do
        if [[ -z "$spec" ]]; then
            die "--bind has an empty entry: $list"
        fi
        # Only DIR, DIR:ro and DIR:rw. A destination (DIR:/elsewhere) could put
        # a bind over the container's own files, such as /etc/claude-code.
        case "$spec" in
            *:ro|*:rw) dir="${spec%:*}" ;;
            *) dir="$spec" ;;
        esac
        if [[ "$dir" == *:* ]]; then
            die "--bind $spec: custom container destinations are not supported;" \
                "use DIR, DIR:ro or DIR:rw."
        fi
        user_bind_specs+=("$spec")
    done
}

# print_ycrc_help: module usage on stdout. Runs before every launch check, so
# it must not fail: an unset or unsupported CLUSTER gives generic text.
print_ycrc_help() {
    local base roots=""
    case "${CLUSTER:-}" in
        [Bb][Oo][Uu][Cc][Hh][Ee][Tt]|[Gg][Rr][Aa][Cc][Ee]|[Mm][Cc][Cc][Ll][Ee][Aa][Rr][Yy])
            set_storage_bases "$CLUSTER"
            roots="  On ${CLUSTER,,}, your group spaces are:"$'\n'
            for base in "${storage_bases[@]}"; do
                roots+="    ${base}/<group>/<netid>"$'\n'
            done
            ;;
    esac

    cat <<EOF
claude (YCRC claude-mod module): Claude Code with safer defaults.

Claude runs in an Apptainer container that sees the directory you start it
from, plus YCRC software, Slurm, and your Conda and R libraries. Credential-like
environment variables (tokens, keys, passwords) are removed before it starts.

Where you can start Claude:
  A non-hidden subfolder of your home, project, scratch, or PI space,
  on a compute node (not a login node).
${roots}
Module options (all other options are passed to Claude; see claude --help):
  --bind=DIR[:ro|:rw]  Also give Claude access to DIR, read-only unless :rw.
                       Repeat it, or list several: --bind=DIR1,DIR2:rw.
                       Also -B DIR. Hidden, system, excluded and home
                       directories are refused.
                       Example: claude --bind=/path/to/lab/shared-data
  --ycrc-help          Show this help.

Documentation: https://docs.ycrc.yale.edu/ai/commercial-coding-agents/#using-the-claude-module
EOF
}

# --- User binds ---------------------------------------------------------------

# add_user_binds: check and queue the --bind directories. Each one, in order:
#   1. must be a readable directory;
#   2. is skipped with a note if already visible (in the work dir or an admin bind);
#   3. is refused if it is or lies in a container system directory, is hidden,
#      contains ':' or ',', is or contains an exclusion, or is or contains home;
#   4. is bound (read-only unless :rw) and passed to Claude with --add-dir.
# Reads: user_bind_specs, work_dir, host_home, configured_bind_*,
# excluded_work_roots. Appends to: bind_entries. Sets: add_dir_opts.
add_user_binds() {
    # Binding over these would replace the image's own files, including its
    # managed settings.
    local -a system_dirs=(/bin /boot /dev /etc /lib /lib64 /opt /proc /root /run /sbin /sys /usr /var)
    local spec path logical resolved home_root candidate system root

    add_dir_opts=()
    (( ${#user_bind_specs[@]} > 0 )) || return 0
    home_root="$(realpath -e -- "$host_home")" || die "cannot resolve the home directory: $host_home"

    for spec in "${user_bind_specs[@]}"; do
        split_bind_mode "$spec" ro "--bind"
        path="$bind_path"
        # A leading ~ arrives literally (the shell does not expand --bind=~/x).
        # shellcheck disable=SC2088
        case "$path" in
            "~") path="$host_home" ;;
            "~/"*) path="${host_home}/${path#"~/"}" ;;
        esac

        # 1. Must be a readable directory.
        resolved="$(resolve_directory "$path" "--bind directory")" || exit 1
        if [[ ! -r "$resolved" || ! -x "$resolved" ]]; then
            die "--bind: you cannot read this directory: $path"
        fi
        # The path as given (made absolute) is kept when it still leads to the
        # same directory, so a symlink works under both names.
        logical="$(realpath -s -m -- "$path")"
        if [[ "$(realpath -e -- "$logical" 2>/dev/null)" != "$resolved" ]]; then
            logical="$resolved"
        fi

        # 2. Already visible: skip with a note.
        if path_is_within "$resolved" "$work_dir" ||
           is_within_configured_bind "$logical" "$resolved"; then
            printf 'Note: %s is already available inside the container; --bind skipped.\n' "$path" >&2
            continue
        fi

        # 3. Refused paths. Checked for both the given and the resolved path.
        for candidate in "$logical" "$resolved"; do
            if [[ "$candidate" == / ]]; then
                die "--bind refused: / is a container system directory: $path"
            fi
            for system in "${system_dirs[@]}"; do
                if path_is_within "$candidate" "$system"; then
                    die "--bind refused: $candidate is in the container system directory $system: $path"
                fi
            done
            if [[ "$candidate" == */.* ]]; then
                die "--bind refused: hidden directories cannot be bound: $candidate"
            fi
            if [[ "$candidate" == *[:,]* ]]; then
                die "--bind refused: Apptainer cannot bind a path containing ':' or ',': $candidate"
            fi
        done
        for root in "${excluded_work_roots[@]}"; do
            if path_is_within "$resolved" "$root" || path_is_within "$root" "$resolved"; then
                die "--bind refused: $path is or contains the excluded directory $root"
            fi
        done
        if path_is_within "$home_root" "$resolved"; then
            die "--bind refused: $path is or contains your home directory," \
                "which holds credentials and Claude's own state. Bind a subfolder instead."
        fi

        # 4. Bind it, and tell Claude about every container path.
        add_bind_with_alias "$logical" "$resolved" "$bind_mode"
        add_dir_opts+=("--add-dir=${logical}")
        if [[ "$resolved" != "$logical" ]]; then
            add_dir_opts+=("--add-dir=${resolved}")
        fi
        if [[ "$bind_mode" == rw ]]; then
            printf 'Binding read-write: %s\n' "$logical" >&2
        else
            printf 'Binding read-only: %s\n' "$logical" >&2
        fi
    done
}

# --- Bind ordering ------------------------------------------------------------

# build_bind_opts: emit --bind options ordered from the shallowest destination
# to the deepest (stable for equal depth), so a nested bind is mounted after,
# and therefore on top of, its parent. Reads: bind_entries. Sets: bind_opts.
build_bind_opts() {
    local entry
    bind_opts=()
    (( ${#bind_entries[@]} > 0 )) || return 0
    while IFS= read -r -d '' entry; do
        bind_opts+=(--bind "${entry#*$'\t'}")
    done < <(printf '%s\0' "${bind_entries[@]}" | sort -z -s -n -t $'\t' -k1,1)
}
