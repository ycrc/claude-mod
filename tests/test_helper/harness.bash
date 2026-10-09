# shellcheck shell=bash
# Test harness for eb/claude-wrapper.sh.
#
# Each test gets a sandbox containing an EasyBuild-like install directory (the
# wrapper, its functions file, fixture .conf files and an empty SIF), a fake
# home directory, and stub commands (apptainer, hostname, groups, curl) that
# come first on PATH. The wrapper is run under `env -i`, so results do not
# depend on the caller's environment. See tests/README.md for requirements.

bats_require_minimum_version 1.7.0

if [[ -z "${BATS_LIB_PATH:-}" ]]; then
    echo "BATS_LIB_PATH is not set; see tests/README.md (or run 'pixi run test' from the workspace)." >&2
    exit 1
fi
bats_load_library bats-support
bats_load_library bats-assert

REPO_DIR="$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)"
# Directory holding the wrapper under test; point it at another checkout to compare versions.
WRAPPER_DIR="${WRAPPER_DIR:-${REPO_DIR}/eb}"

# --- Sandbox ----------------------------------------------------------------

setup() {
    harness_setup
}

teardown() {
    harness_teardown
}

# Create the sandbox, install dir, fake home, default fixture configs and stubs.
harness_setup() {
    local root="${CLAUDE_WRAPPER_TEST_TMPDIR:-}"
    if [[ -z "$root" ]]; then
        echo "CLAUDE_WRAPPER_TEST_TMPDIR is not set; see tests/README.md." >&2
        return 1
    fi
    mkdir -p -- "$root"
    root="$(realpath -e -- "$root")"
    # The shipped config binds /tmp, and the wrapper rejects hidden path components.
    if [[ "$root" == /tmp || "$root" == /tmp/* || "$root" == /var/tmp/* || "$root" == */.* ]]; then
        echo "CLAUDE_WRAPPER_TEST_TMPDIR must not be under /tmp or contain hidden components: $root" >&2
        return 1
    fi

    SANDBOX="$(mktemp -d "${root}/t.XXXXXX")"
    INSTALL_DIR="${SANDBOX}/install"
    STUB_DIR="${SANDBOX}/stubs"
    STUB_LOG_DIR="${SANDBOX}/log"
    TEST_HOME="${SANDBOX}/home"
    WORK_DIR="${TEST_HOME}/proj"
    IMAGE="${INSTALL_DIR}/claude-mod.sif"
    WRAPPER="${INSTALL_DIR}/claude"
    mkdir -p -- "$INSTALL_DIR" "$STUB_DIR" "$STUB_LOG_DIR" "$WORK_DIR"

    # Mirror the EasyBuild layout: the wrapper is installed as "claude".
    cp -- "${WRAPPER_DIR}/claude-wrapper.sh" "$WRAPPER"
    chmod 0755 -- "$WRAPPER"
    if [[ -f "${WRAPPER_DIR}/claude-wrapper-functions.sh" ]]; then
        cp -- "${WRAPPER_DIR}/claude-wrapper-functions.sh" "$INSTALL_DIR/"
    fi
    : > "$IMAGE"

    # Minimal valid fixtures; tests overwrite them with set_conf.
    set_conf env "sensitive_env_patterns=('*TOKEN*')"
    set_conf bind "binds=()"
    set_conf path "path_entries=()"
    set_conf exclude "excluded_workdirs=()"

    write_stubs
    WRAPPER_ENV=()
    WRAPPER_ENV_UNSET=()
}

harness_teardown() {
    if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then
        chmod -R u+rwx -- "$SANDBOX" 2>/dev/null || true
        rm -rf -- "$SANDBOX"
    fi
}

# set_conf NAME CONTENT: write claude-NAME.conf in the install dir.
set_conf() {
    printf '%s\n' "$2" > "${INSTALL_DIR}/claude-$1.conf"
}

# Copy the shipped .conf files from the wrapper directory.
use_shipped_configs() {
    local conf
    for conf in "${WRAPPER_DIR}"/claude-*.conf; do
        cp -- "$conf" "$INSTALL_DIR/"
    done
}

