#!/usr/bin/env bash
# Package already-captured state and desired variables. No import/apply/API call.
set +x
set -euo pipefail
umask 077
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
[[ $# == 7 ]] || state_fail arguments
root=$1 state_file=$2 configuration_file=$3 output=$4 source_commit=$5 source_run=$6 captured_at=$7
[[ -d "$root" && ! -L "$root" && ! -e "$output" && ! -L "$output" ]] || state_fail directory
recipient=$(state_recipient "$root")
[[ "$source_commit" =~ ^[a-f0-9]{40}$ && "$source_run" =~ ^[1-9][0-9]{0,15}$ ]] || state_fail source
jq -n -e --arg run "$source_run" --arg captured "$captured_at" '($run|tonumber)<9007199254740992 and ($captured|fromdateiso8601|todateiso8601)==$captured' >/dev/null 2>&1 || state_fail source
for file in "$state_file" "$configuration_file"; do
  [[ -f "$file" && ! -L "$file" && $(wc -c < "$file") -le 16777216 ]] || state_fail input
done
private=$(mktemp -d)
owned_output=false
prepared=false
cleanup() {
  rm -rf "$private"
  if "$owned_output" && ! "$prepared"; then rm -rf "$output"; fi
}
trap cleanup EXIT
trap 'exit 2' INT TERM
# Freeze both inputs before validation/hash/encryption, so a changing caller file
# cannot silently produce ciphertext different from the checked bytes.
cp "$state_file" "$private/state.json" 2>/dev/null || state_fail input
cp "$configuration_file" "$private/configuration.json" 2>/dev/null || state_fail input
state_payloads "$private/state.json" "$private/configuration.json"
age --encrypt -r "$recipient" -o "$private/state.json.age" "$private/state.json" 2>/dev/null || state_fail encryption
age --encrypt -r "$recipient" -o "$private/configuration.json.age" "$private/configuration.json" 2>/dev/null || state_fail encryption
lineage=$(jq -er .lineage "$private/state.json")
serial=$(jq -er .serial "$private/state.json")
account=$(jq -er .account_id "$private/configuration.json")
zone=$(jq -er .zone_name "$private/configuration.json")
printf '%s' "$account" > "$private/account"
printf '%s' "$zone" > "$private/zone"
jq -n --arg recipient "$recipient" --arg sourceCommit "$source_commit" --argjson sourceRun "$source_run" --arg capturedAt "$captured_at" \
  --arg lineage "$lineage" --argjson serial "$serial" \
  --arg stateCiphertextSha256 "$(state_hash "$private/state.json.age")" --arg configurationCiphertextSha256 "$(state_hash "$private/configuration.json.age")" \
  --arg statePlaintextSha256 "$(state_hash "$private/state.json")" --arg configurationPlaintextSha256 "$(state_hash "$private/configuration.json")" \
  --arg accountIdSha256 "$(state_hash "$private/account")" --arg zoneNameSha256 "$(state_hash "$private/zone")" \
  '{schemaVersion:1,kind:"cloudflare-state-recovery",capturedAt:$capturedAt,sourceCommit:$sourceCommit,sourceRun:$sourceRun,recipient:$recipient,lineage:$lineage,serial:$serial,accountIdSha256:$accountIdSha256,zoneNameSha256:$zoneNameSha256,stateCiphertextSha256:$stateCiphertextSha256,configurationCiphertextSha256:$configurationCiphertextSha256,statePlaintextSha256:$statePlaintextSha256,configurationPlaintextSha256:$configurationPlaintextSha256}' > "$private/manifest.json"
# Reserve a new destination; never overwrite an existing recovery generation.
mkdir "$output" 2>/dev/null || state_fail destination
owned_output=true
for file in state.json.age configuration.json.age manifest.json; do cp "$private/$file" "$output/$file" 2>/dev/null || state_fail publication; done
bash "$script_dir/check-state-recovery-package.sh" "$root" "$output" >/dev/null 2>&1 || state_fail publication
prepared=true
printf '%s\n' 'CLOUDFLARE_STATE_RECOVERY=PREPARED verification=required'
