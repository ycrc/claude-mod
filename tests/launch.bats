#!/usr/bin/env bats
# Characterization tests: record the wrapper's launch behavior so the refactor
# and later features can be checked against it. Must pass unedited before and
# after the refactor. Bind order is ignored and messages match on substrings.

# SC2016: config fixtures are single-quoted on purpose; the wrapper expands $HOME.
# SC2030/SC2031/SC2034: each @test runs in a subshell and sets variables
# (WORK_DIR, WRAPPER_ENV, ...) that the harness reads.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

load 'test_helper/harness'

# --- Host / environment ------------------------------------------------------

@test "launch: default launch runs apptainer with the work dir" {
    run_wrapper
    assert_success
    assert_apptainer_called
    load_apptainer_argv
    assert_equal "${APPTAINER_ARGV[0]}" run
    assert_equal "$(apptainer_pwd)" "$(resolved "$WORK_DIR")"
    assert_bind "$(resolved "$WORK_DIR"):$(resolved "$WORK_DIR")"
    [[ " ${APPTAINER_ARGV[*]} " == *" --contain "* ]] || fail "missing --contain"
}

@test "launch: login node is rejected" {
    STUB_HOSTNAME=login1 run_wrapper
    assert_failure
    assert_output --partial "login node"
    refute_apptainer_called
}

@test "launch: login node match is case-insensitive" {
    STUB_HOSTNAME=LOGIN2 run_wrapper
    assert_failure
    assert_output --partial "login node"
}

@test "launch: hostname failure stops the launch" {
    STUB_HOSTNAME_FAIL=1 run_wrapper
    assert_failure
    assert_output --partial "cannot determine the current hostname"
}

@test "launch: CLUSTER unset is an error" {
    WRAPPER_ENV_UNSET=(CLUSTER)
    run_wrapper
    assert_failure
    assert_output --partial "CLUSTER is not set"
}

@test "launch: unsupported CLUSTER is an error" {
    WRAPPER_ENV=(CLUSTER=nowhere)
    run_wrapper
    assert_failure
    assert_output --partial "unsupported cluster"
}

@test "launch: HOME unset is an error" {
    WRAPPER_ENV_UNSET=(HOME)
    run_wrapper
    assert_failure
    assert_output --partial "HOME is not set"
}

@test "launch: USER unset still launches" {
    WRAPPER_ENV_UNSET=(USER)
    run_wrapper
    assert_success
    assert_apptainer_called
}

# --- Configuration files ------------------------------------------------------

@test "config: each missing configuration file is named in the error" {
    local name
    for name in env bind path exclude; do
        harness_teardown
        harness_setup
        rm -f -- "${INSTALL_DIR}/claude-${name}.conf"
        run_wrapper
        assert_failure
        assert_output --partial "claude-${name}.conf"
        refute_apptainer_called
    done
}

@test "config: a config that removes the array is rejected" {
    set_conf bind 'unset binds'
    run_wrapper
    assert_failure
    assert_output --partial "must define an indexed array named binds"
}

@test "config: a scalar assignment becomes a one-entry array" {
    # The array is reset before sourcing, so binds="x" sets element 0.
    mkdir -p "${TEST_HOME}/a"
    set_conf bind 'binds="$HOME/a:ro"'
    run_wrapper
    assert_success
    assert_bind "${TEST_HOME}/a:${TEST_HOME}/a:ro"
}

@test "config: an inherited binds variable never becomes a bind" {
    # Current behavior: an exported "binds" keeps its export attribute, so the
    # array check fails and the launch stops. Either way /etc must not be bound.
    set_conf bind '# defines nothing'
    WRAPPER_ENV=(binds=/etc)
    run_wrapper
    refute_bind_matching '^/etc'
}

# --- Environment scrubbing ----------------------------------------------------

@test "env scrub: a matching variable is removed and named, value never printed" {
    WRAPPER_ENV=(MY_TOKEN=supersecretvalue)
    run_wrapper
    assert_success
    assert_output --partial "MY_TOKEN"
    refute_output --partial "supersecretvalue"
    run stub_environment MY_TOKEN
    assert_failure
}

@test "env scrub: a non-matching variable is kept" {
    WRAPPER_ENV=(PLAIN_SETTING=kept)
    run_wrapper
    assert_success
    run stub_environment PLAIN_SETTING
    assert_success
    assert_output kept
}

@test "env scrub: an empty pattern is rejected" {
    set_conf env "sensitive_env_patterns=('')"
    run_wrapper
    assert_failure
    assert_output --partial "empty environment-variable pattern"
}

@test "env scrub: a pattern matching HOME is rejected" {
    set_conf env "sensitive_env_patterns=('HO*')"
    run_wrapper
    assert_failure
    assert_output --partial "matches required variable HOME"
}

