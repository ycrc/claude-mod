#!/usr/bin/env bats
# Tests for `claude --bind`: user-requested binds, read-only by default.
# SC2016: config fixtures are single-quoted on purpose; the wrapper expands $HOME.
# SC2030/SC2031/SC2034: tests set variables (WORK_DIR, ...) the harness reads.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

load 'test_helper/harness'

setup() {
    harness_setup
    DATA="${SANDBOX}/data"
    mkdir -p "$DATA"
}

# assert_add_dir PATH: Claude received --add-dir=PATH.
assert_add_dir() {
    claude_args | grep -Fxq -- "--add-dir=$1" ||
        fail "missing --add-dir=$1"$'\n'"claude args:"$'\n'"$(claude_args)"
}

# Index of the --bind whose spec is $1, or -1.
bind_index() {
    local i
    load_apptainer_argv
    for (( i = 0; i < ${#APPTAINER_ARGV[@]}; i++ )); do
        if [[ "${APPTAINER_ARGV[i]}" == --bind && "${APPTAINER_ARGV[i + 1]}" == "$1" ]]; then
            echo "$i"
            return
        fi
    done
    echo -1
}

# --- Accepted -----------------------------------------------------------------

@test "bind: --bind=DIR binds read-only, adds --add-dir, reports it" {
    run_wrapper --separate-stderr --bind="$DATA" -p hi
    assert_success
    assert_bind "${DATA}:${DATA}:ro"
    assert_claude_args "--add-dir=${DATA}" -p hi
    [[ "$stderr" == *"Binding read-only: ${DATA}"* ]] || fail "no summary: $stderr"
}

@test "bind: --bind DIR:rw binds read-write" {
    run_wrapper --separate-stderr --bind "${DATA}:rw"
    assert_success
    assert_bind "${DATA}:${DATA}:rw"
    [[ "$stderr" == *"Binding read-write: ${DATA}"* ]] || fail "no summary: $stderr"
}

@test "bind: -B DIR works like --bind" {
    run_wrapper -B "$DATA"
    assert_success
    assert_bind "${DATA}:${DATA}:ro"
}

@test "bind: a comma-separated list sets modes per element" {
    mkdir -p "${SANDBOX}/other"
    run_wrapper --bind="${DATA},${SANDBOX}/other:rw"
    assert_success
    assert_bind "${DATA}:${DATA}:ro"
    assert_bind "${SANDBOX}/other:${SANDBOX}/other:rw"
    assert_add_dir "$DATA"
    assert_add_dir "${SANDBOX}/other"
}

@test "bind: repeated flags all apply" {
    mkdir -p "${SANDBOX}/other"
    run_wrapper --bind="$DATA" -B "${SANDBOX}/other"
    assert_success
    assert_bind "${DATA}:${DATA}:ro"
    assert_bind "${SANDBOX}/other:${SANDBOX}/other:ro"
}

@test "bind: a leading ~ means the home directory" {
    mkdir -p "${TEST_HOME}/data"
    run_wrapper '--bind=~/data'
    assert_success
    assert_bind "${TEST_HOME}/data:${TEST_HOME}/data:ro"
}

@test "bind: a relative path is resolved from the launch directory" {
    mkdir -p "${TEST_HOME}/data"
    run_wrapper --bind=../data
    assert_success
    assert_bind "${TEST_HOME}/data:${TEST_HOME}/data:ro"
}

@test "bind: a symlinked directory is bound at both paths" {
    ln -s "$DATA" "${TEST_HOME}/link"
    run_wrapper --bind="${TEST_HOME}/link"
    assert_success
    assert_bind "${DATA}:${TEST_HOME}/link:ro"
    assert_bind "${DATA}:${DATA}:ro"
    assert_add_dir "${TEST_HOME}/link"
    assert_add_dir "$DATA"
}

@test "bind: an ancestor of the work dir is mounted before the work dir" {
    mkdir -p "${TEST_HOME}/group/proj"
    WORK_DIR="${TEST_HOME}/group/proj"
    run_wrapper --bind="${TEST_HOME}/group"
    assert_success
    local parent work
    parent="$(bind_index "${TEST_HOME}/group:${TEST_HOME}/group:ro")"
    work="$(bind_index "${WORK_DIR}:${WORK_DIR}")"
    (( parent >= 0 && work > parent )) || fail "order: parent at $parent, work dir at $work"
}

# --- Skipped with a note ------------------------------------------------------

@test "bind: --bind=. is skipped; the work dir stays read-write" {
    run_wrapper --separate-stderr --bind=.
    assert_success
    refute_bind "${WORK_DIR}:${WORK_DIR}:ro"
    assert_bind "${WORK_DIR}:${WORK_DIR}"
    [[ "$stderr" == *"already available"* ]] || fail "no note: $stderr"
    assert_claude_args
}

@test "bind: a work-dir subfolder, even a hidden one, is skipped" {
    mkdir -p "${WORK_DIR}/sub" "${WORK_DIR}/.venv"
    run_wrapper --bind=sub,.venv
    assert_success
    refute_bind_matching '/proj/(sub|\.venv)'
    assert_output --partial "already available"
}

@test "bind: a directory inside an admin bind is skipped" {
    mkdir -p "${TEST_HOME}/shared/x"
    set_conf bind 'binds=("$HOME/shared:ro")'
    run_wrapper --bind="${TEST_HOME}/shared/x:rw"
    assert_success
    refute_bind "${TEST_HOME}/shared/x:${TEST_HOME}/shared/x:rw"
    assert_output --partial "already available"
}

@test "bind: an admin-bound system path is skipped, not blocked" {
    set_conf bind 'binds=("/var/tmp")'
    run_wrapper --bind=/var/tmp
    assert_success
    assert_output --partial "already available"
}

# --- Errors -------------------------------------------------------------------

@test "bind: a missing path is an error" {
    run_wrapper --bind="${SANDBOX}/missing"
    assert_failure
    refute_apptainer_called
}

@test "bind: a regular file is an error" {
    : > "${SANDBOX}/file"
    run_wrapper --bind="${SANDBOX}/file"
    assert_failure
    assert_output --partial "not a directory"
}

@test "bind: an unreadable directory is an error" {
    if [[ "$(id -u)" == 0 ]]; then
        skip "root can read anywhere"
    fi
    chmod 0000 "$DATA"
    run_wrapper --bind="$DATA"
    assert_failure
    assert_output --partial "read"
}

@test "bind: / and container system directories are refused" {
    local path
    for path in / /etc /usr/lib; do
        run_wrapper --bind="$path"
        assert_failure
        assert_output --partial "system directory"
        refute_apptainer_called
    done
}

@test "bind: the home directory, or a directory containing it, is refused" {
    local path
    for path in "$TEST_HOME" "$SANDBOX"; do
        run_wrapper --bind="$path"
        assert_failure
        assert_output --partial "home directory"
    done
}

@test "bind: hidden paths are refused" {
    mkdir -p "${TEST_HOME}/.ssh" "${TEST_HOME}/data/.venv" "${TEST_HOME}/.secret"
    ln -s "${TEST_HOME}/.secret" "${TEST_HOME}/visible"
    local path
    for path in "${TEST_HOME}/.ssh" "${TEST_HOME}/data/.venv" "${TEST_HOME}/visible"; do
        run_wrapper --bind="$path"
        assert_failure
        assert_output --partial "hidden"
    done
}

@test "bind: an excluded directory, or one containing it, is refused" {
    mkdir -p "${TEST_HOME}/stuff/ondemand"
    set_conf exclude 'excluded_workdirs=("$HOME/stuff/ondemand")'
    local path
    for path in "${TEST_HOME}/stuff/ondemand" "${TEST_HOME}/stuff"; do
        run_wrapper --bind="$path"
        assert_failure
        assert_output --partial "excluded"
    done
}

@test "bind: a custom destination or an unknown mode is refused" {
    run_wrapper --bind="${DATA}:/elsewhere"
    assert_failure
    assert_output --partial "custom container destinations are not supported"
    run_wrapper --bind="${DATA}:xx"
    assert_failure
    assert_output --partial "custom container destinations are not supported"
}

@test "bind: --bind with no value is an error" {
    run_wrapper --bind
    assert_failure
    assert_output --partial "--bind requires a directory"
    run_wrapper --bind=
    assert_failure
}

# --- Pass-through -------------------------------------------------------------

@test "bind: after --, --bind is passed to Claude untouched" {
    run_wrapper -- --bind=x
    assert_success
    assert_claude_args -- --bind=x
}

@test "bind: --ycrc-help lists --bind" {
    run_wrapper --ycrc-help
    assert_success
    assert_output --partial "--bind"
}
