#!/usr/bin/env bats
# Tests for `claude --local-model`: a model hosted by YCRC instead of Anthropic's.
# The shipped claude-local-model.conf is installed in every sandbox; the curl stub
# answers the service check (STUB_SERVICE, see the harness).
# SC2016: config fixtures and jq filters are single-quoted on purpose.
# SC2030/SC2031/SC2034: tests set variables (WORK_DIR, WRAPPER_ENV, ...) the harness reads.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

load 'test_helper/harness'

MODEL=ycrc-local
GATEWAY=http://a1127u31n01.mghpcc.ycrc.yale.edu:8008

setup() {
    harness_setup
    LOCAL_CONF="${INSTALL_DIR}/claude-local-model.conf"
    cp -- "${WRAPPER_DIR}/claude-local-model.conf" "$LOCAL_CONF"
}

# set_local LINE: append an assignment to the conf; the last one wins.
set_local() {
    printf '%s\n' "$1" >> "$LOCAL_CONF"
}

# setup_conf_with NAME=VALUE: a fresh copy of the shipped conf with NAME's
# assignment replaced by this one.
setup_conf_with() {
    cp -- "${WRAPPER_DIR}/claude-local-model.conf" "$LOCAL_CONF"
    sed -i "/^${1%%=*}=/d" "$LOCAL_CONF"
    set_local "$1"
}

