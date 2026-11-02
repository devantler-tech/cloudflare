#!/usr/bin/env bash
# Decode approved DATA, never a recovery key. This performs no provider operation.
set -euo pipefail
umask 077
set +x
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
# Refuse with a fixed label; the owned-output trap removes partial decoded bytes.
fail() { printf 'CLOUDFLARE_BOOTSTRAP_INPUT=UNVERIFIED stage=%s\n' "$1" >&2; exit 2; }
[[ $# == 3 ]] || fail arguments
root=$1 input=$2 destination=$3
approval="$root/.github/bootstrap-plan-approval.json"
manifest="$root/recovery/state/manifest.json"
[[ -f "$input" && ! -L "$input" && -f "$approval" && ! -L "$approval" && ! -e "$destination" && ! -L "$destination" ]] || fail files
[[ $(wc -c < "$input") -le 49152 ]] || fail size
if ! state_unique_json "$input" || ! state_unique_json "$approval"; then fail json; fi
bash "$script_dir/check-state-recovery-package.sh" "$root" "$root/recovery/state" >/dev/null 2>&1 || fail retained-generation
jq -e --slurpfile state "$manifest" '
  .schemaVersion==1 and .kind=="cloudflare-state-bootstrap-plan" and
  .sourceCommit==$state[0].sourceCommit and .sourceRun==$state[0].sourceRun and
  .resourceCreates==1 and .resourceUpdates==0 and .resourceDeletes==0 and
  all(.stateManifestSha256,.binaryPlaintextSha256,.jsonPlaintextSha256;type=="string" and test("^[a-f0-9]{64}$"))
' "$approval" >/dev/null 2>&1 || fail approval
[[ $(state_hash "$manifest") == "$(jq -r .stateManifestSha256 "$approval")" ]] || fail generation-binding
jq -e 'keys==["configuration","plan","planJson","state"] and all(.[];type=="string" and length>0 and test("^[A-Za-z0-9+/]+={0,2}$"))' "$input" >/dev/null 2>&1 || fail envelope
mkdir -m 700 "$destination" || fail destination
complete=false
trap 'if [[ $complete != true ]]; then rm -rf "$destination"; fi' EXIT
for pair in state:state.json configuration:configuration.json plan:plan planJson:plan.json; do
  key=${pair%%:*} file=${pair#*:}
  jq -r --arg key "$key" '.[$key]' "$input" | base64 --decode > "$destination/$file" 2>/dev/null || fail encoding
done
[[ $(state_hash "$destination/state.json") == "$(jq -r .statePlaintextSha256 "$manifest")" &&
   $(state_hash "$destination/configuration.json") == "$(jq -r .configurationPlaintextSha256 "$manifest")" &&
   $(state_hash "$destination/plan") == "$(jq -r .binaryPlaintextSha256 "$approval")" &&
   $(state_hash "$destination/plan.json") == "$(jq -r .jsonPlaintextSha256 "$approval")" ]] || fail approved-bytes
state_payloads "$destination/state.json" "$destination/configuration.json"
complete=true
printf '%s\n' 'CLOUDFLARE_BOOTSTRAP_INPUT=VERIFIED provider_writes=0'
