#!/usr/bin/env bash
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
umask 077
age-keygen -o "$scratch/identity" 2>/dev/null
age-keygen -o "$scratch/wrong-identity" 2>/dev/null
mkdir "$scratch/root" "$scratch/root/.github"
age-keygen -y "$scratch/identity" > "$scratch/root/.github/dns-recovery-recipient.txt"
printf '%s\n' '{"version":4,"terraform_version":"1.12.6","serial":7,"lineage":"12345678-1234-1234-1234-123456789abc","outputs":{"fixture":{"sensitive":true,"type":"string","value":"SYNTHETIC_STATE_SECRET"}},"resources":[{"mode":"managed","type":"cloudflare_zone","name":"primary","instances":[{"attributes":{"name":"example.invalid","account":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}]}]}' > "$scratch/state.json"
printf '%s\n' '{"account_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","zone_name":"example.invalid","dns_records":{},"r2_buckets":{},"r2_lifecycle_rules":{},"account_tokens":{}}' > "$scratch/config.json"
if [[ ! -f "$repo_root/scripts/prepare-state-recovery-package.sh" ]]; then
  printf '%s\n' 'FAIL: state recovery package producer is missing' >&2
  exit 1
fi
bash "$repo_root/scripts/prepare-state-recovery-package.sh" "$scratch/root" "$scratch/state.json" "$scratch/config.json" "$scratch/package" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123456789 2026-11-01T19:00:00Z > "$scratch/result" 2>&1
grep -qx 'CLOUDFLARE_STATE_RECOVERY=PREPARED verification=required' "$scratch/result"
bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" > "$scratch/result" 2>&1
grep -qx 'CLOUDFLARE_STATE_RECOVERY=CHECKED verification=required' "$scratch/result"
bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/identity" > "$scratch/result" 2>&1
grep -qx 'CLOUDFLARE_STATE_RECOVERY=VERIFIED scope=authenticated-files' "$scratch/result"

# The repository checker admits only this exact nested encrypted package, while
# preserving the existing DNS package and rejecting extra plaintext files.
mkdir "$scratch/root/recovery"
printf '%s\n' '{"fixture":"historical DNS"}' > "$scratch/dns.json"
age --encrypt -r "$(age-keygen -y "$scratch/identity")" -o "$scratch/root/recovery/dns-snapshot.json.age" "$scratch/dns.json"
digest=$(shasum -a 256 "$scratch/root/recovery/dns-snapshot.json.age")
jq -n --arg recipient "$(age-keygen -y "$scratch/identity")" --arg digest "${digest%% *}" '{schemaVersion:1,kind:"cloudflare-dns-recovery",capturedAt:"2026-11-01T19:00:00Z",sourceCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",sourceRun:123456789,recipient:$recipient,ciphertextSha256:$digest}' > "$scratch/root/recovery/manifest.json"
cp -R "$scratch/package" "$scratch/root/recovery/state"
bash "$repo_root/scripts/check-recovery-package.sh" "$scratch/root" > "$scratch/result" 2>&1
grep -qx 'CLOUDFLARE_RECOVERY_PACKAGE=CHECKED format=age_v1 checksum=match' "$scratch/result"
cp "$scratch/state.json" "$scratch/root/recovery/state/plaintext.json"
if bash "$repo_root/scripts/check-recovery-package.sh" "$scratch/root" > "$scratch/result" 2>&1; then
  printf '%s\n' 'FAIL: retained state layout admitted plaintext' >&2; exit 1
fi

refuse() {
  local rc=0
  "$@" > "$scratch/result" 2>&1 || rc=$?
  if [[ "$rc" != 2 ]] || ! grep -qx 'CLOUDFLARE_STATE_RECOVERY=UNVERIFIED stage=[a-z-]*' "$scratch/result"; then printf '%s\n' 'FAIL: unsafe recovery package did not refuse safely' >&2; exit 1; fi
}
refuse bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/wrong-identity"
refuse bash "$repo_root/scripts/prepare-state-recovery-package.sh" "$scratch/root" "$scratch/state.json" "$scratch/config.json" "$scratch/package" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123456789 2026-11-01T19:00:00Z
bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/identity" > "$scratch/result" 2>&1
grep -qx 'CLOUDFLARE_STATE_RECOVERY=VERIFIED scope=authenticated-files' "$scratch/result"
cp "$scratch/identity" "$scratch/exposed-identity"
chmod 0644 "$scratch/exposed-identity"
refuse bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/exposed-identity"
# A valid ciphertext can lie about its recipient in the public manifest. A key
# that decrypts it is insufficient unless that key is the reviewed recipient.
cp -R "$scratch/package" "$scratch/recipient-lie"
for file in state configuration; do
  rm "$scratch/recipient-lie/$file.json.age"
  input="$scratch/state.json"; [[ "$file" != configuration ]] || input="$scratch/config.json"
  age --encrypt -r "$(age-keygen -y "$scratch/wrong-identity")" -o "$scratch/recipient-lie/$file.json.age" "$input"
  digest=$(shasum -a 256 "$scratch/recipient-lie/$file.json.age")
  jq --arg key "${file}CiphertextSha256" --arg digest "${digest%% *}" '.[$key]=$digest' "$scratch/recipient-lie/manifest.json" > "$scratch/update"
  mv "$scratch/update" "$scratch/recipient-lie/manifest.json"
