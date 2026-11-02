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
