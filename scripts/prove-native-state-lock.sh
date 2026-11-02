#!/usr/bin/env bash
# Use the real backend's native lock, never a process-local substitute. The
# module and private log directory must already exist; no provider is required.
set +x
set -euo pipefail
umask 077
stage=arguments writer='' reader='' locker_pid=''
fail() { printf 'NATIVE_STATE_LOCK=UNVERIFIED stage=%s\n' "$stage" >&2; exit 2; }
finish() {
  local rc=$?
  if [[ -n "$writer" ]]; then
    { printf 'exit\n' >&"$writer"; } 2>/dev/null || true
    exec {writer}>&-
  fi
  [[ -z "$reader" ]] || exec {reader}<&-
  if [[ -n "$locker_pid" ]]; then wait "$locker_pid" 2>/dev/null || true; fi
  return "$rc"
}
trap finish EXIT
trap 'exit 2' INT TERM
[[ ${BASH_VERSINFO[0]} -ge 5 && $# == 2 && -d $1 && ! -L $1 && -d $2 && ! -L $2 ]] || fail
module=$1 logs=$2
command -v timeout >/dev/null 2>&1 || fail
stage=acquire
coproc LOCKER { timeout 45 tofu -chdir="$module" console -no-color -lock-timeout=0s 2> "$logs/console-error.log"; }
# shellcheck disable=SC2153 # Bash assigns this for the named coprocess above.
locker_pid=$LOCKER_PID
exec {writer}>&"${LOCKER[1]}"
exec {reader}<&"${LOCKER[0]}"
printf '"native-lock-held"\n' >&"$writer" || fail
IFS= read -r -t 25 -u "$reader" observed || fail
[[ "$observed" == '"native-lock-held"' ]] || fail
stage=contention
rc=0
timeout 30 tofu -chdir="$module" plan -lock-timeout=0s -input=false -no-color > "$logs/contender.log" 2>&1 || rc=$?
if [[ $rc != 1 ]] || ! grep -Fq 'Error acquiring the state lock' "$logs/contender.log" ||
  ! grep -Fxq 'Lock Info:' "$logs/contender.log" ||
  [[ $(grep -Ec '^  ID: +[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' "$logs/contender.log") != 1 ]]; then fail; fi
stage=release
printf 'exit\n' >&"$writer" || fail
exec {writer}>&-
writer=''
exec {reader}<&-
reader=''
wait "$locker_pid" || fail
locker_pid=''
stage=released-plan
timeout 30 tofu -chdir="$module" plan -lock-timeout=0s -detailed-exitcode -input=false -no-color > "$logs/released-plan.log" 2>&1 || fail
printf '%s\n' 'NATIVE_STATE_LOCK=VERIFIED contention=refused release=normal'