# env_value NAME: the value given to apptainer as --env NAME=...; fails if absent.
env_value() {
    local line
    while IFS= read -r line; do
        if [[ "${line%%=*}" == "$1" ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < <(apptainer_env_opts)
    return 1
}

# claude_option OPTION: the argument following OPTION among Claude's arguments.
claude_option() {
    local -a args
    local i
    mapfile -t args < <(claude_args)
    for (( i = 0; i < ${#args[@]}; i++ )); do
        if [[ "${args[i]}" == "$1" ]]; then
            printf '%s\n' "${args[i + 1]}"
            return 0
        fi
    done
    return 1
}

# settings_jq [JQ_ARGS...] FILTER: run jq -e on the --settings JSON Claude received.
settings_jq() {
    claude_option --settings | jq -e "$@"
}

# assert_env NAME VALUE: apptainer received --env NAME=VALUE.
assert_env() {
    local actual
    actual="$(env_value "$1")" || fail "missing --env $1"$'\n'"$(apptainer_env_opts)"
    [[ "$actual" == "$2" ]] || fail "--env $1: expected [$2], got [$actual]"
}

refute_env() {
    if env_value "$1" >/dev/null; then
        fail "unexpected --env $1"
    fi
}

# curl_argv_contains STRING: one of curl's arguments is exactly STRING.
curl_argv_contains() {
    local -a argv
    mapfile -d '' -t argv < "${STUB_LOG_DIR}/curl.argv"
    printf '%s\n' "${argv[@]}" | grep -Fxq -- "$1" ||
        fail "curl was not given [$1]:"$'\n'"$(printf '%s\n' "${argv[@]}")"
}

# --- Starting the mode --------------------------------------------------------

@test "local-model: --local-model launches against the local model service" {
    run_wrapper --local-model -p hi
    assert_success
    assert_apptainer_called
    assert_env ANTHROPIC_BASE_URL "$GATEWAY"
    [[ "$(claude_args | tail -n 2 | paste -sd ' ')" == "-p hi" ]] || fail "user args not last: $(claude_args)"
    if claude_args | grep -Fxq -- --local-model; then
        fail "--local-model was passed to Claude"
    fi
}

@test "local-model: without the flag nothing changes, and the conf is not needed" {
    rm -- "$LOCAL_CONF"
    run_wrapper -p hi
    assert_success
    assert_claude_args -p hi
    refute_env ANTHROPIC_BASE_URL
    curl_was_called && fail "the service check ran in the default mode"
    true
}

@test "local-model: after --, --local-model is passed to Claude" {
    run_wrapper -- --local-model
    assert_success
    assert_claude_args -- --local-model
    refute_env ANTHROPIC_BASE_URL
}

@test "local-model: the old --in-house-model is just passed to Claude" {
    run_wrapper --in-house-model -p hi
    assert_success
    assert_claude_args --in-house-model -p hi
    refute_env ANTHROPIC_BASE_URL
    curl_was_called && fail "the service check ran"
    true
}

@test "local-model: --local-model=NAME is reserved" {
    run_wrapper --local-model=other
    assert_failure
    assert_output --partial "--local-model takes no value"
    refute_apptainer_called
}

# --- Environment --------------------------------------------------------------

@test "local-model: default-session environment" {
    run_wrapper --local-model
    assert_success
    assert_env ANTHROPIC_MODEL "$MODEL"
    assert_env ANTHROPIC_DEFAULT_OPUS_MODEL "$MODEL"
    assert_env ANTHROPIC_DEFAULT_OPUS_MODEL_NAME "$MODEL (hosted by YCRC)"
    assert_env CLAUDE_CODE_SUBAGENT_MODEL "$MODEL"
    assert_env CLAUDE_CODE_DISABLE_1M_CONTEXT 1
    assert_env CLAUDE_CODE_MAX_CONTEXT_TOKENS 262000
    assert_env CLAUDE_CODE_MAX_OUTPUT_TOKENS 16384
    assert_env CLAUDE_CODE_AUTO_MODE_SERVER 0
    assert_env DISABLE_BUG_COMMAND 1
    local name
    for name in ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
                ANTHROPIC_DEFAULT_FABLE_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CONFIG_DIR \
                CLAUDE_CODE_EFFORT_LEVEL; do
        refute_env "$name"
        stub_environment "$name" >/dev/null && fail "$name is set in the environment"
    done
    true
}

@test "local-model: reasoning is left to the effort level, with no extra body" {
    run_wrapper --local-model
    assert_success
    refute_env CLAUDE_CODE_EXTRA_BODY
    stub_environment CLAUDE_CODE_EXTRA_BODY >/dev/null && fail "CLAUDE_CODE_EXTRA_BODY is set in the environment"
    settings_jq '.env | has("CLAUDE_CODE_EXTRA_BODY") | not' >/dev/null ||
        fail "settings: $(claude_option --settings)"
}

@test "local-model: the credential is <id -un>.claude-mod, from id -un, and not in argv" {
    WRAPPER_ENV=(USER=someone-else)
    run_wrapper --local-model
    assert_success
    local expected
    expected="$(id -un).claude-mod"
    [[ "$(stub_environment ANTHROPIC_AUTH_TOKEN)" == "$expected" ]] ||
        fail "ANTHROPIC_AUTH_TOKEN: $(stub_environment ANTHROPIC_AUTH_TOKEN)"
    refute_argv_contains "$expected"
}

@test "local-model: inherited provider settings are removed; the default mode keeps them" {
    WRAPPER_ENV=(
        ANTHROPIC_BASE_URL=http://elsewhere.example:1
        ANTHROPIC_MODEL=claude-elsewhere
        CLAUDE_CODE_USE_BEDROCK=1
        'CLAUDE_CODE_EXTRA_BODY={"chat_template_kwargs":{"enable_thinking":true}}'
        CLAUDE_CODE_EFFORT_LEVEL=high
        APPTAINERENV_ANTHROPIC_BASE_URL=http://elsewhere.example:2
        SINGULARITYENV_CLAUDE_CODE_USE_VERTEX=1
    )
    local name
    local -a names=(ANTHROPIC_BASE_URL ANTHROPIC_MODEL CLAUDE_CODE_USE_BEDROCK
                    CLAUDE_CODE_EXTRA_BODY CLAUDE_CODE_EFFORT_LEVEL APPTAINERENV_ANTHROPIC_BASE_URL
                    SINGULARITYENV_CLAUDE_CODE_USE_VERTEX)

    run_wrapper --local-model
    assert_success
    for name in "${names[@]}"; do
        stub_environment "$name" >/dev/null && fail "$name was inherited in local mode"
        assert_output --partial "$name"
    done

    run_wrapper
    assert_success
    for name in "${names[@]}"; do
        stub_environment "$name" >/dev/null || fail "$name was removed in the default mode"
    done
}

@test "local-model: an inherited CLAUDE_CONFIG_DIR is kept in both modes" {
    WRAPPER_ENV=(CLAUDE_CONFIG_DIR=/somewhere)
    run_wrapper --local-model
    assert_success
    [[ "$(stub_environment CLAUDE_CONFIG_DIR)" == /somewhere ]] || fail "removed in local mode"
    run_wrapper
    [[ "$(stub_environment CLAUDE_CONFIG_DIR)" == /somewhere ]] || fail "removed in the default mode"
}

# --- Claude options -----------------------------------------------------------

@test "local-model: --settings and --append-system-prompt come before --add-dir and the user's args" {
    mkdir -p "${SANDBOX}/data"
    run_wrapper --local-model --bind="${SANDBOX}/data" -p hi
    assert_success
    local -a args
    mapfile -t args < <(claude_args)
    (( ${#args[@]} == 7 )) || fail "unexpected claude args: $(printf '[%s] ' "${args[@]}")"
    [[ "${args[0]}" == --settings && "${args[2]}" == --append-system-prompt ]] ||
        fail "mode options not first: $(printf '[%s] ' "${args[@]}")"
    [[ "${args[4]}" == "--add-dir=${SANDBOX}/data" && "${args[5]}" == -p && "${args[6]}" == hi ]] ||
        fail "unexpected order: $(printf '[%s] ' "${args[@]}")"
    assert_bind "${SANDBOX}/data:${SANDBOX}/data:ro"
}

@test "local-model: --settings routes, restricts the model choice, and denies WebSearch" {
    run_wrapper --local-model
    assert_success
    local filter
    for filter in \
        ".env.ANTHROPIC_BASE_URL == \"$GATEWAY\"" \
        ".env.ANTHROPIC_MODEL == \"$MODEL\"" \
        ".env.ANTHROPIC_DEFAULT_OPUS_MODEL == \"$MODEL\"" \
        '.maxEffortLevel == "xhigh" and (has("effortLevel") | not)' \
        '.env | has("CLAUDE_CODE_EFFORT_LEVEL") | not' \
        '.env.CLAUDE_CODE_USE_BEDROCK == "0" and .env.CLAUDE_CODE_USE_VERTEX == "0" and .env.CLAUDE_CODE_USE_FOUNDRY == "0"' \
        ".availableModels == [\"$MODEL\"]" \
        ".modelPicker.options == [{\"model\": \"$MODEL\", \"label\": \"$MODEL (hosted by YCRC)\"}]" \
        '.modelPicker.replaceBuiltInOptions == true' \
        '.permissions.deny == ["WebSearch"]'; do
        settings_jq "$filter" >/dev/null || fail "settings fail [$filter]: $(claude_option --settings)"
    done
}

@test "local-model: the system-prompt note names the model and the shared sessions" {
    run_wrapper --local-model
    assert_success
    local note
    note="$(claude_option --append-system-prompt)"
    [[ "$note" == *"$MODEL"* && "$note" == *YCRC* && "$note" == *"--local-model"* ]] ||
        fail "note: $note"
}

@test "local-model: the local model, default, --resume and --continue pass through" {
    local -a case_args
    local spec
    for spec in "--model $MODEL" "--model=$MODEL" "--model default" "--model=default" \
                "--resume abc123" "--continue"; do
        read -r -a case_args <<< "$spec"
        run_wrapper --local-model "${case_args[@]}" -p hi
        assert_success
        [[ "$(claude_args | tail -n $(( ${#case_args[@]} + 2 )) | paste -sd ' ')" == "$spec -p hi" ]] ||
            fail "[$spec] claude args: $(claude_args)"
    done
}

@test "local-model: the banner is on stderr and mentions shared sessions" {
    run_wrapper --separate-stderr --local-model
    assert_success
    assert_output ""
    [[ "$stderr" == *"Local model: $MODEL, hosted by YCRC"* ]] || fail "no banner: $stderr"
    [[ "$stderr" == *"shared with your normal Claude"* ]] || fail "no shared-state note: $stderr"
    [[ "$stderr" == *"Effort: low, medium or xhigh (/effort); high, the default, runs as medium."* ]] ||
        fail "no effort line: $stderr"
}

# --- Shared state -------------------------------------------------------------

@test "local-model: Claude state is bound exactly as in the default mode" {
    set_conf bind 'binds=("$HOME/.claude:rw" "$HOME/.local/share/claude:rw")'
    : > "${TEST_HOME}/.claude.json"
    run_wrapper
    assert_success
    local default_binds
    default_binds="$(apptainer_binds)"
    run_wrapper --local-model
    assert_success
    [[ "$(apptainer_binds)" == "$default_binds" ]] ||
        fail "binds differ:"$'\n'"default:"$'\n'"$default_binds"$'\n'"local:"$'\n'"$(apptainer_binds)"
    assert_bind "${TEST_HOME}/.claude:${TEST_HOME}/.claude:rw"
    assert_bind "${TEST_HOME}/.claude.json:${TEST_HOME}/.claude.json"
}

@test "local-model: no separate state is created" {
    run_wrapper --local-model
    assert_success
    if compgen -G "${TEST_HOME}/.claude-local*" >/dev/null; then
        fail "separate state was created: $(ls -a "$TEST_HOME")"
    fi
}

# --- Errors -------------------------------------------------------------------

@test "local-model: other clusters are refused before any network check" {
    WRAPPER_ENV=(CLUSTER=mccleary)
    run_wrapper --local-model
    assert_failure
    assert_output --partial "only available on: bouchet"
    refute_apptainer_called
    curl_was_called && fail "the service was contacted"
    true
}

@test "local-model: each service failure has its own message" {
    local -a cases=(
        "down|isn't reachable right now"
        "502|its model server isn't responding"
        "401|returned HTTP 401"
        "nomodel|doesn't offer $MODEL"
    )
    local entry
    for entry in "${cases[@]}"; do
        STUB_SERVICE="${entry%%|*}" run_wrapper --local-model
        assert_failure
        assert_output --partial "${entry#*|}"
        assert_output --partial "research.computing@yale.edu"
        refute_apptainer_called
    done
    STUB_SERVICE=down run_wrapper --local-model
    assert_output --partial "a1127u31n01.mghpcc.ycrc.yale.edu:8008"
}

@test "local-model: the service check is a GET of /v1/models with the user's credential" {
    run_wrapper --local-model
    assert_success
    curl_argv_contains "${GATEWAY}/v1/models"
    curl_argv_contains "Authorization: Bearer $(id -un).claude-mod"
    if tr '\0' '\n' < "${STUB_LOG_DIR}/curl.argv" | grep -Eqx -- '-X|--request|-d|--data.*'; then
        fail "the check is not a plain GET: $(tr '\0' ' ' < "${STUB_LOG_DIR}/curl.argv")"
    fi
}

@test "local-model: the service check runs after the local checks" {
    WORK_DIR="$TEST_HOME"
    STUB_SERVICE=down run_wrapper --local-model
    assert_failure
    assert_output --partial "non-hidden subdirectory"
    curl_was_called && fail "the service was contacted before the local checks"
    true
}

@test "local-model: a missing curl is reported plainly" {
    # A PATH with the stubs and the tools the wrapper needs, but no curl.
    local bin="${SANDBOX}/nocurl" tool
    mkdir -p "$bin"
    for tool in bash dirname realpath mkdir id sort; do
        ln -s "$(command -v "$tool")" "${bin}/${tool}"
    done
    cp -- "${STUB_DIR}/apptainer" "${STUB_DIR}/hostname" "${STUB_DIR}/groups" "$bin/"
    WRAPPER_ENV=("PATH=${bin}")
    run_wrapper --local-model
    assert_failure
    assert_output --partial "needs curl"
    refute_apptainer_called
    # The default mode does not need curl.
    run_wrapper
    assert_success
}

@test "local-model: a missing conf stops local mode only" {
    rm -- "$LOCAL_CONF"
    run_wrapper --local-model
    assert_failure
    assert_output --partial "local model configuration not found"
    refute_apptainer_called
    run_wrapper
    assert_success
}

@test "local-model: --effort high and max are refused; low, medium and xhigh pass through" {
    local -a case_args
    local spec
    for spec in "--effort high" "--effort=max" "--effort ultracode"; do
        read -r -a case_args <<< "$spec"
        run_wrapper --local-model "${case_args[@]}" -p hi
        assert_failure
        assert_output --partial "use low, medium or xhigh"
        refute_apptainer_called
        curl_was_called && fail "[$spec] the service was contacted"
    done
    for spec in "--effort low" "--effort=medium" "--effort xhigh"; do
        read -r -a case_args <<< "$spec"
        run_wrapper --local-model "${case_args[@]}" -p hi
        assert_success
        [[ "$(claude_args | tail -n $(( ${#case_args[@]} + 2 )) | paste -sd ' ')" == "$spec -p hi" ]] ||
            fail "[$spec] claude args: $(claude_args)"
    done
    run_wrapper --effort high -p hi
    assert_success
}


@test "local-model: malformed conf values are refused" {
    local line
    for line in \
        "local_agent_label='claude mod'" \
        "local_agent_label='a.b'" \
        "local_base_url='ftp://host:1'" \
        "local_base_url='http://host:1/v1?x=1'" \
        "local_model='Qwen 3'" \
        "local_model='a\"b'" \
        "local_max_output='0'" \
        "local_max_context='12k'" \
        "local_clusters=()" \
        "local_clusters='bouchet'"; do
        setup_conf_with "$line"
        run_wrapper --local-model
        assert_failure
        refute_apptainer_called
        curl_was_called && fail "[$line] the service was contacted"
    done
    true
}

@test "local-model: an inherited variable cannot fill a gap in the conf" {
    sed -i '/^local_base_url=/d' "$LOCAL_CONF"
    WRAPPER_ENV=(local_base_url=http://elsewhere.example:1)
    run_wrapper --local-model
    assert_failure
    assert_output --partial "local_base_url"
    curl_was_called && fail "the service was contacted"
    true
}

@test "local-model: other models, --fallback-model and a user --settings are refused" {
    local -a case_args
    local spec
    for spec in "--model ${MODEL}-think" "--model opus" "--model=sonnet" \
                "--model claude-sonnet-5" "--fallback-model x" "--fallback-model=x" \
                "--settings {}" "--settings=/some/file.json"; do
        read -r -a case_args <<< "$spec"
        run_wrapper --local-model "${case_args[@]}"
        assert_failure
        refute_apptainer_called
    done
    run_wrapper --model opus --local-model
    assert_failure
    assert_output --partial "start claude without --local-model"
    run_wrapper --local-model --settings '{}'
    # shellcheck disable=SC2088  # the message names the path literally
    assert_output --partial "~/.claude/settings.json"
    # The default mode passes them on untouched.
    run_wrapper --model opus --fallback-model sonnet --settings '{}'
    assert_success
    assert_claude_args --model opus --fallback-model sonnet --settings '{}'
}

@test "local-model: --ycrc-help describes --local-model" {
    run_wrapper --ycrc-help
    assert_success
    assert_output --partial "--local-model"
    assert_output --partial "hosted by YCRC"
    assert_output --partial "Bouchet only"
}
