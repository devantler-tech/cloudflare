#!/usr/bin/env bash
# Native OpenTofu controls: this test proves locking, release and refusal when
# the backend has deliberately disabled locks. It does not simulate R2.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
finish() {
  local rc=$?
  if [[ $rc != 0 ]]; then
    for log in init.log apply.log result disabled-result; do
      [[ ! -f "$scratch/$log" ]] || cat "$scratch/$log" >&2
    done
  fi
  rm -rf "$scratch"
}
trap finish EXIT
mkdir "$scratch/module" "$scratch/proof" "$scratch/disabled"
cat > "$scratch/module/main.tf" <<'HCL'
terraform {
  required_version = "= 1.12.6"
  backend "local" {}
}
output "proof" { value = "synthetic-state-lock" }
HCL
tofu -chdir="$scratch/module" init -input=false -no-color > "$scratch/init.log" 2>&1
tofu -chdir="$scratch/module" apply -auto-approve -input=false -no-color > "$scratch/apply.log" 2>&1
bash "$root/scripts/prove-native-state-lock.sh" "$scratch/module" "$scratch/proof" > "$scratch/result" 2>&1
grep -qx 'NATIVE_STATE_LOCK=VERIFIED contention=refused release=normal' "$scratch/result"
# A writable backend alone is insufficient: disabling lock acquisition must
# cause the same proof to refuse, rather than reporting a false green result.
if TF_CLI_ARGS_console=-lock=false bash "$root/scripts/prove-native-state-lock.sh" "$scratch/module" "$scratch/disabled" > "$scratch/disabled-result" 2>&1; then
  printf '%s\n' 'FAIL: a backend without lock contention was accepted' >&2
  exit 1
fi
grep -qx 'NATIVE_STATE_LOCK=UNVERIFIED stage=contention' "$scratch/disabled-result"
tofu -chdir="$scratch/module" plan -detailed-exitcode -input=false -no-color > "$scratch/released.log" 2>&1
printf '%s\n' 'PASS: native lock contention, normal release and disabled-lock negative control'
