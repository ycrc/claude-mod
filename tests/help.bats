#!/usr/bin/env bats
# Tests for `claude --ycrc-help`: module usage, printed before any launch check.
# SC2034: tests set WRAPPER_ENV/WRAPPER_ENV_UNSET, which the harness reads.
# shellcheck disable=SC2034

load 'test_helper/harness'

@test "help: prints module usage, exits 0, never launches" {
    run_wrapper --ycrc-help
    assert_success
    assert_output --partial "claude-mod"
    assert_output --partial "--ycrc-help"
    assert_output --partial "https://docs.ycrc.yale.edu/ai/commercial-coding-agents/#using-the-claude-module"
    refute_apptainer_called
}

@test "help: works on a login node" {
    STUB_HOSTNAME=login1 run_wrapper --ycrc-help
    assert_success
    refute_apptainer_called
}

@test "help: works without CLUSTER or HOME, describing roots generically" {
    WRAPPER_ENV_UNSET=(CLUSTER HOME)
    run_wrapper --ycrc-help
    assert_success
    assert_output --partial "home, project, scratch"
    refute_output --partial "/nfs/roberts"
}

@test "help: works with an unsupported CLUSTER" {
    WRAPPER_ENV=(CLUSTER=nowhere)
    run_wrapper --ycrc-help
    assert_success
}

@test "help: lists the cluster's storage bases" {
    run_wrapper --ycrc-help
    assert_success
    assert_output --partial "/nfs/roberts/project/<group>/<netid>"
    assert_output --partial "/nfs/roberts/scratch/<group>/<netid>"
    WRAPPER_ENV=(CLUSTER=mccleary)
    run_wrapper --ycrc-help
    assert_output --partial "/gpfs/gibbs/project/<group>/<netid>"
}

@test "help: works from a directory where Claude could not start" {
    WORK_DIR="$TEST_HOME"
    run_wrapper --ycrc-help
    assert_success
}

@test "help: after --, --ycrc-help is passed to Claude" {
    run_wrapper -- --ycrc-help
    assert_success
    assert_claude_args -- --ycrc-help
}