done
refuse bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/recipient-lie" --identity-file "$scratch/wrong-identity"
# Ordinary SOPS identity stores can hold several independent identities. Select
# only the reviewed one, even when an unrelated key could decrypt a lying file.
cat "$scratch/wrong-identity" "$scratch/identity" > "$scratch/multiple-identities"
bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/multiple-identities" > "$scratch/result" 2>&1
grep -qx 'CLOUDFLARE_STATE_RECOVERY=VERIFIED scope=authenticated-files' "$scratch/result"
refuse bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/recipient-lie" --identity-file "$scratch/multiple-identities"
cat "$scratch/identity" "$scratch/wrong-identity" > "$scratch/reversed-identities"
bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/reversed-identities" > "$scratch/result" 2>&1
grep -qx 'CLOUDFLARE_STATE_RECOVERY=VERIFIED scope=authenticated-files' "$scratch/result"
cat "$scratch/identity" "$scratch/identity" > "$scratch/duplicate-identities"
refuse bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/duplicate-identities"
cat "$scratch/identity" > "$scratch/unknown-identities"
printf '%s\n' 'AGE-PLUGIN-UNTRUSTED-FIXTURE' >> "$scratch/unknown-identities"
refuse bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/package" --identity-file "$scratch/unknown-identities"
for scenario in lineage serial digest duplicate extra-file symlink plaintext wrong-recipient; do
  cp -R "$scratch/package" "$scratch/$scenario"
  case "$scenario" in
    lineage) jq '.lineage="ffffffff-ffff-ffff-ffff-ffffffffffff"' "$scratch/$scenario/manifest.json" > "$scratch/update"; mv "$scratch/update" "$scratch/$scenario/manifest.json" ;;
    serial) jq '.serial=8' "$scratch/$scenario/manifest.json" > "$scratch/update"; mv "$scratch/update" "$scratch/$scenario/manifest.json" ;;
    digest) printf 'x' >> "$scratch/$scenario/state.json.age" ;;
    duplicate) { printf '{"serial":8,'; tail -c +2 "$scratch/$scenario/manifest.json"; } > "$scratch/update"; mv "$scratch/update" "$scratch/$scenario/manifest.json" ;;
    extra-file) cp "$scratch/state.json" "$scratch/$scenario/state.json" ;;
    symlink) rm "$scratch/$scenario/state.json.age"; ln -s "$scratch/package/state.json.age" "$scratch/$scenario/state.json.age" ;;
    plaintext) cp "$scratch/state.json" "$scratch/$scenario/state.json.age" ;;
    wrong-recipient) jq --arg recipient "$(age-keygen -y "$scratch/wrong-identity")" '.recipient=$recipient' "$scratch/$scenario/manifest.json" > "$scratch/update"; mv "$scratch/update" "$scratch/$scenario/manifest.json" ;;
  esac
  refuse bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$scratch/$scenario" --identity-file "$scratch/identity"
done
# No malformed input may leave a partial ciphertext package behind.
for scenario in bad-version fractional-serial empty-lineage duplicate-payload duplicate-nested-state duplicate-nested-configuration scalar-object-collision missing-configuration state-zone-mismatch state-account-mismatch missing-zone; do
  cp "$scratch/state.json" "$scratch/input.json"
  configuration="$scratch/config.json"
  case "$scenario" in
    bad-version) jq '.version=3' "$scratch/input.json" > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    fractional-serial) jq '.serial=1.5' "$scratch/input.json" > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    empty-lineage) jq '.lineage=""' "$scratch/input.json" > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    duplicate-payload) { printf '{"serial":8,'; tail -c +2 "$scratch/input.json"; } > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    duplicate-nested-state) { printf '{"outputs":{"shadow":{"value":"synthetic"}},'; tail -c +2 "$scratch/input.json"; } > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    duplicate-nested-configuration) configuration="$scratch/duplicate-config.json"; { printf '{"dns_records":{"shadow":{"content":"synthetic"}},'; tail -c +2 "$scratch/config.json"; } > "$configuration" ;;
    scalar-object-collision) { printf '{"outputs":0,'; tail -c +2 "$scratch/input.json"; } > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    missing-configuration) configuration="$scratch/not-present.json" ;;
    state-zone-mismatch) jq '.resources[0].instances[0].attributes.name="other.invalid"' "$scratch/input.json" > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    state-account-mismatch) jq '.resources[0].instances[0].attributes.account.id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$scratch/input.json" > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
    missing-zone) jq '.resources=[]' "$scratch/input.json" > "$scratch/update"; mv "$scratch/update" "$scratch/input.json" ;;
  esac
  refuse bash "$repo_root/scripts/prepare-state-recovery-package.sh" "$scratch/root" "$scratch/input.json" "$configuration" "$scratch/partial-$scenario" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123456789 2026-11-01T19:00:00Z
  [[ ! -e "$scratch/partial-$scenario" ]] || { printf '%s\n' 'FAIL: producer published a partial package'; exit 1; }
done
printf '%s\n' 'PASS: authenticated state/configuration recovery and unsafe-package refusals'