# Stub commands. They record into STUB_LOG_DIR, which run_wrapper passes through.
write_stubs() {
    cat > "${STUB_DIR}/apptainer" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" > "${STUB_LOG_DIR}/apptainer.argv"
env -0 > "${STUB_LOG_DIR}/apptainer.env"
exit 0
EOF
    cat > "${STUB_DIR}/hostname" <<'EOF'
#!/bin/bash
[[ "${STUB_HOSTNAME_FAIL:-0}" == 1 ]] && exit 1
echo "${STUB_HOSTNAME:-c1n01}"
EOF
    cat > "${STUB_DIR}/groups" <<'EOF'
#!/bin/bash
echo "${STUB_GROUPS:-}"
EOF
    # The in-house service check. STUB_SERVICE: ok (default), down (connection
    # fails), nomodel (200 without the model), or an HTTP status such as 502.
    cat > "${STUB_DIR}/curl" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" > "${STUB_LOG_DIR}/curl.argv"
format=""
while (( $# > 0 )); do
    [[ "$1" == -w ]] && { format="$2"; shift; }
    shift
done
case "${STUB_SERVICE:-ok}" in
    ok) body='{"object":"list","data":[{"id":"Qwen3.8-27B"},{"id":"Qwen3.8-27B-think"}]}'; code=200 ;;
    nomodel) body='{"object":"list","data":[{"id":"Qwen3.8-27B-think"}]}'; code=200 ;;
    down) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
    *) body='{"error":"stub"}'; code="$STUB_SERVICE" ;;
