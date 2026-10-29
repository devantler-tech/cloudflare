#!/usr/bin/env bash
# Check the retained package's public bindings and digest without a private key.
# Actual authenticated decryption remains a separate operator recovery proof.
set +x
set -euo pipefail
fail() { printf 'CLOUDFLARE_RECOVERY_PACKAGE=UNVERIFIED stage=%s\n' "$1" >&2; exit 2; }
[[ $# == 1 ]] || fail arguments
root=$1
[[ -d "$root/recovery" && ! -L "$root/recovery" && -d "$root/.github" && ! -L "$root/.github" ]] || fail directory
shopt -s dotglob nullglob
files=("$root/recovery/"*)
[[ ${#files[@]} == 2 ]] || fail inventory
manifest="$root/recovery/manifest.json"
ciphertext="$root/recovery/dns-snapshot.json.age"
recipient_file="$root/.github/dns-recovery-recipient.txt"
for file in "$manifest" "$ciphertext" "$recipient_file"; do
  [[ -f "$file" && ! -L "$file" ]] || fail file
done
[[ $(wc -l < "$recipient_file") -eq 1 ]] || fail recipient
IFS= read -r recipient < "$recipient_file" || fail recipient
[[ "$recipient" =~ ^age1[0-9a-z]{58}$ ]] || fail recipient
[[ $(wc -c < "$manifest") -le 2048 ]] || fail manifest-size
# Streaming retains duplicate keys that an ordinary JSON object decoder loses.
jq --stream -s -e '
  [.[] | select(length == 2) | .[0]] as $paths |
  ($paths | length) == 7 and ($paths | unique | length) == 7 and
  all($paths[]; length == 1)
' "$manifest" >/dev/null 2>&1 || fail manifest-keys
jq -s -e --arg recipient "$recipient" '
  length == 1 and (.[0] |
    keys == ["capturedAt","ciphertextSha256","kind","recipient","schemaVersion","sourceCommit","sourceRun"] and
    .schemaVersion == 1 and .kind == "cloudflare-dns-recovery" and
    .recipient == $recipient and
    (.capturedAt | type == "string") and
    (.capturedAt | fromdateiso8601 | todateiso8601) == .capturedAt and
    (.sourceCommit | type == "string" and test("^[0-9a-f]{40}$")) and
    (.sourceRun | type == "number") and .sourceRun > 0 and
    .sourceRun < 9007199254740992 and .sourceRun == (.sourceRun | floor) and
    (.ciphertextSha256 | type == "string" and test("^[0-9a-f]{64}$")))
' "$manifest" >/dev/null 2>&1 || fail manifest
size=$(wc -c < "$ciphertext")
[[ "$size" -ge 128 && "$size" -le 33554432 ]] || fail ciphertext-size
{
  IFS= read -r magic && IFS= read -r stanza &&
    IFS= read -r wrapped && IFS= read -r mac
} < "$ciphertext" || fail ciphertext-format
# The producer emits one native X25519 stanza. A magic line alone could prefix
# plaintext; refuse other stanza profiles rather than claiming they were checked.
stanza_pattern='^-> X25519 [A-Za-z0-9+/]{43}$'
mac_pattern='^--- [A-Za-z0-9+/]{43}$'
[[ "$magic" == age-encryption.org/v1 && "$stanza" =~ $stanza_pattern &&
  "$wrapped" =~ ^[A-Za-z0-9+/]{43}$ && "$mac" =~ $mac_pattern ]] || fail ciphertext-format
digest=$(shasum -a 256 "$ciphertext") || fail checksum
expected=$(jq -er .ciphertextSha256 "$manifest") || fail checksum
[[ "${digest%% *}" == "$expected" ]] || fail checksum
printf '%s\n' 'CLOUDFLARE_RECOVERY_PACKAGE=CHECKED format=age_v1 checksum=match'
