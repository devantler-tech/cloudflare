#!/usr/bin/env bash
# Shared local-file checks; never contacts a provider or prints payloads.
state_fail() { printf 'CLOUDFLARE_STATE_RECOVERY=UNVERIFIED stage=%s\n' "$1" >&2; exit 2; }
state_hash() { local value; value=$(shasum -a 256 "$1" 2>/dev/null) || state_fail checksum; printf '%s' "${value%% *}"; }
state_unique_json() {
  # A stream's closing entry names the last child: its parent is the object or
  # array just closed. Include that parent as well as leaves, otherwise two
  # duplicate objects with disjoint children evade the duplicate-key check.
  jq --stream -s -e '[.[] | if length == 2 then .[0] else .[0][:-1] end] as $paths | ($paths|length)==($paths|unique|length)' "$1" >/dev/null 2>&1 &&
    jq -s -e 'length==1 and (.[0]|type=="object")' "$1" >/dev/null 2>&1
}
state_payloads() {
  if ! state_unique_json "$1" || ! state_unique_json "$2"; then state_fail payload-json; fi
  jq -e '
    .version==4 and (.terraform_version|type=="string" and length>0) and
    (.lineage|type=="string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")) and
    (.serial|type=="number" and .>=0 and .<9007199254740992 and .==floor) and
    (.resources|type=="array") and (.outputs|type=="object")
  ' "$1" >/dev/null 2>&1 || state_fail state-payload
  jq -e '
    keys==["account_id","account_tokens","dns_records","r2_buckets","r2_lifecycle_rules","zone_name"] and
    (.account_id|type=="string" and test("^[a-f0-9]{32}$")) and
    (.zone_name|type=="string" and test("^[a-z0-9][a-z0-9.-]{0,252}$")) and
    all(.dns_records,.r2_buckets,.r2_lifecycle_rules,.account_tokens; type=="object")
  ' "$2" >/dev/null 2>&1 || state_fail configuration-payload
  # The repository's canonical zone must bind the same account and zone as the
  # desired variables. Hashes of two unrelated valid files are not a pair.
  jq -e --slurpfile configuration "$2" '
    [.resources[]|select(.mode=="managed" and .type=="cloudflare_zone" and .name=="primary" and (has("module")|not))] as $zones |
    ($zones|length)==1 and ($zones[0].instances|length)==1 and
    $zones[0].instances[0].attributes.name==$configuration[0].zone_name and
    $zones[0].instances[0].attributes.account.id==$configuration[0].account_id
  ' "$1" >/dev/null 2>&1 || state_fail configuration-binding
}
state_recipient() {
  local file="$1/.github/dns-recovery-recipient.txt" recipient
  [[ -d "$1/.github" && ! -L "$1/.github" && -f "$file" && ! -L "$file" ]] || state_fail recipient
  IFS= read -r recipient < "$file" || state_fail recipient
  if [[ ! "$recipient" =~ ^age1[0-9a-z]{58}$ ]] || ! cmp -s "$file" <(printf '%s\n' "$recipient"); then state_fail recipient; fi
  printf '%s' "$recipient"
}
state_cipher() {
  local file=$1 expected=$2 size magic stanza wrapped mac
  [[ -f "$file" && ! -L "$file" ]] || state_fail file
  size=$(wc -c < "$file")
  [[ "$size" -ge 200 && "$size" -le 33554432 ]] || state_fail ciphertext-size
  { IFS= read -r magic && IFS= read -r stanza && IFS= read -r wrapped && IFS= read -r mac; } < "$file" || state_fail ciphertext-format
  [[ "$magic" == age-encryption.org/v1 && "$stanza" =~ ^'-> X25519 '[A-Za-z0-9+/]{43}$ && "$wrapped" =~ ^[A-Za-z0-9+/]{43}$ && "$mac" =~ ^'--- '[A-Za-z0-9+/]{43}$ ]] || state_fail ciphertext-format
  [[ $(state_hash "$file") == "$expected" ]] || state_fail checksum
}
