#!/bin/bash
# Test the launcher's --bind handling (the "user bind arguments" and "user
# binds" sections of eb/coding-agents-wrapper.sh) against throwaway
# directories. Needs no container, module or Slurm allocation.
set -uo pipefail
repo="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d)"; T="$(realpath "$T")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

wrapper="$repo/eb/coding-agents-wrapper.sh"
sed -n '/^# --- BEGIN user bind arguments ---$/,/^# --- END user bind arguments ---$/p' "$wrapper" > "$T/args.sh"
sed -n '/^# --- BEGIN user binds ---$/,/^# --- END user binds ---$/p' "$wrapper" > "$T/binds.sh"
check "sections found"                      '[[ -s "$T/args.sh" && -s "$T/binds.sh" ]]'

H="$T/home"; W="$H/work"; S="$T/shared"
mkdir -p "$W/sub" "$H/scripts" "$H/.secret" "$S/db" "$S/.hidden" "$T/admin/inner" "$T/excluded" \
         "$T/a,b" "$T/nonread"
ln -s "$S/db" "$T/db-link"
# Group storage: the user is in grp1 and grp2, not grp3.
mkdir -p "$T/project/grp1/shared" "$T/project/grp2" "$T/pi/grp2/shared" "$T/project/grp3/shared"
chmod 000 "$T/nonread" "$T/pi/grp2/shared"

# run ARGS...: parse and check the arguments as the launcher would, from the
# working directory. Prints the resulting bind options, harness arguments and
# directories on stdout; messages go to stderr.
run(){
    ( set -euo pipefail
      cd "$W"
      agent=pi host_home="$H" home_root="$H" work_dir="$W"
      configured_bind_roots=("$T/admin") configured_bind_paths=("$T/admin")
      excluded_work_roots=("$T/excluded")
      group_output="${GROUPS_OVERRIDE-grp1 grp2}" storage_bases=("$T/project" "$T/pi")
      set -- "$@"
      source "$T/args.sh"
      source "$T/binds.sh"
      for x in "${user_bind_opts[@]}"; do [[ $x == --bind ]] || echo "OPT $x"; done
      for x in "$@"; do echo "ARG $x"; done
      for x in "${user_bind_dirs[@]}"; do echo "DIR $x"; done
    )
}

out="$(GROUPS_OVERRIDE= run --bind "$S/db" -p hello 2>"$T/err")"
check "--bind DIR mounts read-only"         'grep -qx "OPT $S/db:$S/db:ro" <<< "$out"'
check "other arguments forwarded in order"  '[[ "$(grep ^ARG <<< "$out" | tr "\n" " ")" == "ARG -p ARG hello " ]]'
check "bind reported on stderr"             'grep -qx "Binding read-only: $S/db" "$T/err"'

out="$(GROUPS_OVERRIDE= run --bind="$S/db,$H/scripts" -B "$S" 2>/dev/null)"
check "=form, comma list and -B"            '[[ $(grep -c "^DIR" <<< "$out") == 3 ]]'

out="$(run --bind "$S/db:ro" 2>/dev/null)"
check ":ro suffix accepted"                 'grep -qx "OPT $S/db:$S/db:ro" <<< "$out"'

out="$(run --bind '~/scripts' 2>/dev/null)"
check "~ expanded to home"                  'grep -qx "DIR $H/scripts" <<< "$out"'

out="$(run --bind ../scripts 2>/dev/null)"
check "relative path from launch dir"       'grep -qx "DIR $H/scripts" <<< "$out"'

out="$(run --bind "$T/db-link" 2>/dev/null)"
check "symlink bound under both names"      'grep -qx "OPT $S/db:$T/db-link:ro" <<< "$out" && grep -qx "OPT $S/db:$S/db:ro" <<< "$out"'

out="$(GROUPS_OVERRIDE= run --bind "$S/db" --bind "$S/db" 2>/dev/null)"
check "duplicate bound once"                '[[ $(grep -c "^OPT" <<< "$out") == 1 ]]'

out="$(run --bind "$H" 2>/dev/null)"; rc=$?
check "home refused"                        '[[ $rc != 0 && -z "$out" ]]'
check "ancestor of home refused"            '! run --bind "$T" >/dev/null 2>&1'
check "read-write refused"                  '! run --bind "$S/db:rw" >/dev/null 2>&1'
check "custom destination refused"          '! run --bind "$S/db:/data" >/dev/null 2>&1'
check "hidden component refused"            '! run --bind "$S/.hidden" >/dev/null 2>&1'
check "hidden dir in home refused"          '! run --bind "$H/.secret" >/dev/null 2>&1'
check "system directory refused"            '! run --bind /etc >/dev/null 2>&1'
check "root refused"                        '! run --bind / >/dev/null 2>&1'
check "path with comma refused"             '! run --bind="$T/a\,b" >/dev/null 2>&1'
check "excluded directory refused"          '! run --bind "$T/excluded" >/dev/null 2>&1'
check "missing directory refused"           '! run --bind "$T/missing" >/dev/null 2>&1'
check "missing value refused"               '! run --bind >/dev/null 2>&1'
check "empty value refused"                 '! run --bind= >/dev/null 2>&1'
if [[ ! -r "$T/nonread" ]]; then
    check "unreadable directory refused"    '! run --bind "$T/nonread" >/dev/null 2>&1'
fi

out="$(GROUPS_OVERRIDE= run --bind "$W/sub" --bind "$T/admin/inner" 2>"$T/err")"
check "inside work dir/admin bind skipped"  '! grep -q "^OPT" <<< "$out" && [[ $(grep -c "already available" "$T/err") == 2 ]]'

out="$(GROUPS_OVERRIDE= run -p hi -- --bind "$S/db" 2>/dev/null)"
check "nothing after -- is taken"           '! grep -q "^OPT" <<< "$out" && [[ "$(grep ^ARG <<< "$out" | tr "\n" " ")" == "ARG -p ARG hi ARG -- ARG --bind ARG $S/db " ]]'

out="$(GROUPS_OVERRIDE= run 2>/dev/null)"
check "no --bind, no groups: nothing bound" '! grep -q "^OPT" <<< "$out"'

# Group shared directories are bound without --bind, wherever the session starts.
out="$(run 2>"$T/err")"; rc=$?
check "own group's shared bound"            '[[ $rc == 0 ]] && grep -qx "OPT $T/project/grp1/shared:$T/project/grp1/shared:ro" <<< "$out"'
check "group shared reported"               'grep -qx "Binding read-only: $T/project/grp1/shared (group shared directory)" "$T/err"'
check "other group's shared not bound"      '! grep -q "grp3" <<< "$out"'
check "unreadable group shared only noted"  '! grep -q "grp2" <<< "$out" && grep -q "Note: group shared directory not bound: you cannot read" "$T/err"'
out="$(run --bind "$T/project/grp1/shared" 2>/dev/null)"
check "explicit bind of it not duplicated"  '[[ $(grep -c "grp1/shared:ro" <<< "$out") == 1 ]]'

chmod 755 "$T/nonread" "$T/pi/grp2/shared"
echo "== $pass passed, $fail failed"
[[ $fail == 0 ]]
