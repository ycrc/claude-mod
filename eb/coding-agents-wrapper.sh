#!/usr/bin/env bash
set -euo pipefail

launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bind_config="${launcher_dir}/coding-agents-bind.conf"
path_config="${launcher_dir}/coding-agents-path.conf"
exclude_config="${launcher_dir}/coding-agents-exclude.conf"
env_config="${launcher_dir}/coding-agents-env.conf"
provider_config="${launcher_dir}/coding-agents-provider.conf"
codex_config="${launcher_dir}/codex-config.toml"
pi_models_config="${launcher_dir}/pi-models.json"
site_agents_dir="${launcher_dir}/share/agents"
site_skills_dir="${site_agents_dir}/skills"
site_subagents_dir="${site_agents_dir}/subagents"
site_pi_subagents_dir="${site_agents_dir}/pi-subagents"

agent="$(basename -- "$0")"
case "$agent" in
    claude|codex|copilot|pi) ;;
    *)
        echo "Error: launcher must be invoked as claude, codex, copilot, or pi (got: $agent)." >&2
        exit 1
        ;;
esac
# Each harness module (claude-local, codex-local, ...) installs this launcher
# beside its own image, so the image is chosen by the name it was invoked as.
image="${launcher_dir}/coding-agents-${agent}.sif"

