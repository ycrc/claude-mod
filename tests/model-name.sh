#!/bin/bash
# Test the launcher's model-name lookup (the "model name" section of
# eb/coding-agents-wrapper.sh) against canned gateway /v1/models responses.
# Needs no gateway, container, module or Slurm allocation.
set -uo pipefail
repo="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

sed -n '/^# --- BEGIN model name ---$/,/^# --- END model name ---$/p' \
    "$repo/eb/coding-agents-wrapper.sh" > "$T/model.sh"
check "section found"                       '[[ -s "$T/model.sh" ]]'

# lookup RESPONSE [CURL_STATUS]: run the section with curl replaced by a
# function that prints RESPONSE; prints the resulting base_model.
lookup(){
    printf '%s' "$1" > "$T/response"
    ( set -euo pipefail
      curl(){ cat "$T/response"; return "${CURL_STATUS:-0}"; }
      agent_auth=x YCRC_AGENT_MODEL=ycrc-local YCRC_AGENT_THINK_SUFFIX=-think
      YCRC_COPILOT_BASE_URL=http://gateway.invalid/v1
      source "$T/model.sh"
      echo "$base_model" )
}

served='{"data":[
 {"id":"Qwen3.8-Flash-Next","root":"/models/Qwen3.8-Flash-Next-FP8"},
 {"id":"ycrc-local","root":"/models/Qwen3.8-Flash-Next-FP8"},
 {"id":"Qwen3.8-Flash-Next-think","root":"/models/Qwen3.8-Flash-Next-FP8"},
 {"id":"ycrc-local-think","root":"/models/Qwen3.8-Flash-Next-FP8"}]}'
check "real name from the gateway"          '[[ "$(lookup "$served")" == Qwen3.8-Flash-Next ]]'

order='{"data":[
 {"id":"ycrc-local-think","root":"/m/A"},{"id":"ycrc-local","root":"/m/A"},
 {"id":"Other-Model","root":"/m/B"},{"id":"Model-A-think","root":"/m/A"},{"id":"Model-A","root":"/m/A"}]}'
check "matches the alias by backing model"  '[[ "$(lookup "$order")" == Model-A ]]'

check "alias only: keep the alias"          '[[ "$(lookup "{\"data\":[{\"id\":\"ycrc-local\",\"root\":\"/m/A\"}]}")" == ycrc-local ]]'
check "unreachable gateway: keep the alias" '[[ "$(CURL_STATUS=7 lookup "")" == ycrc-local ]]'
check "invalid JSON: keep the alias"        '[[ "$(lookup "<html>502</html>")" == ycrc-local ]]'
check "unsafe name rejected"                '[[ "$(lookup "{\"data\":[{\"id\":\"bad name;rm\",\"root\":\"/m/A\"},{\"id\":\"ycrc-local\",\"root\":\"/m/A\"}]}")" == ycrc-local ]]'

echo "== $pass passed, $fail failed"
[[ $fail == 0 ]]