esac
printf '%s' "$body"
printf '%b' "${format//%\{http_code\}/$code}"
EOF
    chmod 0755 -- "${STUB_DIR}"/*
}

# --- Running the wrapper ----------------------------------------------------

# run_wrapper [--separate-stderr] [ARGS...]
# Runs the installed wrapper from $WORK_DIR under `env -i` via bats' run.
# Extra variables: WRAPPER_ENV=(NAME=value ...). Variables to drop: WRAPPER_ENV_UNSET=(NAME ...).
run_wrapper() {
    local -a run_opts=()
    if [[ "${1:-}" == --separate-stderr ]]; then
        run_opts+=(--separate-stderr)
        shift
    fi

    local -a candidate=(
        "HOME=${TEST_HOME}"
        "USER=tester"
        "CLUSTER=bouchet"
        "PATH=${STUB_DIR}:/usr/bin:/bin"
        "STUB_LOG_DIR=${STUB_LOG_DIR}"
    )
    local name
    for name in STUB_HOSTNAME STUB_HOSTNAME_FAIL STUB_GROUPS STUB_SERVICE; do
        if [[ -n "${!name+x}" ]]; then
            candidate+=("${name}=${!name}")
        fi
    done
    candidate+=("${WRAPPER_ENV[@]}")

    local -a envs=()
    local entry skip unset_name
    for entry in "${candidate[@]}"; do
        skip=false
        for unset_name in "${WRAPPER_ENV_UNSET[@]}"; do
            [[ "${entry%%=*}" == "$unset_name" ]] && skip=true
        done
        [[ "$skip" == true ]] || envs+=("$entry")
    done

    rm -f -- "${STUB_LOG_DIR}"/*
    # shellcheck disable=SC2016  # $1/$@ expand in the inner bash, not here
    run "${run_opts[@]}" bash -c 'cd -- "$1" || exit 99; shift; exec env -i "$@"' _ \
        "$WORK_DIR" "${envs[@]}" "$WRAPPER" "$@"
}

# --- Parsers ----------------------------------------------------------------

apptainer_was_called() {
    [[ -f "${STUB_LOG_DIR}/apptainer.argv" ]]
}

curl_was_called() {
    [[ -f "${STUB_LOG_DIR}/curl.argv" ]]
}

# Load the recorded apptainer argv into APPTAINER_ARGV.
load_apptainer_argv() {
    APPTAINER_ARGV=()
    if apptainer_was_called; then
        mapfile -d '' -t APPTAINER_ARGV < "${STUB_LOG_DIR}/apptainer.argv"
    fi
}

# Print the value following each occurrence of OPTION, one per line.
apptainer_option_values() {
    local option="$1" i
    load_apptainer_argv
    for (( i = 0; i < ${#APPTAINER_ARGV[@]}; i++ )); do
        if [[ "${APPTAINER_ARGV[i]}" == "$option" ]]; then
            printf '%s\n' "${APPTAINER_ARGV[i + 1]}"
        fi
    done
}

apptainer_binds() { apptainer_option_values --bind; }
apptainer_env_opts() { apptainer_option_values --env; }
apptainer_pwd() { apptainer_option_values --pwd; }

apptainer_prepend_path() {
    apptainer_env_opts | sed -n 's/^PREPEND_PATH=//p'
}

# Print the arguments after the image path (what Claude receives), one per line.
claude_args() {
    local i found=false
    load_apptainer_argv
    for (( i = 0; i < ${#APPTAINER_ARGV[@]}; i++ )); do
        if [[ "$found" == true ]]; then
            printf '%s\n' "${APPTAINER_ARGV[i]}"
        elif [[ "${APPTAINER_ARGV[i]}" == "$IMAGE" ]]; then
            found=true
        fi
    done
}

# Print the value of NAME in the environment apptainer received; fail if absent.
stub_environment() {
    local name="$1" entry
    [[ -f "${STUB_LOG_DIR}/apptainer.env" ]] || return 1
    while IFS= read -r -d '' entry; do
        if [[ "${entry%%=*}" == "$name" ]]; then
            printf '%s\n' "${entry#*=}"
            return 0
        fi
    done < "${STUB_LOG_DIR}/apptainer.env"
    return 1
}

# --- Domain checks ----------------------------------------------------------

assert_apptainer_called() {
    apptainer_was_called || fail "apptainer was not called (status ${status:-?})"$'\n'"${output:-}"
}

refute_apptainer_called() {
    if apptainer_was_called; then
        fail "apptainer was called, but the launch should have stopped"
    fi
}

# assert_bind SPEC: a --bind with exactly this spec was passed (order ignored).
assert_bind() {
    apptainer_binds | grep -Fxq -- "$1" ||
        fail "missing bind: $1"$'\n'"binds were:"$'\n'"$(apptainer_binds)"
}

refute_bind() {
    if apptainer_binds | grep -Fxq -- "$1"; then
        fail "unexpected bind: $1"
    fi
}

# refute_bind_matching REGEX: no --bind spec matches the extended regex.
refute_bind_matching() {
    if apptainer_binds | grep -Eq -- "$1"; then
        fail "unexpected bind matching $1:"$'\n'"$(apptainer_binds)"
    fi
}

# assert_claude_args ARGS...: Claude received exactly these arguments.
assert_claude_args() {
    local -a actual=()
    local line
    load_apptainer_argv
    local i found=false
    for (( i = 0; i < ${#APPTAINER_ARGV[@]}; i++ )); do
        if [[ "$found" == true ]]; then
            actual+=("${APPTAINER_ARGV[i]}")
        elif [[ "${APPTAINER_ARGV[i]}" == "$IMAGE" ]]; then
            found=true
        fi
    done
    if [[ "${#actual[@]}" -ne "$#" ]]; then
        fail "claude args: expected $# ($*), got ${#actual[@]} ($(printf '[%s] ' "${actual[@]}"))"
    fi
    for (( i = 0; i < $#; i++ )); do
        line="${actual[i]}"
        local expected="${*:i+1:1}"
        [[ "$line" == "$expected" ]] || fail "claude arg $i: expected [$expected], got [$line]"
    done
}

# refute_argv_contains STRING: STRING appears in no apptainer argument.
refute_argv_contains() {
    local arg
    load_apptainer_argv
    for arg in "${APPTAINER_ARGV[@]}"; do
        if [[ "$arg" == *"$1"* ]]; then
            fail "apptainer argument contains '$1': $arg"
        fi
    done
}

# Resolve a path the same way the wrapper does.
resolved() {
    realpath -e -- "$1"
}
