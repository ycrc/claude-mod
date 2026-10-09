#!/usr/bin/env bats
# Unit tests for eb/claude-wrapper-functions.sh, plus the deliberate behavior
# changes made by the refactor. Functions that can call die() run through
# `run`, so their exit ends only bats' subshell.
# SC2016: config fixtures are single-quoted on purpose; the code expands $HOME.
# SC2030/SC2031/SC2034/SC2154: tests share globals with the functions.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2154

load 'test_helper/harness'

load_functions() {
    # shellcheck source=SCRIPTDIR/../eb/claude-wrapper-functions.sh
    source "${WRAPPER_DIR}/claude-wrapper-functions.sh"
    PATH="${STUB_DIR}:${PATH}"
}

# --- Path helpers -------------------------------------------------------------

@test "path_is_within: equal, child, and the prefix trap" {
    load_functions
    path_is_within /a/b /a/b
    path_is_within /a/b/c /a/b
    run path_is_within /a/bc /a/b
    assert_failure
    run path_is_within /a /a/b
    assert_failure
}

@test "require_bindable_path: accepts an absolute path, rejects the rest" {
    load_functions
    run require_bindable_path /a/b "thing"
    assert_success
    run require_bindable_path a/b "thing"
    assert_failure
    assert_output --partial "absolute directory other than /"
    run require_bindable_path / "thing"
    assert_failure
    run require_bindable_path /a:b "thing"
    assert_failure
    assert_output --partial "cannot contain ':'"
    run require_bindable_path /a,b "thing"
    assert_failure
    assert_output --partial "cannot contain ','"
}

@test "resolve_directory: dir, symlink, file, missing" {
    load_functions
    mkdir -p "${SANDBOX}/d"
    ln -s "${SANDBOX}/d" "${SANDBOX}/l"
    : > "${SANDBOX}/f"
    run resolve_directory "${SANDBOX}/d" "dir"
    assert_success
    assert_output "${SANDBOX}/d"
    run resolve_directory "${SANDBOX}/l" "dir"
    assert_output "${SANDBOX}/d"
    run resolve_directory "${SANDBOX}/f" "dir"
    assert_failure
    assert_output --partial "dir is not a directory"
    run resolve_directory "${SANDBOX}/missing" "dir"
    assert_failure
    assert_output --partial "cannot resolve dir"
}

@test "is_non_hidden_subdirectory: root, child, hidden" {
    load_functions
    run is_non_hidden_subdirectory /r /r
    assert_failure
    run is_non_hidden_subdirectory /r/a/b /r
    assert_success
    run is_non_hidden_subdirectory /r/a/.h/b /r
    assert_failure
    # Hidden components above the root don't matter.
    run is_non_hidden_subdirectory /.x/r/a /.x/r
    assert_success
}

# --- Configuration ------------------------------------------------------------

@test "load_config_array: missing file, removed array, valid, inherited value reset" {
    load_functions
    run load_config_array "${SANDBOX}/missing.conf" binds "bind"
    assert_failure
    assert_output --partial "bind configuration not found"

    echo 'unset binds' > "${SANDBOX}/unset.conf"
    run load_config_array "${SANDBOX}/unset.conf" binds "bind"
    assert_failure
    assert_output --partial "must define an indexed array named binds"

    echo 'binds=("/x" "/y:ro")' > "${SANDBOX}/ok.conf"
    load_config_array "${SANDBOX}/ok.conf" binds "bind"
    assert_equal "${#binds[@]}" 2
    assert_equal "${binds[1]}" "/y:ro"

    binds=(/inherited)
    echo '# nothing' > "${SANDBOX}/empty.conf"
    load_config_array "${SANDBOX}/empty.conf" binds "bind"
    assert_equal "${#binds[@]}" 0
}

@test "load_config_vars: missing file, unset or empty values, valid, inherited value cleared" {
    load_functions
    run load_config_vars "${SANDBOX}/missing.conf" "in-house" one
    assert_failure
    assert_output --partial "in-house configuration not found"

    printf '%s\n' "one='a'" "two=''" > "${SANDBOX}/empty-value.conf"
    run load_config_vars "${SANDBOX}/empty-value.conf" "in-house" one two
    assert_failure
    assert_output --partial "must set two"

    printf '%s\n' "one='a'" "list=(x y)" > "${SANDBOX}/ok.conf"
    load_config_vars "${SANDBOX}/ok.conf" "in-house" one list
    assert_equal "$one" a
    assert_equal "${list[1]}" y

    # An exported value must not fill a gap left in the file.
    export two=inherited
    echo "one='a'" > "${SANDBOX}/gap.conf"
    run load_config_vars "${SANDBOX}/gap.conf" "in-house" one two
    assert_failure
    assert_output --partial "must set two"
}

