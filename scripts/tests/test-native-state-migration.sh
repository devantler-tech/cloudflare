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
    for log in source/init.log source/apply.log positive-result positive-logs/destination-init.log positive-logs/destination-workspaces.json positive-logs/destination-workspaces-error.log positive-logs/migration.log refused-result refused-logs/migration.log named-result named-logs/destination-workspaces.json named-logs/migration.log; do
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
printf 'path = "%s/destination.tfstate"\nworkspace_dir = "%s/positive-workspaces"\n' "$scratch" "$scratch" > "$scratch/destination.hcl"
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
printf 'path = "%s/occupied/terraform.tfstate"\nworkspace_dir = "%s/occupied/terraform.tfstate.d"\n' "$scratch" "$scratch" > "$scratch/occupied.hcl"
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

# The source has only default, but destination has a populated named workspace
# and an empty default. The default prompt alone cannot establish this census.
seed "$scratch/named-source" synthetic-named-source
mkdir "$scratch/named-destination"
cp "$scratch/named-source/main.tf" "$scratch/named-destination/main.tf"
tofu -chdir="$scratch/named-destination" init -input=false -no-color > "$scratch/named-destination/init.log" 2>&1
tofu -chdir="$scratch/named-destination" workspace new retained > "$scratch/named-destination/new.log" 2>&1
tofu -chdir="$scratch/named-destination" apply -auto-approve -input=false -no-color > "$scratch/named-destination/apply.log" 2>&1
tofu -chdir="$scratch/named-destination" workspace select default > "$scratch/named-destination/select.log" 2>&1
cp "$scratch/named-destination/terraform.tfstate.d/retained/terraform.tfstate" "$scratch/expected-named.json"
cp "$scratch/named-source/terraform.tfstate" "$scratch/expected-named-source.json"
printf 'path = "%s/named-destination/terraform.tfstate"\nworkspace_dir = "%s/named-destination/terraform.tfstate.d"\n' "$scratch" "$scratch" > "$scratch/named.hcl"
mkdir "$scratch/named-logs"
rc=0
bash "$root/scripts/migrate-native-backend.sh" "$scratch/named-source" "$scratch/named.hcl" "$scratch/named-logs" > "$scratch/named-result" 2>&1 || rc=$?
[[ $rc == 2 ]]
grep -qx 'NATIVE_STATE_MIGRATION=UNVERIFIED stage=destination-workspaces' "$scratch/named-result"
cmp "$scratch/named-destination/terraform.tfstate.d/retained/terraform.tfstate" "$scratch/expected-named.json"
cmp "$scratch/named-source/terraform.tfstate" "$scratch/expected-named-source.json"
[[ ! -e "$scratch/named-destination/terraform.tfstate" ]]

mkdir "$scratch/relative-logs"
printf 'path = "relative.tfstate"\nworkspace_dir = "relative-workspaces"\n' > "$scratch/relative.hcl"
rc=0
bash "$root/scripts/migrate-native-backend.sh" "$scratch/named-source" "$scratch/relative.hcl" "$scratch/relative-logs" > "$scratch/relative-result" 2>&1 || rc=$?
[[ $rc == 2 ]]
grep -qx 'NATIVE_STATE_MIGRATION=UNVERIFIED stage=destination-workspaces' "$scratch/relative-result"
cmp "$scratch/named-source/terraform.tfstate" "$scratch/expected-named-source.json"
[[ ! -e "$scratch/named-source/relative.tfstate" ]]

printf '%s\n' 'PASS: native empty-destination migration preserves state and occupied destination refuses without overwrite'
