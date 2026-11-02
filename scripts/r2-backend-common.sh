#!/usr/bin/env bash
# Pure validation shared by the confirmed backend proof and its negative tests.
# shellcheck source=scripts/state-recovery-common.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/state-recovery-common.sh"
# gh trims final line endings from stdin secrets. Restore only a missing native
# JSON capture LF; authentication still requires the full reviewed byte digest.
backend_configuration_input() {
  jq -Rsje 'if endswith("\n") then . else . + "\n" end'
}
# Bind private configuration bytes to the reviewed encrypted capture before
# deriving any provider account or backend destination from those values.
backend_configuration() {
  local root=$1 file=$2 package="$1/recovery/backend-source"
  [[ -f "$file" && ! -L "$file" && $(wc -c < "$file") -le 8388608 ]] || return 1
  bash "$root/scripts/check-state-recovery-package.sh" "$root" "$package" >/dev/null 2>&1 || return 1
  [[ $(state_hash "$file") == "$(jq -er .configurationPlaintextSha256 "$package/manifest.json")" ]] || return 1
  state_unique_json "$file" || return 1
  jq -e '
    keys==["account_id","account_tokens","dns_records","r2_buckets","r2_lifecycle_rules","zone_name"] and
    (.account_id|type=="string" and test("^[a-f0-9]{32}$")) and
    (.r2_buckets|keys)==["cloudflare-bootstrap-state"]
  ' "$file" >/dev/null 2>&1
}
# Decode one captured state through stdin. Base64 avoids transport trimming;
# the registered full byte digest remains mandatory before producing a file.
backend_migration_state() (
  set -euo pipefail
  local migration_root=$1 migration_configuration=$2 migration_output=$3 migration_private
  [[ ! -e "$migration_output" && ! -L "$migration_output" ]] || return 1
  backend_configuration "$migration_root" "$migration_configuration" || return 1
  migration_private=$(mktemp -d)
  trap 'rm -rf "$migration_private"' EXIT
  # Bound the input before buffering it; no partial accepted file is exposed.
  head -c 49153 > "$migration_private/input"
  [[ $(wc -c < "$migration_private/input") -le 49152 ]] || return 1
  jq -Rsje 'select(length>0 and test("^[A-Za-z0-9+/]*={0,2}$")) |
    . as $encoded | @base64d | select((@base64)==$encoded)' "$migration_private/input" > "$migration_private/state.json" 2>/dev/null || return 1
  [[ $(state_hash "$migration_private/state.json") == "$(jq -er .statePlaintextSha256 "$migration_root/recovery/backend-source/manifest.json")" ]] || return 1
  state_payloads "$migration_private/state.json" "$migration_configuration"
  (set -o noclobber; cat "$migration_private/state.json" > "$migration_output") 2>/dev/null || return 1
)
# Require an actual successful first-attempt proof from this same reviewed main.
backend_proof_run() {
  local proof_file=$1 proof_source=$2 proof_id=$3 migration_id=$4
  [[ $proof_source =~ ^[a-f0-9]{40}$ && $proof_id =~ ^[1-9][0-9]{5,15}$ &&
    $migration_id =~ ^[1-9][0-9]{5,15}$ && $proof_id != "$migration_id" &&
    -f $proof_file && ! -L $proof_file && $(wc -c < "$proof_file") -le 1048576 ]] || return 1
  state_unique_json "$proof_file" || return 1
  jq -e --arg source "$proof_source" --arg run "$proof_id" '
    (.id|tostring)==$run and .head_sha==$source and .head_branch=="main" and
    .event=="workflow_dispatch" and .path==".github/workflows/state-backend-proof.yaml" and
    .actor.login=="devantler" and .run_attempt==1 and
    .status=="completed" and .conclusion=="success"
  ' "$proof_file" >/dev/null 2>&1
}
# Admit only one unambiguous, bounded native temporary-credential response.
# Reject missing/extra fields and unsafe header characters without printing it.
backend_session() {
  local file=$1
  [[ -f "$file" && ! -L "$file" && $(wc -c < "$file") -le 32768 ]] || return 1
  state_unique_json "$file" || return 1
  jq -e '
    .success==true and (.errors==null or .errors==[]) and
    (.result|keys)==["accessKeyId","secretAccessKey","sessionToken"] and
    (.result.accessKeyId|type=="string" and test("^[a-f0-9]{32}$")) and
    (.result.secretAccessKey|type=="string" and test("^[a-f0-9]{64}$")) and
    (.result.sessionToken|type=="string" and length>=16 and length<=6144 and test("^[A-Za-z0-9._~+/=-]+$"))
  ' "$file" >/dev/null 2>&1
}