# --- BEGIN user bind arguments ---
# Take the launcher's own --bind options out of the arguments; everything else
# goes to the harness. --bind=SPEC, --bind SPEC and -B SPEC may be repeated,
# and SPEC may be a comma-separated list. Scanning stops at "--", which is
# passed on with everything after it. None of the four harnesses uses these
# option names. The directories are checked under "User binds" below.
user_bind_specs=()
forwarded_args=()
while (( $# > 0 )); do
    case "$1" in
        --)
            forwarded_args+=("$@")
            break
            ;;
        --bind=*|-B?*)
            if [[ "$1" == --bind=* ]]; then
                bind_arg="${1#--bind=}"
            else
                bind_arg="${1#-B}"
            fi
            ;;
        --bind|-B)
            if (( $# < 2 )); then
                echo "Error: $1 needs a directory, for example: $agent --bind /path/to/data" >&2
                exit 1
            fi
            bind_arg="$2"
            shift
            ;;
        *)
            forwarded_args+=("$1")
            shift
            continue
            ;;
    esac
    if [[ -z "$bind_arg" ]]; then
        echo "Error: --bind needs a directory, for example: $agent --bind /path/to/data" >&2
        exit 1
    fi
    IFS=',' read -r -a bind_arg_parts <<< "$bind_arg"
    for bind_arg_part in "${bind_arg_parts[@]}"; do
        if [[ -n "$bind_arg_part" ]]; then
            user_bind_specs+=("$bind_arg_part")
        fi
    done
    shift
done
set -- "${forwarded_args[@]}"
# --- END user bind arguments ---

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

# Preserve the location of an existing user ssh-agent before credential-like
# environment variables are scrubbed. The socket may later be forwarded into
# the container, but the original SSH_AUTH_SOCK is not inherited directly.
host_ssh_auth_sock="${SSH_AUTH_SOCK:-}"

# Coding agents must run on a node that belongs to the active Slurm allocation.
# Do not rely on hostname conventions to distinguish login and compute nodes.
if ! host_name="$(hostname -s)"; then
    echo "Error: cannot determine the current hostname." >&2
    exit 1
fi

if [[ -z "${SLURM_JOB_ID:-}" || -z "${SLURM_JOB_NODELIST:-}" ]]; then
    echo "Error: $agent must be launched from within a Slurm compute allocation." >&2
    echo "Start a session in the agent partition and run $agent there, for example:" >&2
    echo "  salloc -p agent --mem=8G -t 8:00:00" >&2
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
            # Always removed, but not worth a warning: the user's own
            # "<netid>.api" key from the ycrc-llm module (not a secret), and
            # Lmod's __LMOD_STACK_* records of values pushenv replaced (which
            # may hold a real key, so they are removed too).
            quiet=false
            if [[ "${!exported_env_name}" == "${user_name}.api" || "$exported_env_name" == __LMOD_STACK_* ]]; then
                quiet=true
            fi
            unset "$exported_env_name"
            [[ "$quiet" == true ]] ||
                printf 'Warning: unset sensitive environment variable: %s\n' "$exported_env_name" >&2
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

# Extended reasoning opt-in.
#
# Set YCRC_THINKING=1 before launching to run the session with the model's
# reasoning mode enabled, for example:
#
#     YCRC_THINKING=1 pi
#
# This selects a virtual model name that the YCRC inference gateway recognises:
# the gateway serves it with the real model and reasoning switched on. The
# model name is used because it is the one setting that reaches the gateway
# from every harness; the launcher cannot add headers to a harness's own HTTP
# requests.
#
# Reasoning produces noticeably more output and a slower first token, so it is
# off unless the user asks for it AND the administrator has configured a
# suffix. Clearing YCRC_AGENT_THINK_SUFFIX disables the feature entirely.
# Credential presented to the inference endpoint.
#
# With user-scoped auth enabled, the launcher sends "<netid>.<agent>" instead
# of the shared site credential. The gateway in front of vLLM splits that to
# attribute token usage to a netid, then substitutes the real upstream
# credential before forwarding. vLLM itself never sees this value.
#
# This REQUIRES the gateway to be deployed: vLLM rejects anything but its own
# API key, so enabling it while talking to vLLM directly would break every
# harness. It is therefore off unless coding-agents-provider.conf turns it on.
if [[ "${YCRC_AGENT_USER_SCOPED_AUTH:-0}" == "1" ]]; then
    agent_auth="${user_name}.${agent}"
else
    agent_auth="${YCRC_AGENT_AUTH}"
fi

# --- BEGIN model name ---
# Request the served model by its real name, so every harness shows it (for
# example Qwen3.8-Flash-Next) rather than the gateway alias. The name is
# looked up at each launch from the gateway's /v1/models, where the alias is
# listed with the same backing model ("root") as the real entry, so swapping
# the served model still needs no module change. If the lookup fails, the
# session uses the alias, which the gateway resolves itself.
#
# A session keeps the name it started with: after a model swap, it must be
# restarted. The managed subagents keep requesting the alias, which they never
# display.
base_model="$YCRC_AGENT_MODEL"
if models_json="$(curl -sS --connect-timeout 2 -m 4 \
        -H "Authorization: Bearer ${agent_auth}" \
        "${YCRC_COPILOT_BASE_URL%/}/models" 2>/dev/null)"; then
    served_model="$(python3 -I -c '
import json, re, sys
alias, suffix = sys.argv[1], sys.argv[2]
models = [m for m in json.load(sys.stdin).get("data", [])
          if isinstance(m, dict) and isinstance(m.get("id"), str)]
roots = {m.get("root") for m in models if m["id"] == alias}
for m in models:
    name = m["id"]
    if (name != alias and m.get("root") in roots
            and not (suffix and name.endswith(suffix))
            and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}", name)):
        print(name)
        break
' "$YCRC_AGENT_MODEL" "${YCRC_AGENT_THINK_SUFFIX:-}" <<< "$models_json" 2>/dev/null || true)"
    if [[ -n "$served_model" ]]; then
        base_model="$served_model"
    fi
fi
# --- END model name ---

agent_model="$base_model"
if [[ "${YCRC_THINKING:-0}" == "1" && -n "${YCRC_AGENT_THINK_SUFFIX:-}" ]]; then
    agent_model="${base_model}${YCRC_AGENT_THINK_SUFFIX}"
    printf 'Extended reasoning enabled for this session (model: %s).\n' "$agent_model" >&2
fi

# Persistent client state directories. They are deliberately separate from
# users' normal harness state so the YCRC-managed clients cannot modify an
# independently installed Claude/Codex/Copilot/Pi configuration.
claude_config_dir="${host_home}/.claude-ycrc"
claude_config_file="${host_home}/.claude-ycrc.json"
codex_home="${host_home}/.codex-ycrc"
pi_home="${host_home}/.pi-ycrc"
copilot_home="${host_home}/.copilot-ycrc"
copilot_cache_home="${host_home}/.cache/copilot-ycrc"

conda_state_dir="${host_home}/.conda"
r_library_dir="${host_home}/R"

mkdir -p -- \
    "$claude_config_dir" \
    "$codex_home" \
    "$pi_home" \
    "$copilot_home" \
    "$copilot_cache_home" \
    "$conda_state_dir" \
    "$r_library_dir"

# The module installation carries a host-visible, administrator-owned copy of
# the shared policy and skills. Because /apps is bound read-only into the
# container, these paths resolve both from a normal shell and from a harness.
[[ -r "${site_agents_dir}/AGENTS.md" ]] || { echo "Error: missing site policy: ${site_agents_dir}/AGENTS.md" >&2; exit 1; }
[[ -d "$site_skills_dir" ]] || { echo "Error: missing site skills: $site_skills_dir" >&2; exit 1; }

# --- BEGIN user configuration import ---
# Users' normal harness configuration (~/.claude, ~/.codex, ~/.pi/agent,
# ~/.copilot) is never bound into the container. So that users still get their
# own settings, the portable parts of the launched harness's configuration are
# copied into its YCRC state directory on every launch.
#
# Each YCRC state directory keeps a record (.ycrc-import-state) of the
# modification time and size of every original it has imported. An original is
# imported when it has never been imported or has changed since, so edits to
# the original are picked up on the next launch, while an unchanged original
# never overwrites edits made to the YCRC copy. Settings files are merged into
# the YCRC copy rather than replacing it, keeping state the harness saved
# there. Any other file that already exists in the YCRC directory when its
# original is first seen is kept. Nothing is ever deleted.
#
# Credentials, history, sessions, plugins, MCP server definitions and Codex's
# config.toml are never imported, and settings that could point a harness at
# another model or provider are dropped. Set YCRC_IMPORT_USER_CONFIG=0 to turn
# this off.
user_claude_dir="${host_home}/.claude"
user_codex_dir="${host_home}/.codex"
user_pi_dir="${host_home}/.pi/agent"
user_copilot_dir="${host_home}/.copilot"

import_user_config=true
[[ "${YCRC_IMPORT_USER_CONFIG:-1}" == "0" ]] && import_user_config=false

declare -A import_record=()
import_state=""
kept_paths=()

import_warn() {
    echo "Warning: could not import $1; continuing without it." >&2
}

load_import_state() {
    local stamp path

    import_state="$1/.ycrc-import-state"
    [[ -f "$import_state" ]] || return 0
    while IFS=$'\t' read -r stamp path; do
        if [[ -n "$path" ]]; then
            import_record["$path"]="$stamp"
        fi
    done < "$import_state"
}

save_import_state() {
    local path tmp

    if ! tmp="$(mktemp -- "${import_state}.XXXXXX")"; then
        import_warn "the import record $import_state"
        return 0
    fi
    for path in "${!import_record[@]}"; do
        printf '%s\t%s\n' "${import_record[$path]}" "$path"
    done > "$tmp"
    if ! mv -f -- "$tmp" "$import_state"; then
        rm -f -- "$tmp"
        import_warn "the import record $import_state"
    fi
}

# Modification time and size identify a version of an original.
import_stamp() {
    stat -L -c '%.9Y.%s' -- "$1" 2>/dev/null
}

import_file() {
    local source="$1" target="$2" stamp

    if [[ "$source" == *$'\t'* || "$source" == *$'\n'* || -L "$target" ]]; then
        return 0
    fi
    stamp="$(import_stamp "$source")" || { import_warn "$source"; return 0; }
    if [[ "${import_record[$source]:-}" == "$stamp" ]]; then
        return 0
    fi
    if [[ -z "${import_record[$source]:-}" && -e "$target" ]] && ! cmp -s -- "$source" "$target"; then
        import_record["$source"]="$stamp"
        kept_paths+=("$target")
        return 0
    fi
    if mkdir -p -- "$(dirname -- "$target")" && cp -Lp -- "$source" "$target" 2>/dev/null; then
        import_record["$source"]="$stamp"
    else
        import_warn "$source"
    fi
}

# Import a file, or every file below the entries of a directory. Existing links
# (administrator-managed skills and agents) are left alone, as are dot-entries
# and any entry names passed after the target. Links in the user's own tree are
# followed, since their targets are not mounted.
import_user_path() {
    local source="$1" target="$2"
    shift 2
    local entry name skip file

    if [[ -d "$source" ]]; then
        if [[ -L "$target" || ( -e "$target" && ! -d "$target" ) ]]; then
            return 0
        fi
        for entry in "$source"/*; do
            [[ -e "$entry" ]] || continue
            name="$(basename -- "$entry")"
            for skip in "$@"; do
                if [[ "$name" == "$skip" ]]; then
                    continue 2
                fi
            done
            if [[ -L "${target}/${name}" ]]; then
                continue
            fi
            if [[ -d "$entry" ]]; then
                while IFS= read -r -d '' file; do
                    import_file "$file" "${target}/${name}/${file#"$entry"/}"
                done < <(find -L "$entry" -type f -print0 2>/dev/null)
            else
                import_file "$entry" "${target}/${name}"
            fi
        done
    elif [[ -f "$source" ]]; then
        import_file "$source" "$target"
    fi
}

# Agents are single files, and a user's own agent of the same name wins over
# the managed one (see link_site_subagents_non_destructive below).
import_user_agents() {
    local source="$1" target="$2" entry

    if [[ -d "$source" && -d "$target" ]]; then
        for entry in "$source"/*.md; do
            if [[ -f "$entry" && -L "${target}/$(basename -- "$entry")" ]]; then
                rm -f -- "${target}/$(basename -- "$entry")"
            fi
        done
    fi
    import_user_path "$source" "$target"
}

# Merge a JSON settings file into the YCRC copy, with provider, model,
# credential and plugin settings removed and paths into the user's
# configuration directory pointed at the YCRC copy. The user's values win;
# anything else already in the YCRC copy is kept.
import_user_settings() {
    local harness="$1" source="$2" target="$3" user_dir="$4" ycrc_dir="$5" stamp

    if [[ ! -f "$source" || -L "$target" ]]; then
        return 0
    fi
    stamp="$(import_stamp "$source")" || { import_warn "$source"; return 0; }
    if [[ "${import_record[$source]:-}" == "$stamp" ]]; then
        return 0
    fi
    if python3 -I - "$harness" "$source" "$target" "$user_dir" "$ycrc_dir" "$host_home" <<'PY'
import json, os, re, sys, tempfile

harness, source, target, user_dir, ycrc_dir, home = sys.argv[1:]
with open(source) as f:
    settings = json.load(f)
existing = {}
if os.path.exists(target):
    with open(target) as f:
        existing = json.load(f)
if not isinstance(settings, dict) or not isinstance(existing, dict):
    sys.exit(1)

dropped = {
    "claude": {"apiKeyHelper", "awsAuthRefresh", "awsCredentialExport",
               "gcpAuthRefresh", "otelHeadersHelper", "forceLoginMethod",
               "forceLoginOrgUUID", "model", "availableModels", "enabledPlugins",
               "extraKnownMarketplaces", "sandbox"},
    "pi": {"defaultProvider", "defaultModel", "enabledModels", "packages"},
}[harness]
for key in dropped:
    settings.pop(key, None)

# Claude applies settings "env" to its own process, so it could otherwise
# redirect the client to an external provider or replace the YCRC limits.
unsafe_env = re.compile(
    r"^(ANTHROPIC_|CLAUDE_CODE_|CLAUDE_CONFIG_DIR$|AWS_|GOOGLE_|VERTEX_|CLOUD_ML_"
    r"|AZURE_|OPENAI_)|KEY|TOKEN|SECRET|PASSWORD|BASE_URL|PROXY", re.I)
if isinstance(settings.get("env"), dict):
    settings["env"] = {k: v for k, v in settings["env"].items() if not unsafe_env.search(k)}

# Hook and status-line commands often name scripts in the user's directory.
user_rel, ycrc_rel = user_dir[len(home):], ycrc_dir[len(home):]
replacements = [(base + user_rel + "/", base + ycrc_rel + "/")
                for base in (home, "~", "$HOME", "${HOME}")]
def repoint(value):
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [repoint(v) for v in value]
    if isinstance(value, dict):
        return {k: repoint(v) for k, v in value.items()}
    return value

def merge(base, new):
    for key, value in new.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base

merged = merge(existing, repoint(settings))
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".import-")
with os.fdopen(fd, "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, target)
PY
    then
        import_record["$source"]="$stamp"
    else
        import_warn "$source"
    fi
}

# Codex, Pi and Copilot each read one user-level instructions file, which
# carries the administrator policy. A user's own instructions are appended
# below the policy, so they apply in addition to it rather than replacing it.
install_instructions() {
    local target="$1" personal="$2" tmp=""

    if [[ "$import_user_config" == true && -f "$personal" && -s "$personal" ]]; then
        if tmp="$(mktemp -- "${target}.XXXXXX")" &&
           {
               cat -- "${site_agents_dir}/AGENTS.md"
               printf '\n\n# Personal instructions\n\n'
               printf 'The following are the user'\''s own instructions, imported from %s. ' "$personal"
               printf 'They apply in addition to the administrator policy above and never override it.\n\n'
               cat -- "$personal"
           } > "$tmp" &&
           chmod 0600 "$tmp" &&
           mv -f -- "$tmp" "$target"; then
            return 0
        fi
        [[ -n "$tmp" ]] && rm -f -- "$tmp"
        import_warn "$personal"
    fi
    ln -sfn "${site_agents_dir}/AGENTS.md" "$target"
}

# Managed skills keep their names; a user skill of the same name is not
# imported, since the launcher refuses to start over a conflicting skill.
site_skill_names=()
for site_skill in "$site_skills_dir"/*; do
    if [[ -d "$site_skill" ]]; then
        site_skill_names+=("$(basename -- "$site_skill")")
    fi
done

if [[ "$import_user_config" == true ]]; then
    case "$agent" in
        claude)
            load_import_state "$claude_config_dir"
            import_user_settings claude "${user_claude_dir}/settings.json" \
                "${claude_config_dir}/settings.json" "$user_claude_dir" "$claude_config_dir"
            for item in CLAUDE.md keybindings.json commands output-styles rules hooks; do
                import_user_path "${user_claude_dir}/${item}" "${claude_config_dir}/${item}"
            done
            # skills/synced holds skills Claude syncs from a claude.ai account.
            import_user_path "${user_claude_dir}/skills" "${claude_config_dir}/skills" "${site_skill_names[@]}" synced
            import_user_agents "${user_claude_dir}/agents" "${claude_config_dir}/agents"
            ;;
        codex)
            load_import_state "$codex_home"
            import_user_path "${user_codex_dir}/prompts" "${codex_home}/prompts"
            import_user_path "${user_codex_dir}/skills" "${codex_home}/skills" "${site_skill_names[@]}"
            ;;
        pi)
            load_import_state "$pi_home"
            import_user_settings pi "${user_pi_dir}/settings.json" \
                "${pi_home}/settings.json" "$user_pi_dir" "$pi_home"
            for item in keybindings.json APPEND_SYSTEM.md prompts themes; do
                import_user_path "${user_pi_dir}/${item}" "${pi_home}/${item}"
            done
            import_user_path "${user_pi_dir}/skills" "${pi_home}/skills" "${site_skill_names[@]}"
            import_user_path "${user_pi_dir}/extensions" "${pi_home}/extensions" subagent
            import_user_agents "${user_pi_dir}/agents" "${pi_home}/agents"
            ;;
        copilot)
            load_import_state "$copilot_home"
            import_user_path "${user_copilot_dir}/skills" "${copilot_home}/skills" "${site_skill_names[@]}"
            import_user_agents "${user_copilot_dir}/agents" "${copilot_home}/agents"
            ;;
    esac
    save_import_state
    if (( ${#kept_paths[@]} > 0 )); then
        echo "Note: kept ${#kept_paths[@]} existing file(s) in $(dirname -- "$import_state") that differ from your own $agent configuration (for example ${kept_paths[0]}). Later edits to your originals will replace them." >&2
    fi
fi

install_instructions "${codex_home}/AGENTS.md" "${user_codex_dir}/AGENTS.md"
install_instructions "${pi_home}/AGENTS.md" "${user_pi_dir}/AGENTS.md"
install_instructions "${copilot_home}/copilot-instructions.md" "${user_copilot_dir}/copilot-instructions.md"
# --- END user configuration import ---

# Claude and Pi get real, user-writable skill directories. The YCRC-managed
# skills are linked into those directories individually, so users can inspect
# the managed skills from the host and add their own skills alongside them.
link_site_skills_non_destructive() {
    local target_root="$1"
    local skill_source skill_name target_skill

    if [[ -L "$target_root" ]]; then
        # Older releases made the entire skills directory a symlink to
        # /etc/agents/skills. Replace only that legacy link; never remove a
        # real user-owned directory.
        if [[ "$(readlink -- "$target_root" 2>/dev/null || true)" == "/etc/agents/skills" ]]; then
            rm -- "$target_root"
        else
            echo "Error: unexpected skills symlink: $target_root -> $(readlink -- "$target_root")" >&2
            exit 1
        fi
    fi

    if [[ -e "$target_root" && ! -d "$target_root" ]]; then
        echo "Error: skill path exists but is not a directory: $target_root" >&2
        exit 1
    fi
    mkdir -p -- "$target_root"

    for skill_source in "$site_skills_dir"/*; do
        [[ -d "$skill_source" ]] || continue
        skill_name="$(basename -- "$skill_source")"
        target_skill="${target_root}/${skill_name}"
        if [[ -L "$target_skill" || ! -e "$target_skill" ]]; then
            ln -sfn "$skill_source" "$target_skill"
        elif [[ -d "$target_skill" ]]; then
            echo "Error: existing user skill conflicts with administrator skill: $target_skill" >&2
            exit 1
        else
            echo "Error: existing path conflicts with administrator skill: $target_skill" >&2
            exit 1
        fi
    done
}

link_site_skills_non_destructive "${claude_config_dir}/skills"
link_site_skills_non_destructive "${pi_home}/skills"

# YCRC-managed Claude subagents. These let a session delegate work to a
# different model than the one it is running: a fast session can hand a hard
# sub-problem to the reasoning model, or a reasoning session can hand routine
# lookups to the fast one. Claude is the only harness that honours a per-agent
# model, so these are linked for Claude alone.
#
# Unlike skills, these are individual files and a user may legitimately want
# their own agent of the same name. A conflicting real file is therefore left
# untouched and the user's definition wins, rather than being treated as an
# error that would refuse to launch the agent.
link_site_subagents_non_destructive() {
    local target_root="$1"
    local agent_source agent_name target_agent

    [[ -d "$site_subagents_dir" ]] || return 0

    if [[ -e "$target_root" && ! -d "$target_root" ]]; then
        echo "Warning: agent path is not a directory, skipping managed agents: $target_root" >&2
        return 0
    fi
    mkdir -p -- "$target_root"

    for agent_source in "$site_subagents_dir"/*.md; do
        [[ -f "$agent_source" ]] || continue
        agent_name="$(basename -- "$agent_source")"
        target_agent="${target_root}/${agent_name}"
        if [[ -L "$target_agent" || ! -e "$target_agent" ]]; then
            ln -sfn "$agent_source" "$target_agent"
        fi
    done
}

link_site_subagents_non_destructive "${claude_config_dir}/agents"

# Pi delegated reasoning. Pi ships an official subagent extension that runs each
# delegated task in a separate Pi process -- an isolated context -- and honours a
# per-agent model. Linking it in gives Pi the same capability Claude has: a fast
# session can hand a hard sub-problem to the reasoning model, or a reasoning
# session can hand routine lookups to the fast one.
#
# The extension itself is NOT vendored. These are links to the copy inside the
# container image, so it always matches the packaged Pi version and YCRC
# maintains only the two agent definitions. The links deliberately point at an
# in-container path: they do not resolve on the host, only where Pi reads them.
link_pi_subagent_extension() {
    local ext_target="${pi_home}/extensions/subagent"
    local agents_target="${pi_home}/agents"
    local agent_source agent_name target_agent

    [[ -n "${YCRC_PI_SUBAGENT_EXT_DIR:-}" ]] || return 0
    [[ -d "$site_pi_subagents_dir" ]] || return 0

    mkdir -p -- "$ext_target" "$agents_target" || return 0
    ln -sfn "${YCRC_PI_SUBAGENT_EXT_DIR}/index.ts"  "${ext_target}/index.ts"
    ln -sfn "${YCRC_PI_SUBAGENT_EXT_DIR}/agents.ts" "${ext_target}/agents.ts"

    # As with the Claude agents, a real user file of the same name is left alone
    # so a user's own definition wins rather than the launcher refusing to start.
    for agent_source in "$site_pi_subagents_dir"/*.md; do
        [[ -f "$agent_source" ]] || continue
        agent_name="$(basename -- "$agent_source")"
        target_agent="${agents_target}/${agent_name}"
        if [[ -L "$target_agent" || ! -e "$target_agent" ]]; then
            ln -sfn "$agent_source" "$target_agent"
        fi
    done
}

link_pi_subagent_extension

# Claude still uses ~/.claude.json for some legacy state. Persist a dedicated
# YCRC copy on the host and mount it at that legacy path only inside the
# container, leaving a user's real ~/.claude.json untouched.
if [[ ! -e "$claude_config_file" ]]; then
    (umask 077; printf '{}\n' > "$claude_config_file")
fi
if [[ ! -f "$claude_config_file" ]]; then
    echo "Error: YCRC Claude state path is not a regular file: $claude_config_file" >&2
    exit 1
fi
chmod 0600 "$claude_config_file"

# Codex state is maintained only when launching Codex: since 1.1 each harness
# is its own module, and only codex-local ships codex-config.toml.
if [[ "$agent" == codex ]]; then
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
    # Codex 0.165+ runs its app-server as a background daemon reached through a
    # Unix socket under CODEX_HOME. In this sandbox the daemon never becomes
    # ready, so interactive codex exits at startup ("app server did not become
    # ready"). Keep the app-server in-process, as --no-daemon does, for every
    # subcommand including resume and fork. The key lives in the [features]
    # table; add the table if the file has none (a second [features] header
    # would be invalid TOML).
    if grep -qE '^[[:space:]]*daemon_auto_start[[:space:]]*=' "$codex_user_config"; then
        sed -i -E 's|^[[:space:]]*daemon_auto_start[[:space:]]*=.*$|daemon_auto_start = false|' "$codex_user_config"
    elif grep -qE '^[[:space:]]*\[features\][[:space:]]*$' "$codex_user_config"; then
        sed -i -E '/^[[:space:]]*\[features\][[:space:]]*$/a daemon_auto_start = false' "$codex_user_config"
    else
        printf '\n[features]\ndaemon_auto_start = false\n' >> "$codex_user_config"
    fi
    # Codex persists its own config.toml, so a user who has run Codex before keeps
    # whatever endpoint they were first given. If the inference service moves to a
    # different node, that stale value silently points them at a host that is no
    # longer serving, and the only fix would be deleting the file by hand. Re-apply
    # the endpoint from the administrator-managed config on every launch, the same
    # way the model sizing above is kept current. Only an existing key is rewritten:
    # base_url lives inside a [model_providers.*] table, so inserting one blind
    # could land it in the wrong table.
    codex_site_base_url="$(sed -nE 's|^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$|\1|p' "$codex_config" | head -1)"
    if [[ -n "$codex_site_base_url" ]] \
       && grep -qE '^[[:space:]]*base_url[[:space:]]*=' "$codex_user_config"; then
        sed -i -E "s|^[[:space:]]*base_url[[:space:]]*=.*$|base_url = \"${codex_site_base_url}\"|" "$codex_user_config"
    fi

    # Codex takes its model only from this file, so the reasoning opt-in has to be
    # written here rather than passed as an environment variable like the others.
    if grep -qE '^[[:space:]]*model[[:space:]]*=' "$codex_user_config"; then
        sed -i -E "s|^[[:space:]]*model[[:space:]]*=.*$|model = \"${agent_model}\"|" "$codex_user_config"
    else
        sed -i "1i model = \"${agent_model}\"" "$codex_user_config"
    fi
    chmod 0600 "$codex_user_config"
fi
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

# --- BEGIN user binds ---
# Read-only binds beyond the working directory and administrator binds:
#
# - Group shared directories, automatically: for each of the user's groups,
#   <base>/<group>/shared under the project, PI and scratch bases, when it
#   exists and the user can read it. Labs keep shared data and reference
#   databases there, outside any one member's own space.
# - Directories the user names with --bind (see "user bind arguments" above),
#   for example data in another group's space.
#
# Each directory, in order:
#   1. must be an existing directory the user can read;
#   2. is skipped if it is already visible (inside the working directory or an
#      administrator bind), so these binds never change the mode of something
#      already mounted;
#   3. is refused if it is or lies in a container system directory, has a
#      hidden component, contains ':' or ',', is or contains an excluded
#      directory, or is or contains the home directory (credentials and harness
#      state live there);
#   4. is otherwise mounted read-only at its own path, and at its resolved path
#      too when that differs, as for administrator binds.
# A refused --bind stops the launch; a group shared directory that fails a
# check is skipped with a note. Binds are only ever read-only: write access
# stays limited to the working directory and the approved state directories.
# Apptainer mounts nested binds parent-first, so a bind above the working
# directory leaves it writable.
path_is_within() {
    [[ "$1" == "$2" || "$1" == "$2/"* ]]
}

# Binding over these would replace the image's own files.
container_system_dirs=(/bin /boot /dev /etc /lib /lib64 /opt /proc /root /run /sbin /sys /usr /var)
user_bind_opts=()
user_bind_dirs=()
declare -A user_bind_seen=()

# add_readonly_bind SPEC: check SPEC and queue it, setting bind_logical to its
# container path. Returns 1 with the reason in bind_problem if it is refused,
# or 2 if it is skipped as already available.
add_readonly_bind() {
    local spec="$1" path logical resolved visible root candidate system_dir

    bind_problem=""
    path="$spec"
    case "$path" in
        *:rw)
            bind_problem="--bind gives read-only access only; it cannot make a directory writable: $spec"
            return 1
            ;;
        *:ro)
            path="${path%:ro}"
            ;;
    esac
    if [[ "$path" == *:* ]]; then
        bind_problem="--bind takes a directory, optionally followed by :ro; other ':' fields are not supported: $spec"
        return 1
    fi
    # A leading ~ arrives literally when written as --bind=~/x.
    # shellcheck disable=SC2088
    case "$path" in
        "~") path="$host_home" ;;
        "~/"*) path="${host_home}/${path#"~/"}" ;;
    esac

    # 1. An existing directory the user can read. Relative paths are resolved
    # from the launch directory.
    if ! resolved="$(realpath -e -- "$path" 2>/dev/null)" || [[ ! -d "$resolved" ]]; then
        bind_problem="not an existing directory: $spec"
        return 1
    fi
    if [[ ! -r "$resolved" || ! -x "$resolved" ]]; then
        bind_problem="you cannot read this directory: $spec"
        return 1
    fi
    # The path as given (made absolute) is kept when it still leads to the same
    # directory, so a symlinked path works under both names.
    logical="$(realpath -s -m -- "$path")"
    if [[ "$(realpath -e -- "$logical" 2>/dev/null)" != "$resolved" ]]; then
        logical="$resolved"
    fi

    # 2. Already visible.
    visible=false
    if path_is_within "$resolved" "$work_dir" || [[ -n "${user_bind_seen[$logical]:-}" ]]; then
        visible=true
    fi
    for root in "${configured_bind_roots[@]}" "${configured_bind_paths[@]}"; do
        if path_is_within "$resolved" "$root" || path_is_within "$logical" "$root"; then
            visible=true
        fi
    done
    if [[ "$visible" == true ]]; then
        return 2
    fi

    # 3. Refused paths, checked for both the given and the resolved path.
    for candidate in "$logical" "$resolved"; do
        if [[ "$candidate" == / ]]; then
            bind_problem="/ cannot be bound."
            return 1
        fi
        for system_dir in "${container_system_dirs[@]}"; do
            if path_is_within "$candidate" "$system_dir"; then
                bind_problem="$candidate is in the container system directory $system_dir."
                return 1
            fi
        done
        if [[ "$candidate" == */.* ]]; then
            bind_problem="hidden directories cannot be bound: $candidate"
            return 1
        fi
        if [[ "$candidate" == *[:,]* ]]; then
            bind_problem="Apptainer cannot bind a path containing ':' or ',': $candidate"
            return 1
        fi
        if path_is_within "$home_root" "$candidate" || path_is_within "$host_home" "$candidate"; then
            bind_problem="$spec is or contains your home directory, which holds credentials and harness state. Bind a subdirectory instead."
            return 1
        fi
    done
    for root in "${excluded_work_roots[@]}"; do
        if path_is_within "$resolved" "$root" || path_is_within "$root" "$resolved"; then
            bind_problem="$spec is or contains the excluded directory $root"
            return 1
        fi
    done

    # 4. Mount read-only.
    user_bind_seen["$logical"]=1
    user_bind_opts+=(--bind "${resolved}:${logical}:ro")
    user_bind_dirs+=("$logical")
    if [[ "$resolved" != "$logical" && -z "${user_bind_seen[$resolved]:-}" ]]; then
        user_bind_seen["$resolved"]=1
        user_bind_opts+=(--bind "${resolved}:${resolved}:ro")
        user_bind_dirs+=("$resolved")
    fi
    bind_logical="$logical"
}

