#!/usr/bin/env bash
# Native file/authentication boundaries only; no provider or GitHub calls.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/repo/.github" "$scratch/repo/recovery"
cp "$root/.github/dns-recovery-recipient.txt" "$scratch/repo/.github/"
cp -R "$root/scripts" "$scratch/repo/"
printf '%s\n' '{"account_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","zone_name":"devantler.tech","dns_records":{},"r2_buckets":{"cloudflare-bootstrap-state":{"jurisdiction":"default","storage_class":"Standard"}},"r2_lifecycle_rules":{},"account_tokens":{}}' > "$scratch/configuration.json"
printf '%s\n' '{"version":4,"terraform_version":"1.12.6","lineage":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","serial":1,"outputs":{},"resources":[{"mode":"managed","type":"cloudflare_zone","name":"primary","instances":[{"attributes":{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"devantler.tech","account":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}]}]}' > "$scratch/state.json"
printf '%s\n' 'PRIVATE_SYNTHETIC_BINARY_PLAN' > "$scratch/plan"
printf '%s\n' 'PRIVATE_SYNTHETIC_PLAN_JSON' > "$scratch/plan.json"
bash "$root/scripts/prepare-state-recovery-package.sh" "$scratch/repo" "$scratch/state.json" "$scratch/configuration.json" "$scratch/repo/recovery/state" 1111111111111111111111111111111111111111 123456789 2026-11-02T00:00:00Z >/dev/null
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
jq -n --arg manifest "$(hash "$scratch/repo/recovery/state/manifest.json")" --arg binary "$(hash "$scratch/plan")" --arg json "$(hash "$scratch/plan.json")" \
  '{schemaVersion:1,kind:"cloudflare-state-bootstrap-plan",sourceCommit:"1111111111111111111111111111111111111111",sourceRun:123456789,stateManifestSha256:$manifest,binaryPlaintextSha256:$binary,jsonPlaintextSha256:$json,resourceCreates:1,resourceUpdates:0,resourceDeletes:0}' > "$scratch/repo/.github/bootstrap-plan-approval.json"
encode() { base64 < "$1" | tr -d '\n'; }
jq -n --arg state "$(encode "$scratch/state.json")" --arg configuration "$(encode "$scratch/configuration.json")" --arg plan "$(encode "$scratch/plan")" --arg planJson "$(encode "$scratch/plan.json")" \
  '{state:$state,configuration:$configuration,plan:$plan,planJson:$planJson}' > "$scratch/input.json"
bash "$root/scripts/decode-bootstrap-apply-input.sh" "$scratch/repo" "$scratch/input.json" "$scratch/accepted" > "$scratch/stdout" 2> "$scratch/stderr"
for file in state.json configuration.json plan plan.json; do cmp "$scratch/$file" "$scratch/accepted/$file"; done
if grep -q PRIVATE_SYNTHETIC "$scratch/stdout" "$scratch/stderr"; then exit 1; fi

refuse() {
  rm -rf "$scratch/refused"
  if bash "$root/scripts/decode-bootstrap-apply-input.sh" "$scratch/repo" "$1" "$scratch/refused" > "$scratch/stdout" 2> "$scratch/stderr"; then
    printf 'FAIL: accepted %s\n' "$2" >&2; exit 1
  fi
  test ! -e "$scratch/refused"
  if grep -q PRIVATE_SYNTHETIC "$scratch/stdout" "$scratch/stderr"; then exit 1; fi
}
for key in state configuration plan planJson; do
  jq --arg key "$key" '.[$key]="Y29ycnVwdGVk"' "$scratch/input.json" > "$scratch/corrupt.json"
  refuse "$scratch/corrupt.json" "changed $key"
done
jq '.extra="unexpected"' "$scratch/input.json" > "$scratch/corrupt.json"
refuse "$scratch/corrupt.json" extra-key
jq '.plan="%%%"' "$scratch/input.json" > "$scratch/corrupt.json"
refuse "$scratch/corrupt.json" malformed-base64
sed 's/"plan":/"plan":"AAAA", "plan":/' "$scratch/input.json" > "$scratch/corrupt.json"
refuse "$scratch/corrupt.json" duplicate-key
ln -s "$scratch/input.json" "$scratch/link.json"
refuse "$scratch/link.json" symlink-input
cp "$scratch/repo/.github/bootstrap-plan-approval.json" "$scratch/approval.json"
jq '.sourceRun=987654321' "$scratch/approval.json" > "$scratch/repo/.github/bootstrap-plan-approval.json"
refuse "$scratch/input.json" unrelated-source-run
cp "$scratch/approval.json" "$scratch/repo/.github/bootstrap-plan-approval.json"
jq '.resourceUpdates=1' "$scratch/approval.json" > "$scratch/repo/.github/bootstrap-plan-approval.json"
refuse "$scratch/input.json" widened-proposal
printf '%s\n' 'PASS: reviewed bootstrap bytes bind to their retained recovery generation'
