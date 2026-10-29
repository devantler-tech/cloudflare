#!/usr/bin/env bash
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
age-keygen -o "$scratch/key" 2>/dev/null
age-keygen -o "$scratch/wrong-key" 2>/dev/null
recipient=$(age-keygen -y "$scratch/key")
mkdir -p "$scratch/base/recovery" "$scratch/base/.github"
printf '%s\n' "$recipient" > "$scratch/base/.github/dns-recovery-recipient.txt"
printf '%s\n' '{"fixture":"owned synthetic recovery payload"}' > "$scratch/payload"
age --encrypt -r "$recipient" -o "$scratch/base/recovery/dns-snapshot.json.age" "$scratch/payload"
digest=$(shasum -a 256 "$scratch/base/recovery/dns-snapshot.json.age")
jq -n --arg recipient "$recipient" --arg digest "${digest%% *}" \
  '{schemaVersion:1,kind:"cloudflare-dns-recovery",capturedAt:"2026-10-26T06:00:00Z",sourceCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",sourceRun:40282002745,recipient:$recipient,ciphertextSha256:$digest}' \
  > "$scratch/base/recovery/manifest.json"
age --decrypt -i "$scratch/key" "$scratch/base/recovery/dns-snapshot.json.age" 2>/dev/null | cmp - "$scratch/payload"
if age --decrypt -i "$scratch/wrong-key" "$scratch/base/recovery/dns-snapshot.json.age" > "$scratch/wrong-output" 2>/dev/null; then
  printf '%s\n' 'FAIL: unrelated identity decrypted synthetic recovery' >&2
  exit 1
fi
# Mutate one binding at a time and require the checker to fail closed.
run_case() {
  local scenario=$1 expected=$2 rc=0
  local case_dir="$scratch/$scenario"
  cp -R "$scratch/base" "$case_dir"
  case "$scenario" in
    damaged) printf 'x' >> "$case_dir/recovery/dns-snapshot.json.age" ;;
    plaintext|fake-header|header-only|nonce-only)
      if [[ "$scenario" == fake-header ]]; then
        { printf '%s\n' age-encryption.org/v1; cat "$scratch/payload" "$scratch/payload" "$scratch/payload"; } > "$case_dir/recovery/dns-snapshot.json.age"
      elif [[ "$scenario" == header-only || "$scenario" == nonce-only ]]; then
        head -n 4 "$scratch/base/recovery/dns-snapshot.json.age" > "$case_dir/recovery/dns-snapshot.json.age"
        if [[ "$scenario" == nonce-only ]]; then
          printf '0123456789abcdef' >> "$case_dir/recovery/dns-snapshot.json.age"
        fi
      else
        cp "$scratch/payload" "$case_dir/recovery/dns-snapshot.json.age"
      fi
      digest=$(shasum -a 256 "$case_dir/recovery/dns-snapshot.json.age")
      jq --arg digest "${digest%% *}" '.ciphertextSha256=$digest' "$case_dir/recovery/manifest.json" > "$case_dir/updated"
      mv "$case_dir/updated" "$case_dir/recovery/manifest.json" ;;
    wrong-recipient)
      jq --arg recipient "$(age-keygen -y "$scratch/wrong-key")" '.recipient=$recipient' "$case_dir/recovery/manifest.json" > "$case_dir/updated"
      mv "$case_dir/updated" "$case_dir/recovery/manifest.json" ;;
    recipient-extra) printf 'unterminated' >> "$case_dir/.github/dns-recovery-recipient.txt" ;;
    recipient-blank-line) printf '\n' >> "$case_dir/.github/dns-recovery-recipient.txt" ;;
    recipient-no-newline) printf '%s' "$recipient" > "$case_dir/.github/dns-recovery-recipient.txt" ;;
    extra-file) printf '%s\n' 'synthetic private material' > "$case_dir/recovery/private-key.txt" ;;
    symlink)
      rm "$case_dir/recovery/dns-snapshot.json.age"
      ln -s "$scratch/base/recovery/dns-snapshot.json.age" "$case_dir/recovery/dns-snapshot.json.age" ;;
    duplicate-field)
      { printf '{"schemaVersion":2,'; tail -c +2 "$case_dir/recovery/manifest.json"; } > "$case_dir/updated"
      mv "$case_dir/updated" "$case_dir/recovery/manifest.json" ;;
    extra-document) cat "$scratch/base/recovery/manifest.json" >> "$case_dir/recovery/manifest.json" ;;
    unknown-field)
      jq '.unexpected="synthetic"' "$case_dir/recovery/manifest.json" > "$case_dir/updated"
      mv "$case_dir/updated" "$case_dir/recovery/manifest.json" ;;
    missing-field)
      jq 'del(.sourceRun)' "$case_dir/recovery/manifest.json" > "$case_dir/updated"
      mv "$case_dir/updated" "$case_dir/recovery/manifest.json" ;;
  esac
  bash "$repo_root/scripts/check-recovery-package.sh" "$case_dir" > "$scratch/result" 2>&1 || rc=$?
  if [[ "$expected" == pass ]]; then
    if [[ "$rc" != 0 ]] || ! grep -qx 'CLOUDFLARE_RECOVERY_PACKAGE=CHECKED format=age_v1 checksum=match' "$scratch/result"; then
      printf 'FAIL: %s must pass\n' "$scenario" >&2
      cat "$scratch/result" >&2
      exit 1
    fi
  else
    if [[ "$rc" != 2 ]] || ! grep -qx 'CLOUDFLARE_RECOVERY_PACKAGE=UNVERIFIED stage=[a-z-]*' "$scratch/result"; then
      printf 'FAIL: %s must refuse\n' "$scenario" >&2
      exit 1
    fi
  fi
}
run_case valid pass
for scenario in damaged plaintext fake-header header-only nonce-only wrong-recipient recipient-extra recipient-blank-line recipient-no-newline extra-file symlink duplicate-field extra-document unknown-field missing-field; do
  run_case "$scenario" refuse
done
printf '%s\n' 'PASS: recovery package bindings and plaintext refusals'
