#!/usr/bin/env bash
# Automate only the pinned CLI's empty-destination confirmation. OpenTofu owns
# both native locks and rechecks state while locked; never force or overwrite.
set +x
set -euo pipefail
umask 077
stage=arguments writer='' reader='' child='' log=''
fail() { printf 'NATIVE_STATE_MIGRATION=UNVERIFIED stage=%s\n' "$stage" >&2; exit 2; }
# EOF aborts an unanswered native prompt. Drain output so its normal error path
# can release locks before waiting; an unresponsive child has its own deadline.
finish() {
  local rc=$?
  [[ -z "$writer" ]] || exec {writer}>&-
  if [[ -n "$reader" ]]; then
    timeout 10 cat <&"$reader" >> "$log" 2>/dev/null || true
    exec {reader}<&-
  fi
  [[ -z "$child" ]] || wait "$child" 2>/dev/null || true
  return "$rc"
}
trap finish EXIT
trap 'exit 2' INT TERM
[[ ${BASH_VERSINFO[0]} -ge 5 && $# == 3 && -d $1 && ! -L $1 &&
  -f $2 && ! -L $2 && -d $3 && ! -L $3 && ! -e $3/migration.log && ! -L $3/migration.log ]] || fail
module=$1 configuration=$2 log="$3/migration.log"
stage=environment
while IFS= read -r name; do
  case "$name" in
    TF_IN_AUTOMATION) [[ ${TF_IN_AUTOMATION:-} == 1 ]] || fail ;;
    TF_*|TOFU_*) fail ;;
  esac
done < <(compgen -e)
command -v timeout >/dev/null 2>&1 || fail
stage=version
version=$(tofu version -json 2>/dev/null) || fail
printf '%s' "$version" | jq -e '.terraform_version=="1.12.6"' >/dev/null 2>&1 || fail
stage=copy
coproc MIGRATION { timeout --kill-after=10s 180 tofu -chdir="$module" init -migrate-state -no-color -backend-config="$configuration" 2>&1; }
# shellcheck disable=SC2153 # Bash creates this for the named coprocess above.
child=$MIGRATION_PID
exec {writer}>&"${MIGRATION[1]}"
exec {reader}<&"${MIGRATION[0]}"
# Closing only the duplicates would leave the original coprocess write end
# open, preventing EOF from reaching a refused prompt.
original_writer=${MIGRATION[1]} original_reader=${MIGRATION[0]}
exec {original_writer}>&-
exec {original_reader}<&-
buffer='' answers=0 refused=false total=0
while true; do
  read_rc=0
  IFS= read -r -N 1 -t 30 -u "$reader" character || read_rc=$?
  if [[ $read_rc != 0 ]]; then
    if [[ $read_rc != 1 ]]; then stage=stream; refused=true; fi
    break
  fi
  printf '%s' "$character" >> "$log"
  buffer+=$character
  total=$((total + 1))
  if [[ $total -gt 1048576 ]]; then stage=output; refused=true; break; fi
  if [[ "$buffer" == *'Enter a value:' ]]; then
    if [[ $answers == 0 && "$buffer" == *'Do you want to copy existing state to the new backend?'* &&
      "$buffer" == *'No existing state was found'* && "${buffer,,}" != *'overwrite'* &&
      "${buffer,,}" != *'non-empty'* && "${buffer,,}" != *'all workspaces'* ]]; then
      printf 'yes\n' >&"$writer" || fail
      answers=1
      buffer=''
    else
      stage=destination
      refused=true
      [[ -z "$writer" ]] || exec {writer}>&-
      writer=''
    fi
  fi
done
[[ -z "$writer" ]] || exec {writer}>&-
writer=''
rc=0
wait "$child" || rc=$?
child=''
exec {reader}<&-
reader=''
[[ "$refused" == false ]] || fail
stage=native-command
[[ $rc == 0 ]] || fail
stage=no-copy
[[ $answers == 1 ]] || fail
printf '%s\n' 'NATIVE_STATE_MIGRATION=VERIFIED confirmation=empty-destination'