for user_bind_spec in "${user_bind_specs[@]}"; do
    user_bind_status=0
    add_readonly_bind "$user_bind_spec" || user_bind_status=$?
    case "$user_bind_status" in
        0) echo "Binding read-only: $bind_logical" >&2 ;;
        2) echo "Note: $user_bind_spec is already available inside the container; --bind skipped." >&2 ;;
        *) echo "Error: --bind refused: $bind_problem" >&2
           exit 1 ;;
    esac
done

for group_name in $group_output; do
    for storage_base in "${storage_bases[@]}"; do
        group_shared_dir="${storage_base}/${group_name}/shared"
        [[ -d "$group_shared_dir" ]] || continue
        user_bind_status=0
        add_readonly_bind "$group_shared_dir" || user_bind_status=$?
        case "$user_bind_status" in
            0) echo "Binding read-only: $bind_logical (group shared directory)" >&2 ;;
            2) ;;
            *) echo "Note: group shared directory not bound: $bind_problem" >&2 ;;
        esac
    done
done
# --- END user binds ---

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

# Expose the user's Git configuration read-only when present. This provides
# normal Git identity/settings without exposing ~/.ssh or Git credential files.
if [[ -f "${host_home}/.gitconfig" ]]; then
    bind_opts+=(--bind "${host_home}/.gitconfig:${host_home}/.gitconfig:ro")
