#!/usr/bin/env bash
# CHECKED is public structure only. VERIFIED additionally authenticates both
# files and their paired state/configuration bindings using an independent key.
# Neither result initializes a backend or proves a clean provider plan.
set +x
set -euo pipefail
umask 077
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
[[ $# == 2 || ( $# == 4 && $3 == --identity-file ) ]] || state_fail arguments
root=$1 package=$2
[[ -d "$root" && ! -L "$root" && -d "$package" && ! -L "$package" ]] || state_fail directory
recipient=$(state_recipient "$root")
shopt -s dotglob nullglob
files=("$package/"*)
[[ ${#files[@]} == 3 ]] || state_fail inventory
for name in manifest.json state.json.age configuration.json.age; do [[ -f "$package/$name" && ! -L "$package/$name" ]] || state_fail file; done
manifest="$package/manifest.json"
[[ $(wc -c < "$manifest") -le 4096 ]] || state_fail manifest-size
state_unique_json "$manifest" || state_fail manifest-json
jq -e --arg recipient "$recipient" '
  keys==["accountIdSha256","capturedAt","configurationCiphertextSha256","configurationPlaintextSha256","kind","lineage","recipient","schemaVersion","serial","sourceCommit","sourceRun","stateCiphertextSha256","statePlaintextSha256","zoneNameSha256"] and
  .schemaVersion==1 and .kind=="cloudflare-state-recovery" and .recipient==$recipient and
  (.capturedAt|type=="string") and (.capturedAt|fromdateiso8601|todateiso8601)==.capturedAt and
  (.sourceCommit|type=="string" and test("^[a-f0-9]{40}$")) and
  (.sourceRun|type=="number" and .>0 and .<9007199254740992 and .==floor) and
  (.lineage|type=="string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")) and
  (.serial|type=="number" and .>=0 and .<9007199254740992 and .==floor) and
  all(.accountIdSha256,.zoneNameSha256,.stateCiphertextSha256,.configurationCiphertextSha256,.statePlaintextSha256,.configurationPlaintextSha256; type=="string" and test("^[a-f0-9]{64}$"))
' "$manifest" >/dev/null 2>&1 || state_fail manifest
state_cipher "$package/state.json.age" "$(jq -er .stateCiphertextSha256 "$manifest")"
state_cipher "$package/configuration.json.age" "$(jq -er .configurationCiphertextSha256 "$manifest")"
if [[ $# == 2 ]]; then printf '%s\n' 'CLOUDFLARE_STATE_RECOVERY=CHECKED verification=required'; exit 0; fi
identity=$4
[[ "$identity" == /* && -f "$identity" && ! -L "$identity" ]] || state_fail identity
case "$(uname -s)" in
  Darwin) identity_stat=$(stat -f '%u %Lp' "$identity" 2>/dev/null) || state_fail identity ;;
  Linux) identity_stat=$(stat -c '%u %a' "$identity" 2>/dev/null) || state_fail identity ;;
  *) state_fail identity-platform ;;
esac
[[ "$identity_stat" == "$(id -u) 600" ]] || state_fail identity
# Do not copy the key, read its value into a shell variable or give it as argv.
private=$(mktemp -d)
trap 'rm -rf "$private"' EXIT
trap 'exit 2' INT TERM
age --decrypt -i "$identity" "$package/state.json.age" > "$private/state.json" 2>/dev/null || state_fail authentication
age --decrypt -i "$identity" "$package/configuration.json.age" > "$private/configuration.json" 2>/dev/null || state_fail authentication
state_payloads "$private/state.json" "$private/configuration.json"
[[ $(state_hash "$private/state.json") == "$(jq -er .statePlaintextSha256 "$manifest")" && $(state_hash "$private/configuration.json") == "$(jq -er .configurationPlaintextSha256 "$manifest")" ]] || state_fail payload-checksum
[[ $(jq -er .lineage "$private/state.json") == "$(jq -er .lineage "$manifest")" && $(jq -er .serial "$private/state.json") == "$(jq -er .serial "$manifest")" ]] || state_fail state-binding
jq -jr .account_id "$private/configuration.json" > "$private/account"
jq -jr .zone_name "$private/configuration.json" > "$private/zone"
[[ $(state_hash "$private/account") == "$(jq -er .accountIdSha256 "$manifest")" && $(state_hash "$private/zone") == "$(jq -er .zoneNameSha256 "$manifest")" ]] || state_fail configuration-binding
printf '%s\n' 'CLOUDFLARE_STATE_RECOVERY=VERIFIED scope=authenticated-files'