@test "env scrub: a pattern matching PATH is rejected" {
    set_conf env "sensitive_env_patterns=('P*TH')"
    run_wrapper
    assert_failure
    assert_output --partial "matches required variable PATH"
}

# --- Claude state -------------------------------------------------------------

@test "state: ~/.claude and ~/.local/share/claude are created" {
    run_wrapper
    assert_success
    [[ -d "${TEST_HOME}/.claude" ]] || fail "\$HOME/.claude missing"
    [[ -d "${TEST_HOME}/.local/share/claude" ]] || fail "\$HOME/.local/share/claude missing"
}

@test "state: ~/.claude.json is not bound when absent" {
    run_wrapper
    assert_success
    refute_bind_matching '\.claude\.json'
}

@test "state: ~/.claude.json is bound when present" {
    echo '{}' > "${TEST_HOME}/.claude.json"
    run_wrapper
    assert_success
    assert_bind "${TEST_HOME}/.claude.json:${TEST_HOME}/.claude.json"
}

@test "state: shipped configs bind ~/.claude and ~/.local/share/claude read-write" {
    use_shipped_configs
    run_wrapper
    assert_success
    assert_bind "${TEST_HOME}/.claude:${TEST_HOME}/.claude:rw"
    assert_bind "${TEST_HOME}/.local/share/claude:${TEST_HOME}/.local/share/claude:rw"
}

# --- Admin binds --------------------------------------------------------------

@test "admin binds: no suffix, :ro and :rw produce matching specs" {
    mkdir -p "${TEST_HOME}/a" "${TEST_HOME}/b" "${TEST_HOME}/c"
    set_conf bind 'binds=("$HOME/a" "$HOME/b:ro" "$HOME/c:rw")'
    run_wrapper
    assert_success
    assert_bind "${TEST_HOME}/a:${TEST_HOME}/a"
    assert_bind "${TEST_HOME}/b:${TEST_HOME}/b:ro"
    assert_bind "${TEST_HOME}/c:${TEST_HOME}/c:rw"
}

@test "admin binds: an invalid mode is rejected" {
    mkdir -p "${TEST_HOME}/a"
    set_conf bind 'binds=("$HOME/a:xx")'
    run_wrapper
    assert_failure
    assert_output --partial "invalid bind mode"
}

@test "admin binds: a relative path is rejected" {
    set_conf bind 'binds=("relative/dir")'
    run_wrapper
    assert_failure
    assert_output --partial "absolute directory other than /"
}

@test "admin binds: / is rejected" {
    set_conf bind 'binds=("/")'
    run_wrapper
    assert_failure
    assert_output --partial "absolute directory other than /"
}

@test "admin binds: a comma is rejected" {
    set_conf bind 'binds=("$HOME/a,b")'
    run_wrapper
    assert_failure
    assert_output --partial "cannot contain ','"
}

@test "admin binds: a missing path is skipped" {
    set_conf bind 'binds=("$HOME/missing")'
    run_wrapper
    assert_success
    refute_bind_matching 'missing'
}

@test "admin binds: a regular file is rejected" {
    : > "${TEST_HOME}/file"
    set_conf bind 'binds=("$HOME/file")'
    run_wrapper
    assert_failure
    assert_output --partial "not a directory"
}

@test "admin binds: a symlinked entry gets logical and physical binds" {
    mkdir -p "${SANDBOX}/real"
    ln -s "${SANDBOX}/real" "${TEST_HOME}/link"
    set_conf bind 'binds=("$HOME/link:ro")'
    run_wrapper
    assert_success
    assert_bind "${SANDBOX}/real:${TEST_HOME}/link:ro"
    assert_bind "${SANDBOX}/real:${SANDBOX}/real:ro"
}

# --- Container PATH -----------------------------------------------------------

@test "path: a covered entry becomes PREPEND_PATH" {
    mkdir -p "${TEST_HOME}/tools/bin"
    set_conf bind 'binds=("$HOME/tools:ro")'
    set_conf path 'path_entries=("$HOME/tools/bin")'
    run_wrapper
    assert_success
    assert_equal "$(apptainer_prepend_path)" "${TEST_HOME}/tools/bin"
}

@test "path: an uncovered entry is rejected" {
    mkdir -p "${TEST_HOME}/tools/bin"
    set_conf path 'path_entries=("$HOME/tools/bin")'
    run_wrapper
    assert_failure
    assert_output --partial "not covered by a configured bind"
}

@test "path: a missing entry is skipped and no --env is passed" {
    set_conf path 'path_entries=("$HOME/missing/bin")'
    run_wrapper
    assert_success
    assert_equal "$(apptainer_env_opts)" ""
}

