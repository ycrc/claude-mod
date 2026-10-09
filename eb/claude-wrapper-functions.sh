# shellcheck shell=bash
# Functions used by claude-wrapper.sh, the claude-mod launcher.
#
# Only helpers used in more than one place, and the longer steps that would
# clutter the launch sequence (user binds, allowed roots, bind ordering, help
# text, in-house mode), live here; everything else is inline in claude-wrapper.sh. Sourcing
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

# load_config_vars FILE LABEL VAR...: source an administrator-controlled config
# file and require that it set each VAR to a non-empty value (for an array, a
# non-empty first element). Each VAR is unset first, so an inherited
# environment variable cannot fill a gap in the file.
load_config_vars() {
    local config_file="$1" label="$2" var_name
    shift 2
    if [[ ! -r "$config_file" ]]; then
        die "$label configuration not found or not readable: $config_file"
    fi
    for var_name in "$@"; do
        unset "$var_name"
    done
    # shellcheck source=/dev/null
    source "$config_file"
    for var_name in "$@"; do
        if [[ -z "${!var_name:-}" ]]; then
            die "$config_file must set $var_name."
        fi
    done
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
  --in-house-model     Use YCRC's in-house model, hosted at Yale, instead of
                       Anthropic's: this session's prompts and code are not
                       sent to Anthropic. Bouchet only. Sessions, settings and
                       memory are shared with normal Claude, so continuing an
                       in-house session without this option sends it to
                       Anthropic. Token counts (not prompts) are recorded per
                       netid. Auto mode works; the in-house model judges which
                       commands are safe. See "In-house mode" in the docs.
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

# --- In-house mode ------------------------------------------------------------

# prepare_in_house_mode: load and check claude-in-house.conf, apply the
# in-house rules for --model, --fallback-model and --settings, require a
# supported cluster and curl, remove inherited provider settings, and export
# the user-scoped credential.
# Reads: in_house_config, cluster_name, requested_models, fallback_model_given,
# settings_given. Sets: in_house_* (from the conf), ANTHROPIC_AUTH_TOKEN.
prepare_in_house_mode() {
    local url_pattern='^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'
    local model_pattern='^[A-Za-z0-9._:/@-]+$' label_pattern='^[A-Za-z0-9_-]+$'
    local name base value cluster cluster_allowed=false account

    load_config_vars "$in_house_config" "in-house" in_house_clusters in_house_base_url \
        in_house_model in_house_agent_label in_house_max_context in_house_max_output in_house_effort
    if [[ "$(declare -p in_house_clusters)" != "declare -a "* ]]; then
        die "$in_house_config: in_house_clusters must be an array, e.g. in_house_clusters=(bouchet)."
    fi
    in_house_base_url="${in_house_base_url%/}"
    if [[ ! "$in_house_base_url" =~ $url_pattern ]]; then
        die "$in_house_config: in_house_base_url must look like http(s)://host[:port][/path]: $in_house_base_url"
    fi
    if [[ ! "$in_house_model" =~ $model_pattern ]]; then
        die "$in_house_config: in_house_model may only contain letters, digits and ._:/@-: $in_house_model"
    fi
    if [[ ! "$in_house_agent_label" =~ $label_pattern ]]; then
        die "$in_house_config: in_house_agent_label may only contain letters, digits, _ and -: $in_house_agent_label"
    fi
    for name in in_house_max_context in_house_max_output; do
        if [[ ! "${!name}" =~ ^[1-9][0-9]*$ ]]; then
            die "$in_house_config: $name must be a positive integer: ${!name}"
        fi
    done
    case "$in_house_effort" in
        xhigh|medium|low) ;;
        *) die "$in_house_config: in_house_effort must be xhigh, medium or low; the in-house server rejects other levels: $in_house_effort" ;;
    esac

    # One model is served, so Claude's model choices and fallbacks don't apply,
    # and the wrapper's own --settings must not be replaced.
    for value in "${requested_models[@]}"; do
        if [[ "$value" != "$in_house_model" && "$value" != default ]]; then
            die "--model $value is not available in in-house mode, which offers only $in_house_model." \
                "To use a Claude model, start claude without --in-house-model."
        fi
    done
    if [[ "$fallback_model_given" == true ]]; then
        die "--fallback-model cannot be used with --in-house-model: there is only one in-house model."
    fi
    if [[ "$settings_given" == true ]]; then
        die "in-house mode sets --settings itself; put your settings in ~/.claude/settings.json."
    fi

    for cluster in "${in_house_clusters[@]}"; do
        [[ "${cluster,,}" == "${cluster_name,,}" ]] && cluster_allowed=true
    done
    if [[ "$cluster_allowed" != true ]]; then
        die "in-house mode is only available on: ${in_house_clusters[*]}"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        die "in-house mode needs curl to check the in-house model service, but curl was not found."
    fi

    # Inherited provider settings could send in-house prompts elsewhere.
    while IFS= read -r name; do
        base="${name#APPTAINERENV_}"
        base="${base#SINGULARITYENV_}"
        case "$base" in
            ANTHROPIC_*|CLAUDE_CODE_USE_*|CLAUDE_CODE_EXTRA_BODY)
                unset "$name"
                warn "in-house mode ignores $name from your environment."
                ;;
        esac
    done < <(compgen -e)

    # The gateway accounts usage to "<netid>.<label>"; it is not a password.
    if ! account="$(id -un)"; then
        die "cannot determine your account name."
    fi
    export ANTHROPIC_AUTH_TOKEN="${account}.${in_house_agent_label}"
}

