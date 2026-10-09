#!/usr/bin/env bats
# Tests for `claude --in-house-model`: YCRC's in-house model instead of Anthropic's.
# The shipped claude-in-house.conf is installed in every sandbox; the curl stub
# answers the service check (STUB_SERVICE, see the harness).
# SC2016: config fixtures and jq filters are single-quoted on purpose.
# SC2030/SC2031/SC2034: tests set variables (WORK_DIR, WRAPPER_ENV, ...) the harness reads.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

load 'test_helper/harness'

MODEL=Qwen3.8-27B
GATEWAY=http://a1127u31n01.mghpcc.ycrc.yale.edu:8008
EXTRA_BODY='{"chat_template_kwargs":{"enable_thinking":false}}'

setup() {
    harness_setup
    IN_HOUSE_CONF="${INSTALL_DIR}/claude-in-house.conf"
    cp -- "${WRAPPER_DIR}/claude-in-house.conf" "$IN_HOUSE_CONF"
}

# set_in_house LINE: append an assignment to the conf; the last one wins.
set_in_house() {
    printf '%s\n' "$1" >> "$IN_HOUSE_CONF"
}

# setup_conf_with NAME=VALUE: a fresh copy of the shipped conf with NAME's
# assignment replaced by this one.
setup_conf_with() {
    cp -- "${WRAPPER_DIR}/claude-in-house.conf" "$IN_HOUSE_CONF"
    sed -i "/^${1%%=*}=/d" "$IN_HOUSE_CONF"
    set_in_house "$1"
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

@test "in-house: --in-house-model launches against the in-house service" {
    run_wrapper --in-house-model -p hi
    assert_success
    assert_apptainer_called
    assert_env ANTHROPIC_BASE_URL "$GATEWAY"
    [[ "$(claude_args | tail -n 2 | paste -sd ' ')" == "-p hi" ]] || fail "user args not last: $(claude_args)"
    if claude_args | grep -Fxq -- --in-house-model; then
        fail "--in-house-model was passed to Claude"
    fi
}

@test "in-house: without the flag nothing changes, and the conf is not needed" {
    rm -- "$IN_HOUSE_CONF"
    run_wrapper -p hi
    assert_success
    assert_claude_args -p hi
    refute_env ANTHROPIC_BASE_URL
    curl_was_called && fail "the service check ran in the default mode"
    true
}

@test "in-house: after --, --in-house-model is passed to Claude" {
    run_wrapper -- --in-house-model
    assert_success
    assert_claude_args -- --in-house-model
    refute_env ANTHROPIC_BASE_URL
}

@test "in-house: --in-house-model=NAME is reserved" {
    run_wrapper --in-house-model=other
    assert_failure
    assert_output --partial "--in-house-model takes no value"
    refute_apptainer_called
}

# --- Environment --------------------------------------------------------------

@test "in-house: default-session environment" {
    run_wrapper --in-house-model
    assert_success
    assert_env ANTHROPIC_MODEL "$MODEL"
    assert_env ANTHROPIC_DEFAULT_OPUS_MODEL "$MODEL"
    assert_env ANTHROPIC_DEFAULT_OPUS_MODEL_NAME "$MODEL (YCRC in-house)"
    assert_env CLAUDE_CODE_SUBAGENT_MODEL "$MODEL"
    assert_env CLAUDE_CODE_DISABLE_1M_CONTEXT 1
    assert_env CLAUDE_CODE_EXTRA_BODY "$EXTRA_BODY"
    assert_env CLAUDE_CODE_MAX_CONTEXT_TOKENS 262000
    assert_env CLAUDE_CODE_MAX_OUTPUT_TOKENS 16384
    assert_env CLAUDE_CODE_EFFORT_LEVEL medium
    assert_env CLAUDE_CODE_AUTO_MODE_SERVER 0
    assert_env DISABLE_BUG_COMMAND 1
    local name
    for name in ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
                ANTHROPIC_DEFAULT_FABLE_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CONFIG_DIR; do
        refute_env "$name"
        stub_environment "$name" >/dev/null && fail "$name is set in the environment"
    done
    true
}

@test "in-house: reasoning is switched off in --env and in --settings" {
    run_wrapper --in-house-model
    assert_success
    assert_env CLAUDE_CODE_EXTRA_BODY "$EXTRA_BODY"
    settings_jq --arg b "$EXTRA_BODY" '.env.CLAUDE_CODE_EXTRA_BODY == $b' >/dev/null ||
        fail "settings: $(claude_option --settings)"
}

@test "in-house: the credential is <id -un>.claude, from id -un, and not in argv" {
    WRAPPER_ENV=(USER=someone-else)
    run_wrapper --in-house-model
    assert_success
    local expected
    expected="$(id -un).claude"
    [[ "$(stub_environment ANTHROPIC_AUTH_TOKEN)" == "$expected" ]] ||
        fail "ANTHROPIC_AUTH_TOKEN: $(stub_environment ANTHROPIC_AUTH_TOKEN)"
    refute_argv_contains "$expected"
}

@test "in-house: inherited provider settings are removed; the default mode keeps them" {
    WRAPPER_ENV=(
        ANTHROPIC_BASE_URL=http://elsewhere.example:1
        ANTHROPIC_MODEL=claude-elsewhere
        CLAUDE_CODE_USE_BEDROCK=1
        'CLAUDE_CODE_EXTRA_BODY={"chat_template_kwargs":{"enable_thinking":true}}'
        APPTAINERENV_ANTHROPIC_BASE_URL=http://elsewhere.example:2
        SINGULARITYENV_CLAUDE_CODE_USE_VERTEX=1
    )
    local name
    local -a names=(ANTHROPIC_BASE_URL ANTHROPIC_MODEL CLAUDE_CODE_USE_BEDROCK
                    CLAUDE_CODE_EXTRA_BODY APPTAINERENV_ANTHROPIC_BASE_URL
                    SINGULARITYENV_CLAUDE_CODE_USE_VERTEX)

    run_wrapper --in-house-model
    assert_success
    for name in "${names[@]}"; do
        stub_environment "$name" >/dev/null && fail "$name was inherited in in-house mode"
        assert_output --partial "$name"
    done

    run_wrapper
    assert_success
    for name in "${names[@]}"; do
        stub_environment "$name" >/dev/null || fail "$name was removed in the default mode"
    done
}

@test "in-house: an inherited CLAUDE_CONFIG_DIR is kept in both modes" {
    WRAPPER_ENV=(CLAUDE_CONFIG_DIR=/somewhere)
    run_wrapper --in-house-model
    assert_success
    [[ "$(stub_environment CLAUDE_CONFIG_DIR)" == /somewhere ]] || fail "removed in in-house mode"
    run_wrapper
    [[ "$(stub_environment CLAUDE_CONFIG_DIR)" == /somewhere ]] || fail "removed in the default mode"
}

# --- Claude options -----------------------------------------------------------

@test "in-house: --settings and --append-system-prompt come before --add-dir and the user's args" {
    mkdir -p "${SANDBOX}/data"
    run_wrapper --in-house-model --bind="${SANDBOX}/data" -p hi
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

@test "in-house: --settings routes, restricts the model choice, and denies WebSearch" {
    run_wrapper --in-house-model
    assert_success
    local filter
    for filter in \
        ".env.ANTHROPIC_BASE_URL == \"$GATEWAY\"" \
        ".env.ANTHROPIC_MODEL == \"$MODEL\"" \
        ".env.ANTHROPIC_DEFAULT_OPUS_MODEL == \"$MODEL\"" \
        ".env.CLAUDE_CODE_EFFORT_LEVEL == \"medium\"" \
        '.env.CLAUDE_CODE_USE_BEDROCK == "0" and .env.CLAUDE_CODE_USE_VERTEX == "0" and .env.CLAUDE_CODE_USE_FOUNDRY == "0"' \
        ".availableModels == [\"$MODEL\"]" \
        ".modelPicker.options == [{\"model\": \"$MODEL\", \"label\": \"$MODEL (YCRC in-house)\"}]" \
        '.modelPicker.replaceBuiltInOptions == true' \
        '.permissions.deny == ["WebSearch"]'; do
        settings_jq "$filter" >/dev/null || fail "settings fail [$filter]: $(claude_option --settings)"
    done
}

@test "in-house: the system-prompt note names the model and the shared sessions" {
    run_wrapper --in-house-model
    assert_success
    local note
    note="$(claude_option --append-system-prompt)"
    [[ "$note" == *"$MODEL"* && "$note" == *YCRC* && "$note" == *"--in-house-model"* ]] ||
        fail "note: $note"
}

@test "in-house: the in-house model, default, --resume and --continue pass through" {
    local -a case_args
    local spec
    for spec in "--model $MODEL" "--model=$MODEL" "--model default" "--model=default" \
                "--resume abc123" "--continue"; do
        read -r -a case_args <<< "$spec"
        run_wrapper --in-house-model "${case_args[@]}" -p hi
        assert_success
        [[ "$(claude_args | tail -n $(( ${#case_args[@]} + 2 )) | paste -sd ' ')" == "$spec -p hi" ]] ||
            fail "[$spec] claude args: $(claude_args)"
    done
}

@test "in-house: the banner is on stderr and mentions shared sessions" {
    run_wrapper --separate-stderr --in-house-model
    assert_success
    assert_output ""
    [[ "$stderr" == *"In-house mode: $MODEL hosted by YCRC"* ]] || fail "no banner: $stderr"
    [[ "$stderr" == *"shared with your normal Claude"* ]] || fail "no shared-state note: $stderr"
}

# --- Shared state -------------------------------------------------------------

@test "in-house: Claude state is bound exactly as in the default mode" {
    set_conf bind 'binds=("$HOME/.claude:rw" "$HOME/.local/share/claude:rw")'
    : > "${TEST_HOME}/.claude.json"
    run_wrapper
    assert_success
    local default_binds
    default_binds="$(apptainer_binds)"
    run_wrapper --in-house-model
    assert_success
    [[ "$(apptainer_binds)" == "$default_binds" ]] ||
        fail "binds differ:"$'\n'"default:"$'\n'"$default_binds"$'\n'"in-house:"$'\n'"$(apptainer_binds)"
    assert_bind "${TEST_HOME}/.claude:${TEST_HOME}/.claude:rw"
    assert_bind "${TEST_HOME}/.claude.json:${TEST_HOME}/.claude.json"
}

@test "in-house: no separate state is created" {
    run_wrapper --in-house-model
    assert_success
    if compgen -G "${TEST_HOME}/.claude-in-house*" >/dev/null; then
        fail "separate state was created: $(ls -a "$TEST_HOME")"
    fi
}

# --- Errors -------------------------------------------------------------------

@test "in-house: other clusters are refused before any network check" {
    WRAPPER_ENV=(CLUSTER=mccleary)
    run_wrapper --in-house-model
    assert_failure
    assert_output --partial "only available on: bouchet"
    refute_apptainer_called
    curl_was_called && fail "the service was contacted"
    true
}

@test "in-house: each service failure has its own message" {
    local -a cases=(
        "down|isn't reachable right now"
        "502|its model server isn't responding"
        "401|returned HTTP 401"
        "nomodel|doesn't offer $MODEL"
    )
    local entry
    for entry in "${cases[@]}"; do
        STUB_SERVICE="${entry%%|*}" run_wrapper --in-house-model
        assert_failure
        assert_output --partial "${entry#*|}"
        assert_output --partial "research.computing@yale.edu"
        refute_apptainer_called
    done
    STUB_SERVICE=down run_wrapper --in-house-model
    assert_output --partial "a1127u31n01.mghpcc.ycrc.yale.edu:8008"
}

@test "in-house: the service check is a GET of /v1/models with the user's credential" {
    run_wrapper --in-house-model
    assert_success
    curl_argv_contains "${GATEWAY}/v1/models"
    curl_argv_contains "Authorization: Bearer $(id -un).claude"
    if tr '\0' '\n' < "${STUB_LOG_DIR}/curl.argv" | grep -Eqx -- '-X|--request|-d|--data.*'; then
        fail "the check is not a plain GET: $(tr '\0' ' ' < "${STUB_LOG_DIR}/curl.argv")"
    fi
}

@test "in-house: the service check runs after the local checks" {
    WORK_DIR="$TEST_HOME"
    STUB_SERVICE=down run_wrapper --in-house-model
    assert_failure
    assert_output --partial "non-hidden subdirectory"
    curl_was_called && fail "the service was contacted before the local checks"
    true
}

@test "in-house: a missing curl is reported plainly" {
    # A PATH with the stubs and the tools the wrapper needs, but no curl.
    local bin="${SANDBOX}/nocurl" tool
    mkdir -p "$bin"
    for tool in bash dirname realpath mkdir id sort; do
        ln -s "$(command -v "$tool")" "${bin}/${tool}"
    done
    cp -- "${STUB_DIR}/apptainer" "${STUB_DIR}/hostname" "${STUB_DIR}/groups" "$bin/"
    WRAPPER_ENV=("PATH=${bin}")
    run_wrapper --in-house-model
    assert_failure
    assert_output --partial "needs curl"
    refute_apptainer_called
    # The default mode does not need curl.
    run_wrapper
    assert_success
}

@test "in-house: a missing conf stops in-house mode only" {
    rm -- "$IN_HOUSE_CONF"
    run_wrapper --in-house-model
    assert_failure
    assert_output --partial "in-house configuration not found"
    refute_apptainer_called
    run_wrapper
    assert_success
}

@test "in-house: effort levels the server rejects are refused" {
    local effort
    for effort in high max HIGH ''; do
        setup_conf_with "in_house_effort='$effort'"
        run_wrapper --in-house-model
        assert_failure
        assert_output --partial "in_house_effort"
        refute_apptainer_called
    done
    for effort in xhigh medium low; do
        setup_conf_with "in_house_effort='$effort'"
        run_wrapper --in-house-model
        assert_success
        assert_env CLAUDE_CODE_EFFORT_LEVEL "$effort"
    done
}


@test "in-house: malformed conf values are refused" {
    local line
    for line in \
        "in_house_agent_label='claude mod'" \
        "in_house_agent_label='a.b'" \
        "in_house_base_url='ftp://host:1'" \
        "in_house_base_url='http://host:1/v1?x=1'" \
        "in_house_model='Qwen 3'" \
        "in_house_model='a\"b'" \
        "in_house_max_output='0'" \
        "in_house_max_context='12k'" \
        "in_house_clusters=()" \
        "in_house_clusters='bouchet'"; do
        setup_conf_with "$line"
        run_wrapper --in-house-model
        assert_failure
        refute_apptainer_called
        curl_was_called && fail "[$line] the service was contacted"
    done
    true
}

@test "in-house: an inherited variable cannot fill a gap in the conf" {
    sed -i '/^in_house_base_url=/d' "$IN_HOUSE_CONF"
    WRAPPER_ENV=(in_house_base_url=http://elsewhere.example:1)
    run_wrapper --in-house-model
    assert_failure
    assert_output --partial "in_house_base_url"
    curl_was_called && fail "the service was contacted"
    true
}

@test "in-house: other models, --fallback-model and a user --settings are refused" {
    local -a case_args
    local spec
    for spec in "--model ${MODEL}-think" "--model opus" "--model=sonnet" \
                "--model claude-sonnet-5" "--fallback-model x" "--fallback-model=x" \
                "--settings {}" "--settings=/some/file.json"; do
        read -r -a case_args <<< "$spec"
        run_wrapper --in-house-model "${case_args[@]}"
        assert_failure
        refute_apptainer_called
    done
    run_wrapper --model opus --in-house-model
    assert_failure
    assert_output --partial "start claude without --in-house-model"
    run_wrapper --in-house-model --settings '{}'
    # shellcheck disable=SC2088  # the message names the path literally
    assert_output --partial "~/.claude/settings.json"
    # The default mode passes them on untouched.
    run_wrapper --model opus --fallback-model sonnet --settings '{}'
    assert_success
    assert_claude_args --model opus --fallback-model sonnet --settings '{}'
}

@test "in-house: --ycrc-help describes --in-house-model" {
    run_wrapper --ycrc-help
    assert_success
    assert_output --partial "--in-house-model"
    assert_output --partial "YCRC's in-house model"
    assert_output --partial "Bouchet only"
}