@test "path: duplicates and trailing slashes are removed" {
    mkdir -p "${TEST_HOME}/tools/bin"
    set_conf bind 'binds=("$HOME/tools:ro")'
    set_conf path 'path_entries=("$HOME/tools/bin/" "$HOME/tools/bin")'
    run_wrapper
    assert_success
    assert_equal "$(apptainer_prepend_path)" "${TEST_HOME}/tools/bin"
}

@test "path: ':' or ',' is rejected" {
    set_conf path 'path_entries=("$HOME/a:b")'
    run_wrapper
    assert_failure
    assert_output --partial "cannot contain ':' or ','"
}

@test "path: no entries means no --env" {
    run_wrapper
    assert_success
    assert_equal "$(apptainer_env_opts)" ""
}

# --- Exclusions ---------------------------------------------------------------

@test "exclude: a missing excluded path gives a warning" {
    set_conf exclude 'excluded_workdirs=("$HOME/ondemand")'
    run_wrapper
    assert_success
    assert_output --partial "skipping missing excluded path"
}

@test "exclude: a regular file is rejected" {
    : > "${TEST_HOME}/ondemand"
    set_conf exclude 'excluded_workdirs=("$HOME/ondemand")'
    run_wrapper
    assert_failure
    assert_output --partial "excluded path is not a directory"
}

@test "exclude: a work dir inside an excluded dir is rejected" {
    mkdir -p "${TEST_HOME}/ondemand/proj"
    set_conf exclude 'excluded_workdirs=("$HOME/ondemand")'
    WORK_DIR="${TEST_HOME}/ondemand/proj"
    run_wrapper
    assert_failure
    assert_output --partial "administratively restricted"
}

# --- Working directory --------------------------------------------------------

@test "work dir: \$HOME itself is rejected" {
    WORK_DIR="$TEST_HOME"
    run_wrapper
    assert_failure
    assert_output --partial "non-hidden subdirectory"
}

@test "work dir: a hidden component is rejected" {
    mkdir -p "${TEST_HOME}/.hidden/proj"
    WORK_DIR="${TEST_HOME}/.hidden/proj"
    run_wrapper
    assert_failure
    assert_output --partial "non-hidden subdirectory"
}

@test "work dir: a directory inside an admin bind is rejected" {
    mkdir -p "${TEST_HOME}/data/proj"
    set_conf bind 'binds=("$HOME/data:ro")'
    WORK_DIR="${TEST_HOME}/data/proj"
    run_wrapper
    assert_failure
    assert_output --partial "administratively restricted"
}

@test "work dir: an unwritable directory is rejected" {
    if [[ "$(id -u)" == 0 ]]; then
        skip "root can write anywhere"
    fi
    chmod 0555 "$WORK_DIR"
    run_wrapper
    assert_failure
    assert_output --partial "readable, writable, and searchable"
}

@test "work dir: a directory outside all allowed roots is rejected" {
    mkdir -p "${SANDBOX}/elsewhere/proj"
    WORK_DIR="${SANDBOX}/elsewhere/proj"
    run_wrapper
    assert_failure
    assert_output --partial "non-hidden subdirectory"
}

@test "work dir: entered through a symlink, the resolved path is used" {
    ln -s "$WORK_DIR" "${TEST_HOME}/link"
    WORK_DIR="${TEST_HOME}/link"
    run_wrapper
    assert_success
    assert_equal "$(apptainer_pwd)" "${TEST_HOME}/proj"
    assert_bind "${TEST_HOME}/proj:${TEST_HOME}/proj"
}

# --- Launch -------------------------------------------------------------------

@test "launch: missing apptainer is an error" {
    if [[ -x /usr/bin/apptainer || -x /bin/apptainer ]]; then
        skip "a system apptainer is installed"
    fi
    rm -f -- "${STUB_DIR}/apptainer"
    run_wrapper
    assert_failure
    assert_output --partial "apptainer is not available"
}

@test "launch: missing SIF is an error" {
    rm -f -- "$IMAGE"
    run_wrapper
    assert_failure
    assert_output --partial "container not found"
}

@test "launch: arguments after the image are passed through verbatim" {
    run_wrapper -p "hello world" "" -- --resume
    assert_success
    assert_claude_args -p "hello world" "" -- --resume
}

@test "launch: --nv is present exactly when NVIDIA devices exist" {
    run_wrapper
    assert_success
    load_apptainer_argv
    local has_nv=false
    [[ " ${APPTAINER_ARGV[*]} " == *" --nv "* ]] && has_nv=true
    if [[ -c /dev/nvidiactl ]] && compgen -G '/dev/nvidia[0-9]*' >/dev/null; then
        assert_equal "$has_nv" true
    else
        assert_equal "$has_nv" false
    fi
}
