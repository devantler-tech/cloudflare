#!/usr/bin/env bash
# Exercise the pinned native CLI, including a real occupied destination. No
# provider, credentials, network service or simulated backend participates.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
# On failure print only this fixture's synthetic native diagnostics, then erase
# its private source/destination files. No production inputs are used here.
finish() {
  local rc=$?
  if [[ $rc != 0 ]]; then
    for log in source/init.log source/apply.log positive-result positive-logs/migration.log refused-result refused-logs/migration.log; do
      [[ ! -f "$scratch/$log" ]] || cat "$scratch/$log" >&2
    done
    for state in expected-source.json actual.json; do
      [[ ! -f "$scratch/$state" ]] || jq '{version,terraform_version,lineage,serial,outputs,resources}' "$scratch/$state" >&2
    done
  fi
  rm -rf "$scratch"
}
trap finish EXIT
seed() {
  local directory=$1 value=$2
  mkdir "$directory"
  cat > "$directory/main.tf" <<HCL
terraform {
  required_version = "= 1.12.6"
  backend "local" {}
}
output "proof" { value = "$value" }
HCL
  tofu -chdir="$directory" init -input=false -no-color > "$directory/init.log" 2>&1
  tofu -chdir="$directory" apply -auto-approve -input=false -no-color > "$directory/apply.log" 2>&1
}
seed "$scratch/source" synthetic-source
cp "$scratch/source/terraform.tfstate" "$scratch/expected-source.json"
printf 'path = "%s/destination.tfstate"\n' "$scratch" > "$scratch/destination.hcl"
mkdir "$scratch/positive-logs"
TF_IN_AUTOMATION=1 bash "$root/scripts/migrate-native-backend.sh" "$scratch/source" "$scratch/destination.hcl" "$scratch/positive-logs" > "$scratch/positive-result" 2>&1
grep -qx 'NATIVE_STATE_MIGRATION=VERIFIED confirmation=empty-destination' "$scratch/positive-result"
tofu -chdir="$scratch/source" state pull > "$scratch/actual.json"
# Native migration advances its storage generation. All logical state and the
# lineage must remain identical; the serial must never move backwards.
jq -e --slurpfile expected "$scratch/expected-source.json" '.serial>=$expected[0].serial and (del(.serial))==($expected[0]|del(.serial))' "$scratch/actual.json" >/dev/null

seed "$scratch/refused-source" synthetic-other-source
seed "$scratch/occupied" keep-destination
cp "$scratch/occupied/terraform.tfstate" "$scratch/expected-destination.json"
printf 'path = "%s/occupied/terraform.tfstate"\n' "$scratch" > "$scratch/occupied.hcl"
mkdir "$scratch/refused-logs"
rc=0
bash "$root/scripts/migrate-native-backend.sh" "$scratch/refused-source" "$scratch/occupied.hcl" "$scratch/refused-logs" > "$scratch/refused-result" 2>&1 || rc=$?
[[ $rc == 2 ]]
grep -qx 'NATIVE_STATE_MIGRATION=UNVERIFIED stage=destination' "$scratch/refused-result"
cmp "$scratch/occupied/terraform.tfstate" "$scratch/expected-destination.json"
grep -Fq 'An existing non-empty state already exists' "$scratch/refused-logs/migration.log"
for directory in "$scratch/refused-source" "$scratch/occupied"; do
  tofu -chdir="$directory" plan -lock-timeout=0s -detailed-exitcode -input=false -no-color > "$directory/released-plan.log" 2>&1
done
mkdir "$scratch/hostile-logs"
rc=0
TF_CLI_ARGS_init=-force-copy bash "$root/scripts/migrate-native-backend.sh" "$scratch/refused-source" "$scratch/occupied.hcl" "$scratch/hostile-logs" > "$scratch/hostile-result" 2>&1 || rc=$?
[[ $rc == 2 ]]
grep -qx 'NATIVE_STATE_MIGRATION=UNVERIFIED stage=environment' "$scratch/hostile-result"
cmp "$scratch/occupied/terraform.tfstate" "$scratch/expected-destination.json"

seed "$scratch/multi-source" synthetic-multiple
tofu -chdir="$scratch/multi-source" workspace new additional > "$scratch/multi-source/new-workspace.log" 2>&1
tofu -chdir="$scratch/multi-source" apply -auto-approve -input=false -no-color > "$scratch/multi-source/additional-apply.log" 2>&1
tofu -chdir="$scratch/multi-source" workspace select default > "$scratch/multi-source/select-workspace.log" 2>&1
printf 'path = "%s/multi-destination.tfstate"\nworkspace_dir = "%s/multi-workspaces"\n' "$scratch" "$scratch" > "$scratch/multi.hcl"
mkdir "$scratch/multi-logs"
rc=0
bash "$root/scripts/migrate-native-backend.sh" "$scratch/multi-source" "$scratch/multi.hcl" "$scratch/multi-logs" > "$scratch/multi-result" 2>&1 || rc=$?
[[ $rc == 2 ]]
grep -qx 'NATIVE_STATE_MIGRATION=UNVERIFIED stage=destination' "$scratch/multi-result"
[[ ! -e "$scratch/multi-destination.tfstate" ]]

printf '%s\n' 'PASS: native empty-destination migration preserves state and occupied destination refuses without overwrite'