fi

# Reuse the user's provisioned SSH host trust without exposing ~/.ssh. YCRC
# creates ~/.ssh/known_hosts for user accounts; present only that file as the
# container's system known-hosts database.
if [[ -f "${host_home}/.ssh/known_hosts" && -r "${host_home}/.ssh/known_hosts" ]]; then
    bind_opts+=(--bind "${host_home}/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro")
fi

# Provide Git/SSH authentication without exposing private key files. Prefer an
# ssh-agent the user already has. If none is available, create a temporary
# agent on the host and load the identities that the host SSH configuration
# says it would use for github.com. Only the resulting socket is mounted into
# the coding-agent container; ~/.ssh and the private keys remain inaccessible.
client_ssh_auth_sock=""
temporary_ssh_agent_pid=""
temporary_ssh_agent_dir=""
session_tmp_dir=""

cleanup_temporary_ssh_agent() {
    if [[ -n "$temporary_ssh_agent_pid" ]]; then
        kill "$temporary_ssh_agent_pid" 2>/dev/null || true
        wait "$temporary_ssh_agent_pid" 2>/dev/null || true
    fi
    if [[ -n "$temporary_ssh_agent_dir" ]]; then
        rm -rf -- "$temporary_ssh_agent_dir"
    fi
}

cleanup_session() {
    cleanup_temporary_ssh_agent
    if [[ -n "$session_tmp_dir" ]]; then
        # Some tools (Go's module cache, for example) leave read-only
        # directories that rm -rf alone cannot remove.
        chmod -R u+w -- "$session_tmp_dir" 2>/dev/null || true
        rm -rf -- "$session_tmp_dir"
    fi
}
trap cleanup_session EXIT HUP INT TERM

