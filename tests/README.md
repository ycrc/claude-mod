# Tests for the claude-mod launcher

These tests exercise `eb/claude-wrapper.sh` and `eb/claude-wrapper-functions.sh`
without Apptainer or a cluster. Each test builds a sandbox with an EasyBuild-like
install directory, a fake home directory and stub `apptainer`, `hostname`,
`groups` and `curl` commands, then checks the exit status, the messages and
the exact arguments the wrapper would pass to Apptainer. The `curl` stub stands
in for the in-house model service; `STUB_SERVICE` selects its answer (`ok`,
`down`, `nomodel`, or an HTTP status such as `502`).

| File | Covers |
| --- | --- |
| `launch.bats` | Characterization of launch behavior (login node, configs, env scrubbing, binds, PATH, exclusions, working directory). |
| `functions.bats` | Unit tests for the functions file. |
| `help.bats` | `claude --ycrc-help`. |
| `user_binds.bats` | `claude --bind`. |
| `in_house.bats` | `claude --in-house-model`, with the shipped `claude-in-house.conf`. |
| `test_helper/harness.bash` | Sandbox, stubs, `run_wrapper`, parsers and bind/argument checks. |

## Requirements

- [bats-core](https://github.com/bats-core/bats-core) 1.7 or newer
- [bats-support](https://github.com/bats-core/bats-support) and
  [bats-assert](https://github.com/bats-core/bats-assert), in a directory on `BATS_LIB_PATH`
- `jq`
- `shellcheck`, for linting
- GNU coreutils and Bash 4.4 or newer

## Creating an environment with pixi

```bash
pixi init --platform linux-64 claude-mod-tests && cd claude-mod-tests
pixi add bats-core shellcheck jq

# bats-support and bats-assert are not on conda-forge; clone their latest releases.
mkdir -p lib
for lib in bats-support bats-assert; do
  tag=$(git ls-remote --tags --refs "https://github.com/bats-core/$lib" | sed 's#.*refs/tags/##' | sort -V | tail -1)
  git clone --depth 1 --branch "$tag" "https://github.com/bats-core/$lib" "lib/$lib"
done
```

Any other way of installing the same tools works too.

## Running the tests

```bash
export BATS_LIB_PATH=/path/to/lib                 # contains bats-support/ and bats-assert/
export CLAUDE_WRAPPER_TEST_TMPDIR=/path/to/scratch # not under /tmp, no hidden path components
pixi run bats /path/to/claude-mod/tests           # or: bats tests, from the repo root
```

`CLAUDE_WRAPPER_TEST_TMPDIR` holds the per-test sandboxes. It must not be under
`/tmp` (the shipped bind configuration binds `/tmp`, which makes it an invalid
working directory) and must not contain hidden path components.

Optional: set `WRAPPER_DIR` to another checkout's `eb/` directory to run the same
tests against a different version of the wrapper.

To run one file or filter by name: `bats tests/launch.bats` or
`bats --filter 'work dir' tests`.

## Linting

From the repository root:

```bash
shellcheck -x eb/*.sh tests/test_helper/harness.bash tests/*.bats
shellcheck -s bash -e SC2034 eb/*.conf
```