# add_in_house_claude_opts: the environment, Claude options and banner for an
# in-house session. Every variable goes both to Apptainer (--env) and into the
# --settings env block, which outranks project and user settings. Values never
# contain "=", which Apptainer's --env parsing relies on.
# Reads: in_house_*. Sets: env_opts, mode_claude_opts.
add_in_house_claude_opts() {
    local label="${in_house_model} (YCRC in-house)" entry value env_json="" settings
    local -a session_env=(
        "ANTHROPIC_BASE_URL=${in_house_base_url}"
        "ANTHROPIC_MODEL=${in_house_model}"
        # "Default" in /model resolves to the Opus tier. The other tiers stay
        # unmapped, so availableModels refuses them instead of silently giving Qwen.
        "ANTHROPIC_DEFAULT_OPUS_MODEL=${in_house_model}"
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME=${label}"
        "CLAUDE_CODE_SUBAGENT_MODEL=${in_house_model}"
        "CLAUDE_CODE_DISABLE_1M_CONTEXT=1"
        # Any effort level switches the model's reasoning on; this turns it off.
        'CLAUDE_CODE_EXTRA_BODY={"chat_template_kwargs":{"enable_thinking":false}}'
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS=${in_house_max_context}"
        "CLAUDE_CODE_MAX_OUTPUT_TOKENS=${in_house_max_output}"
        "CLAUDE_CODE_EFFORT_LEVEL=${in_house_effort}"
        # The auto-mode classifier then runs in Claude Code, on the in-house model.
        "CLAUDE_CODE_AUTO_MODE_SERVER=0"
        "CLAUDE_CODE_USE_BEDROCK=0"
        "CLAUDE_CODE_USE_VERTEX=0"
        "CLAUDE_CODE_USE_FOUNDRY=0"
        "DISABLE_BUG_COMMAND=1"
    )

    env_opts=()
    for entry in "${session_env[@]}"; do
        env_opts+=(--env "$entry")
        value="${entry#*=}"
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        env_json+="${env_json:+,}\"${entry%%=*}\":\"${value}\""
    done
    printf -v settings '{"env":{%s},"availableModels":["%s"],"modelPicker":{"options":[{"model":"%s","label":"%s"}],"replaceBuiltInOptions":true},"permissions":{"deny":["WebSearch"]}}' \
        "$env_json" "$in_house_model" "$in_house_model" "$label"

    mode_claude_opts=(
        --settings "$settings"
        --append-system-prompt "This session runs on ${in_house_model}, YCRC's in-house model hosted at Yale, not on an Anthropic model, and web search is unavailable. Sessions are shared with the user's normal Claude Code, so continuing this session without --in-house-model would send it to Anthropic."
    )

    printf '%s\n' \
        "In-house mode: ${in_house_model} hosted by YCRC. This session's prompts and code are not sent to Anthropic." \
        "Sessions, settings and memory are shared with your normal Claude; continuing this session" \
        "without --in-house-model sends it to Anthropic. See claude --ycrc-help." >&2
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