# Session scratch. With --contain, Apptainer puts /tmp and the container home
# in its session directory, which apptainer.conf caps at 64 MB, so pip, conda
# and similar tools fail with ENOSPC as soon as they unpack or cache anything.
# Bind a private, disk-backed host directory over /tmp instead (TMPDIR and the
# per-user cache are pointed at it below); it is removed when the session ends.
if session_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ycrc-agent-tmp.XXXXXX")"; then
    bind_opts+=(--bind "${session_tmp_dir}:/tmp")
else
    session_tmp_dir=""
    echo "Warning: could not create a session temporary directory; /tmp in the agent is limited to 64 MB." >&2
fi

if [[ -n "$host_ssh_auth_sock" && -S "$host_ssh_auth_sock" ]]; then
    bind_opts+=(--bind "${host_ssh_auth_sock}:/run/ycrc-agent/ssh.sock")
    client_ssh_auth_sock="/run/ycrc-agent/ssh.sock"
elif command -v ssh-agent >/dev/null 2>&1 && command -v ssh-add >/dev/null 2>&1 && command -v ssh >/dev/null 2>&1; then
    temporary_ssh_agent_dir="$(mktemp -d "${TMPDIR:-/tmp}/ycrc-agent-ssh.XXXXXX")"
    temporary_ssh_socket="${temporary_ssh_agent_dir}/agent.sock"

    # Start the agent at a wrapper-controlled path so no output parsing/eval is
    # needed. The PID is captured only for cleanup after the harness exits.
    temporary_ssh_agent_pid="$(ssh-agent -a "$temporary_ssh_socket" -s | sed -n 's/^echo Agent pid \([0-9][0-9]*\);$/\1/p')"
    if [[ -z "$temporary_ssh_agent_pid" || ! -S "$temporary_ssh_socket" ]]; then
        echo "Warning: could not start a temporary SSH agent; GitHub SSH authentication may be unavailable." >&2
        cleanup_temporary_ssh_agent
        temporary_ssh_agent_pid=""
        temporary_ssh_agent_dir=""
    else
        # ssh-add needs the host-side socket only while identities are loaded.
        # Resolve configured/default GitHub identities using the host SSH
        # client, honoring IdentityFile settings rather than assuming id_rsa.
        loaded_ssh_identity=false
        while IFS= read -r identity_file; do
            case "$identity_file" in
                '~/'*) identity_file="${host_home}/${identity_file#\~/}" ;;
                /*) ;;
                *) continue ;;
            esac
            [[ -f "$identity_file" && -r "$identity_file" ]] || continue
            if SSH_AUTH_SOCK="$temporary_ssh_socket" ssh-add -- "$identity_file" </dev/tty; then
                loaded_ssh_identity=true
            fi
        done < <(ssh -G github.com 2>/dev/null | awk '$1 == "identityfile" { print $2 }' | awk '!seen[$0]++')

        if [[ "$loaded_ssh_identity" == true ]]; then
            bind_opts+=(--bind "${temporary_ssh_socket}:/run/ycrc-agent/ssh.sock")
            client_ssh_auth_sock="/run/ycrc-agent/ssh.sock"
        else
            echo "Warning: no usable GitHub SSH identity could be loaded; GitHub SSH authentication may be unavailable." >&2
            cleanup_temporary_ssh_agent
            temporary_ssh_agent_pid=""
            temporary_ssh_agent_dir=""
        fi
    fi
fi

# Present the dedicated YCRC Claude legacy-state file at Claude's historical
# ~/.claude.json location only inside the container.
bind_opts+=(--bind "${claude_config_file}:${host_home}/.claude.json")

bind_opts+=("${configured_bind_opts[@]}")
bind_opts+=("${user_bind_opts[@]}")

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

# renv's default package cache (~/.cache/R/renv) would land in the container's
# small temporary home and be lost with the session. Keep it under the
# persistent ~/R bind instead, unless the user has chosen a location.
if [[ -z "${RENV_PATHS_CACHE:-}" ]]; then
    renv_cache_dir="${r_library_dir}/renv-cache"
    if mkdir -p -m 0700 -- "$renv_cache_dir"; then
        client_env_opts+=(--env "RENV_PATHS_CACHE=${renv_cache_dir}")
    fi
fi

# Send temporary files and the per-user cache (pip, matplotlib, Hugging Face,
# uv, ...) to the disk-backed session /tmp rather than the 64 MB container
# home. TMPDIR is always replaced: an inherited host value usually names a path
# that does not exist inside the container. An explicit XDG_CACHE_HOME is kept.
if [[ -n "$session_tmp_dir" ]]; then
    client_env_opts+=(--env "TMPDIR=/tmp")
    if [[ -z "${XDG_CACHE_HOME:-}" ]]; then
        client_env_opts+=(--env "XDG_CACHE_HOME=/tmp/.cache")
    fi
fi

# Tell every harness which directories the user bound read-only at launch
# (colon-separated; --bind refuses paths containing ':').
if (( ${#user_bind_dirs[@]} > 0 )); then
    client_env_opts+=(--env "YCRC_READONLY_BINDS=$(IFS=:; echo "${user_bind_dirs[*]}")")
fi

# Reintroduce only the controlled in-container ssh-agent socket. Users without
# an active ssh-agent simply receive no SSH_AUTH_SOCK inside the container.
if [[ -n "$client_ssh_auth_sock" ]]; then
    client_env_opts+=(--env "SSH_AUTH_SOCK=${client_ssh_auth_sock}")
fi

case "$agent" in
    claude)
        client_bin=claude
        client_env_opts+=(
            --env "DISABLE_BUG_COMMAND=1"
            --env "ANTHROPIC_TELEMETRY_DISABLED=1"
            --env "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
            --env "CLAUDE_CODE_AUTO_MODE_SERVER=0"
            --env "CLAUDE_CONFIG_DIR=${claude_config_dir}"
            --env "ANTHROPIC_BASE_URL=${YCRC_CLAUDE_BASE_URL}"
            --env "ANTHROPIC_MODEL=${agent_model}"
            --env "ANTHROPIC_SMALL_FAST_MODEL=${base_model}"
            --env "ANTHROPIC_AUTH_TOKEN=${agent_auth}"
            --env "CLAUDE_CODE_EFFORT_LEVEL=${YCRC_CLAUDE_EFFORT:-xhigh}"
            --env "CLAUDE_CODE_MAX_CONTEXT_TOKENS=${YCRC_AGENT_MAX_CONTEXT}"
        )
        # Claude's file tools only work in its working directory and the
        # directories it is given. The = form keeps --add-dir, which takes
        # several values, from consuming the user's prompt.
        for user_bind_dir in "${user_bind_dirs[@]}"; do
            client_args+=("--add-dir=${user_bind_dir}")
        done
        ;;
    codex)
        client_bin=codex
        [[ -r "$codex_config" ]] || { echo "Error: missing Codex config: $codex_config" >&2; exit 1; }
        client_env_opts+=(
            --env "CODEX_HOME=${codex_home}"
            --env "BOUCHET_API_KEY=${agent_auth}"
        )
        ;;
    pi)
        client_bin=pi
        [[ -r "$pi_models_config" ]] || { echo "Error: missing Pi models config: $pi_models_config" >&2; exit 1; }
        # Pi accepts only models listed in models.json. When the session uses
        # the served model's real name, mount a copy of the managed file that
        # also lists it (and its reasoning variant) with the alias entries'
        # settings. The copy lives in a launcher directory that is not bound
        # into the container, so like the managed file it is read-only there;
        # it is replaced atomically at each launch, which leaves running
        # sessions on the version they started with.
        pi_models_source="$pi_models_config"
        launcher_cache_dir="${host_home}/.cache/ycrc-launcher"
        pi_models_copy="${launcher_cache_dir}/pi-models.json"
        pi_models_tmp=""
        if [[ "$base_model" != "$YCRC_AGENT_MODEL" ]] &&
           mkdir -p -m 0700 -- "$launcher_cache_dir" &&
           pi_models_tmp="$(mktemp "${launcher_cache_dir}/pi-models.XXXXXX")" &&
           python3 -I - "$pi_models_config" "$pi_models_tmp" "$YCRC_AGENT_MODEL" "$base_model" "${YCRC_AGENT_THINK_SUFFIX:-}" <<'PY'
import json, sys
source, target, alias, real, suffix = sys.argv[1:]
config = json.load(open(source))
for provider in config.get("providers", {}).values():
    models = provider.get("models", [])
    known = {m.get("id") for m in models}
    for entry in list(models):
        for old, new in ((alias, real), (alias + suffix, real + suffix) if suffix else (None, None)):
            if old and entry.get("id") == old and new not in known:
                models.append(dict(entry, id=new))
                known.add(new)
with open(target, "w") as f:
    json.dump(config, f, indent=2)
PY
        then
            chmod 0644 "$pi_models_tmp"
            if mv -f -- "$pi_models_tmp" "$pi_models_copy"; then
                pi_models_source="$pi_models_copy"
            fi
        fi
        if [[ -n "$pi_models_tmp" ]]; then
            rm -f -- "$pi_models_tmp"
        fi
        bind_opts+=(--bind "${pi_models_source}:${pi_home}/models.json:ro")
        client_env_opts+=(
            --env "PI_CODING_AGENT_DIR=${pi_home}"
            --env "PI_OFFLINE=true"
            --env "PI_SKIP_VERSION_CHECK=1"
            --env "PI_TELEMETRY=0"
            --env "YCRC_PI_API_KEY=${agent_auth}"
        )
        # Explicit selection prevents Pi from restoring a previously selected
        # non-Bouchet provider/model from persistent session state.
        client_args+=(--approve --provider bouchet --model "${agent_model}")
        ;;
    copilot)
        client_bin=copilot
        client_env_opts+=(
            --env "COPILOT_HOME=${copilot_home}"
            --env "COPILOT_CACHE_HOME=${copilot_cache_home}"
            --env "COPILOT_PROVIDER_TYPE=openai"
            --env "COPILOT_PROVIDER_BASE_URL=${YCRC_COPILOT_BASE_URL}"
            --env "COPILOT_PROVIDER_API_KEY=${agent_auth}"
            --env "COPILOT_MODEL=${agent_model}"
            --env "COPILOT_PROVIDER_MAX_PROMPT_TOKENS=${YCRC_AGENT_MAX_PROMPT}"
            --env "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=${YCRC_AGENT_MAX_OUTPUT}"
            --env "COPILOT_SKILLS_DIRS=/etc/agents/skills"
            --env "COPILOT_ALLOW_ALL=true"
            --env "COPILOT_OFFLINE=true"
        )
        client_args+=(--disable-builtin-mcps)
        ;;
esac

session_start="$(date +%s)"

set +e
apptainer exec \
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
client_status=$?

# Per-netid usage accounting. Report one session record to the collector
# running beside the inference server, so administrators can see which netids
# use the service, through which harness, and for how long. The endpoint is
# configured in coding-agents-provider.conf; leaving it unset disables
# reporting entirely.
#
# Identity comes from the account database ($user_name, resolved at the top of
# this script), never from the mutable environment. Prompts, file paths,
# command arguments and the working directory are deliberately NOT reported --
# only who ran which harness, for how long, and whether it exited cleanly.
#
# Reporting is strictly best-effort and must never break or delay a user's
# session: the call is bounded by a short timeout, all output is discarded,
# and every failure is swallowed. A refused connection (collector down)
# returns immediately rather than waiting out the timeout.
if [[ -n "${YCRC_AGENT_USAGE_ENDPOINT:-}" ]] && command -v curl >/dev/null 2>&1; then
    {
        session_end="$(date +%s)"
        # The module installs into <name>/<version>/, so the install directory
        # names the version; a hard-coded string went stale across releases.
        wrapper_version="$(basename -- "$launcher_dir")"
        [[ "$wrapper_version" =~ ^[0-9][0-9A-Za-z.+_-]*$ ]] || wrapper_version="unknown"
        printf -v usage_record \
            '{"netid":"%s","uid":%s,"agent":"%s","cluster":"%s","model":"%s","slurm_job":"%s","node":"%s","start_epoch":%s,"end_epoch":%s,"duration_s":%s,"exit":%s,"wrapper":"%s"}' \
            "$user_name" "$(id -u)" "$agent" "${YCRC_CLUSTER:-unknown}" \
            "${YCRC_AGENT_MODEL:-unknown}" "${SLURM_JOB_ID:-}" "$host_name" \
            "$session_start" "$session_end" "$((session_end - session_start))" \
            "$client_status" "$wrapper_version"
        curl -sS -X POST \
            --connect-timeout 1 --max-time 3 \
            -H 'Content-Type: application/json' \
            ${YCRC_AGENT_USAGE_TOKEN:+-H "X-Usage-Token: ${YCRC_AGENT_USAGE_TOKEN}"} \
            --data "$usage_record" \
            "$YCRC_AGENT_USAGE_ENDPOINT"
    } >/dev/null 2>&1 || true
fi

set -e
exit "$client_status"