@test "split_bind_mode: modes, default, invalid" {
    load_functions
    split_bind_mode /a:ro "" label
    assert_equal "$bind_path:$bind_mode" "/a:ro"
    split_bind_mode /a:rw "" label
    assert_equal "$bind_path:$bind_mode" "/a:rw"
    split_bind_mode /a "" label
    assert_equal "$bind_path:$bind_mode" "/a:"
    split_bind_mode /a ro label
    assert_equal "$bind_mode" ro
    run split_bind_mode /a:xx "" label
    assert_failure
    assert_output --partial "invalid bind mode in label"
}

# --- Work-dir policy ----------------------------------------------------------

@test "collect_allowed_roots: home plus each existing group space" {
    load_functions
    host_home="$TEST_HOME"
    user_name=tester
    storage_bases=("${SANDBOX}/project" "${SANDBOX}/scratch")
    mkdir -p "${SANDBOX}/project/lab/tester" "${SANDBOX}/scratch/lab/tester" \
             "${SANDBOX}/project/other/someone"
    STUB_GROUPS="lab other" collect_allowed_roots
    assert_equal "${allowed_roots[*]}" \
        "${TEST_HOME} ${SANDBOX}/project/lab/tester ${SANDBOX}/scratch/lab/tester"
}

# --- Binds --------------------------------------------------------------------

@test "build_bind_opts: parent-first by depth, stable at equal depth" {
    load_functions
    bind_entries=()
    add_bind /h/a/b/c /a/b/c ""
    add_bind /h/a /a ro
    add_bind /h/z /z ""
    add_bind /h/a/b /a/b rw
    build_bind_opts
    assert_equal "${bind_opts[*]}" \
        "--bind /h/a:/a:ro --bind /h/z:/z --bind /h/a/b:/a/b:rw --bind /h/a/b/c:/a/b/c"
}

@test "add_bind_with_alias: a symlink is bound at both paths" {
    load_functions
    bind_entries=()
    add_bind_with_alias /logical /real ro
    add_bind_with_alias /same /same ""
    build_bind_opts
    assert_equal "${bind_opts[*]}" "--bind /real:/logical:ro --bind /real:/real:ro --bind /same:/same"
}

# --- Deliberate behavior changes from the refactor ----------------------------

@test "change: env-scrub warnings go to stderr only" {
    WRAPPER_ENV=(MY_TOKEN=secret)
    run_wrapper --separate-stderr
    assert_success
    assert_equal "$output" ""
    [[ "$stderr" == *"unset sensitive environment variable: MY_TOKEN"* ]] ||
        fail "warning not on stderr: $stderr"
}

@test "change: a bind entry containing ':' in its path is rejected" {
    mkdir -p "${TEST_HOME}/a:b"
    set_conf bind 'binds=("$HOME/a:b:ro")'
    run_wrapper
    assert_failure
    assert_output --partial "cannot contain ':'"
}

# --- PI storage (docs/spec.md) ------------------------------------------------

@test "set_storage_bases: project, scratch and PI bases per cluster" {
    load_functions
    set_storage_bases bouchet
    assert_equal "${storage_bases[*]}" "/nfs/roberts/project /nfs/roberts/scratch /nfs/roberts/pi"
    set_storage_bases grace
    assert_equal "${storage_bases[*]}" \
        "/gpfs/gibbs/project /vast/palmer/scratch /gpfs/gibbs/pi /vast/palmer/pi"
    set_storage_bases McCleary
    assert_equal "${storage_bases[*]}" \
        "/gpfs/gibbs/project /vast/palmer/scratch /gpfs/gibbs/pi /vast/palmer/pi"
}

@test "collect_allowed_roots: skips the personal group and ignored groups" {
    load_functions
    host_home="$TEST_HOME"
    user_name=tester
    storage_bases=("${SANDBOX}/project" "${SANDBOX}/scratch" "${SANDBOX}/pi")
    local base group
    for base in project scratch pi; do
        for group in lab tester gaussian; do
            mkdir -p "${SANDBOX}/${base}/${group}/tester"
        done
    done
    STUB_GROUPS="lab tester gaussian" collect_allowed_roots
    assert_equal "${allowed_roots[*]}" \
        "${TEST_HOME} ${SANDBOX}/project/lab/tester ${SANDBOX}/scratch/lab/tester ${SANDBOX}/pi/lab/tester"
}

@test "is_non_hidden_subdirectory: below a PI root is allowed; the root and hidden parts are not" {
    load_functions
    local root=/nfs/roberts/pi/lab/tester
    run is_non_hidden_subdirectory "${root}/proj" "$root"
    assert_success
    run is_non_hidden_subdirectory "$root" "$root"
    assert_failure
    run is_non_hidden_subdirectory "${root}/.h/proj" "$root"
    assert_failure
}
