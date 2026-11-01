#!/usr/bin/env bash
# Read/import locally and encrypt a saved proposal. Never applies or changes a provider resource.
set +x
set -euo pipefail
umask 077
# Report a fixed stage and terminate without exposing captured provider output.
stop() { failure_stage=$1; printf 'CLOUDFLARE_BOOTSTRAP_PLAN=UNVERIFIED stage=%s\n' "$1" >&2; exit 2; }
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main \
  && ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_ACTOR:-} == devantler \
  && ${GITHUB_RUN_ATTEMPT:-} == 1 && ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ \
  && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{0,15}$ && ${CONFIRMATION:-} == PLAN_STATE_BOOTSTRAP ]] || stop dispatch
[[ $# == 1 && -d $1 && ! -L $1 ]] || stop root
root=$1
[[ -n ${CLOUDFLARE_API_TOKEN:-} ]] || stop credential
provider_token=$CLOUDFLARE_API_TOKEN
unset CLOUDFLARE_API_TOKEN
[[ ${#provider_token} -ge 20 && ${#provider_token} -le 512 && $provider_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop credential
# CLI arguments, debug logging, custom API endpoints, workspaces and proxy
# settings must not alter the reviewed provider invocation or expose its data.
while IFS= read -r variable; do
  case $variable in
    TF_*|TOFU_*|CLOUDFLARE_*|AWS_*|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy) unset "$variable" ;;
  esac
done < <(compgen -e)
for tool in jq curl age tofu shasum tar; do command -v "$tool" >/dev/null 2>&1 || stop tools; done
[[ -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR ]] || stop destination
[[ -n ${DIAGNOSTICS_DIR:-} && $DIAGNOSTICS_DIR == /* && ! -e $DIAGNOSTICS_DIR && ! -L $DIAGNOSTICS_DIR \
  && $DIAGNOSTICS_DIR != "$OUTPUT_DIR" ]] || stop diagnostics-destination
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
recipient=$(state_recipient "$root")
scratch=$(mktemp -d)
owned_output=false
complete=false
failure_stage=unexpected
# Encrypt bounded failure evidence separately from an accepted plan package.
prepare_diagnostics() {
  local rc=$1 file
  local files=(diagnostics-metadata.json)
  jq -n --arg source "$GITHUB_SHA" --argjson run "$GITHUB_RUN_ID" --arg stage "$failure_stage" --argjson code "$rc" \
    '{schemaVersion:1,kind:"cloudflare-state-bootstrap-diagnostics",sourceCommit:$source,sourceRun:$run,stage:$stage,exitCode:$code}' > "$scratch/diagnostics-metadata.json" || return 1
  # Fixed, bounded files only: no provider executable, environment or credential
  # file is collected. The encrypted archive is separate from a valid proposal.
  for file in zone.json bucket.json init.log import.log plan.log show.log state.log guard.log package.log plan.json state.json work/terraform.tfstate work/migration.tfplan work/production.auto.tfvars.json; do
    if [[ -f $scratch/$file && ! -L $scratch/$file && $(wc -c < "$scratch/$file") -le 16777216 ]]; then files+=("$file"); fi
  done
  tar -czf "$scratch/diagnostics.tar.gz" -C "$scratch" "${files[@]}" 2>/dev/null || return 1
  [[ $(wc -c < "$scratch/diagnostics.tar.gz") -le 33554432 ]] || return 1
  age -r "$recipient" -o "$scratch/diagnostics.tar.gz.age" "$scratch/diagnostics.tar.gz" 2>/dev/null || return 1
  mkdir -m 700 "$DIAGNOSTICS_DIR" 2>/dev/null || return 1
  if ! mv "$scratch/diagnostics.tar.gz.age" "$DIAGNOSTICS_DIR/diagnostics.tar.gz.age" 2>/dev/null; then
    rmdir "$DIAGNOSTICS_DIR" 2>/dev/null
    return 1
  fi
  printf '%s\n' 'CLOUDFLARE_BOOTSTRAP_PLAN_DIAGNOSTICS=ENCRYPTED'
}
# Retain encrypted diagnostics on failure and remove private or partial outputs.
cleanup() {
  local rc=$?
  if [[ $rc != 0 ]]; then
    if ! prepare_diagnostics "$rc"; then printf '%s\n' 'CLOUDFLARE_BOOTSTRAP_PLAN_DIAGNOSTICS=UNVERIFIED' >&2; fi
  fi
  rm -rf "$scratch"
  if "$owned_output" && ! "$complete"; then rm -rf "$OUTPUT_DIR"; fi
}
trap cleanup EXIT
trap 'exit 2' INT TERM
printf 'recipient validation\n' | age -r "$recipient" -o "$scratch/probe.age" 2>/dev/null || stop recipient

# Make a fixed GET with the credential on stdin and the response in private scratch.
read_cloudflare() {
  printf 'header = "Authorization: Bearer %s"\n' "$provider_token" |
    curl --disable --config - --request GET --proto '=https' --noproxy '*' \
      --max-redirs 0 --connect-timeout 10 --max-time 20 --max-filesize 8388608 \
      --silent --output "$2" --write-out '%{http_code}' --url "$1" 2>/dev/null
}
status=$(read_cloudflare 'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50' "$scratch/zone.json") || stop zone-read
if [[ $status != 200 ]] || ! state_unique_json "$scratch/zone.json"; then stop zone-response; fi
zone_id=$(jq -er '
  if .success==true and (.result|type=="array" and length==1) and
    .result_info.total_count==1 and .result_info.total_pages==1 and
    .result[0].name=="devantler.tech" and .result[0].status=="active" and
    (.result[0].id|type=="string" and test("^[a-f0-9]{32}$")) and
    (.result[0].account.id|type=="string" and test("^[a-f0-9]{32}$"))
  then .result[0].id else error("binding") end
' "$scratch/zone.json" 2>/dev/null) || stop zone-binding
account_id=$(jq -er .result[0].account.id "$scratch/zone.json")
# The first proposal creates one new default-jurisdiction state bucket. It may
# not silently adopt an existing bucket or interpret an authorization failure
# as absence. Cloudflare documents NoSuchBucket as HTTP 404 / code 10006.
status=$(read_cloudflare "https://api.cloudflare.com/client/v4/accounts/$account_id/r2/buckets/cloudflare-bootstrap-state" "$scratch/bucket.json") || stop bucket-read
if [[ $status != 404 ]] || ! state_unique_json "$scratch/bucket.json"; then stop bucket-absence; fi
jq -e '.success==false and .result==null and (.errors|type=="array" and length>0) and all(.errors[]; .code==10006)' "$scratch/bucket.json" >/dev/null 2>&1 || stop bucket-absence

mkdir "$scratch/work"
for file in main.tf variables.tf versions.tf providers.tf outputs.tf .terraform.lock.hcl; do
  [[ -f $root/$file && ! -L $root/$file ]] || stop source
  cp "$root/$file" "$scratch/work/$file" || stop source
done
printf 'terraform {\n  backend "local" {}\n}\n' > "$scratch/work/backend_override.tf"
jq -n --arg account "$account_id" '{account_id:$account,zone_name:"devantler.tech",dns_records:{},r2_buckets:{"cloudflare-bootstrap-state":{jurisdiction:"default",storage_class:"Standard"}},r2_lifecycle_rules:{},account_tokens:{}}' > "$scratch/work/production.auto.tfvars.json"
# Expose the credential only to the isolated provider process, never its argv.
provider_tofu() (
  export CLOUDFLARE_API_TOKEN="$provider_token" TF_IN_AUTOMATION=true CHECKPOINT_DISABLE=1
  tofu -chdir="$scratch/work" "$@"
)
provider_tofu init -input=false -lockfile=readonly > "$scratch/init.log" 2>&1 || stop init
provider_tofu import -input=false cloudflare_zone.primary "$zone_id" > "$scratch/import.log" 2>&1 || stop import
plan_rc=0
provider_tofu plan -input=false -detailed-exitcode -out=migration.tfplan > "$scratch/plan.log" 2>&1 || plan_rc=$?
[[ $plan_rc == 0 || $plan_rc == 2 ]] || stop plan
provider_tofu show -json migration.tfplan > "$scratch/plan.json" 2> "$scratch/show.log" || stop show
state_unique_json "$scratch/plan.json" || stop plan-json
bash "$script_dir/assert-no-destructive-plan.sh" "$scratch/plan.json" > "$scratch/guard.log" 2>&1 || stop destructive
# The read-only first plan admits one existing unchanged zone and one new state
# bucket only. An update, unrelated create, deferred evaluation or error is HOLD.
jq -e --arg account "$account_id" --arg zone "$zone_id" '
  .errored!=true and ((.deferred_changes // [])|length==0) and
  (.resource_changes|type=="array" and length==2) and
  ([.resource_changes[].address]|sort)==["cloudflare_r2_bucket.buckets[\"cloudflare-bootstrap-state\"]","cloudflare_zone.primary"] and
  all(.resource_changes[];
    .mode=="managed" and
    if .address=="cloudflare_zone.primary" then
      .type=="cloudflare_zone" and .change.actions==["no-op"] and .change.before.id==$zone and .change.after.id==$zone
    else
      .type=="cloudflare_r2_bucket" and .change.actions==["create"] and .change.before==null and
      .change.after.account_id==$account and .change.after.name=="cloudflare-bootstrap-state" and
      .change.after.jurisdiction=="default" and .change.after.storage_class=="Standard"
    end)
' "$scratch/plan.json" >/dev/null 2>&1 || stop change-boundary
provider_tofu state pull > "$scratch/state.json" 2> "$scratch/state.log" || stop state
state_payloads "$scratch/state.json" "$scratch/work/production.auto.tfvars.json"
jq -e --arg zone "$zone_id" '.resources|length==1 and .[0].type=="cloudflare_zone" and .[0].name=="primary" and .[0].mode=="managed" and .[0].instances[0].attributes.id==$zone' "$scratch/state.json" >/dev/null 2>&1 || stop state-boundary
unset provider_token account_id zone_id

# Only ciphertext and non-sensitive binding metadata leave the private workspace.
mkdir -m 700 "$OUTPUT_DIR" 2>/dev/null || stop destination
owned_output=true
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bash "$script_dir/prepare-state-recovery-package.sh" "$root" "$scratch/state.json" "$scratch/work/production.auto.tfvars.json" "$OUTPUT_DIR/state" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$captured_at" > "$scratch/package.log" 2>&1 || stop recovery-package
age -r "$recipient" -o "$OUTPUT_DIR/migration.tfplan.age" "$scratch/work/migration.tfplan" 2>/dev/null || stop encryption
age -r "$recipient" -o "$OUTPUT_DIR/migration.tfplan.json.age" "$scratch/plan.json" 2>/dev/null || stop encryption
# Evaluate each fallible hash before jq: a command substitution in jq's argv
# cannot propagate its failure through jq's own successful exit status.
state_manifest_sha256=$(state_hash "$OUTPUT_DIR/state/manifest.json") || stop checksum
binary_plaintext_sha256=$(state_hash "$scratch/work/migration.tfplan") || stop checksum
binary_ciphertext_sha256=$(state_hash "$OUTPUT_DIR/migration.tfplan.age") || stop checksum
json_plaintext_sha256=$(state_hash "$scratch/plan.json") || stop checksum
json_ciphertext_sha256=$(state_hash "$OUTPUT_DIR/migration.tfplan.json.age") || stop checksum
for digest in "$state_manifest_sha256" "$binary_plaintext_sha256" "$binary_ciphertext_sha256" "$json_plaintext_sha256" "$json_ciphertext_sha256"; do
  [[ $digest =~ ^[a-f0-9]{64}$ ]] || stop checksum
done
jq -n --arg source "$GITHUB_SHA" --argjson run "$GITHUB_RUN_ID" --arg captured "$captured_at" \
  --arg stateManifestSha256 "$state_manifest_sha256" \
  --arg binaryPlaintextSha256 "$binary_plaintext_sha256" --arg binaryCiphertextSha256 "$binary_ciphertext_sha256" \
  --arg jsonPlaintextSha256 "$json_plaintext_sha256" --arg jsonCiphertextSha256 "$json_ciphertext_sha256" \
  '{schemaVersion:1,kind:"cloudflare-state-bootstrap-plan",sourceCommit:$source,sourceRun:$run,capturedAt:$captured,stateManifestSha256:$stateManifestSha256,binaryPlaintextSha256:$binaryPlaintextSha256,binaryCiphertextSha256:$binaryCiphertextSha256,jsonPlaintextSha256:$jsonPlaintextSha256,jsonCiphertextSha256:$jsonCiphertextSha256,resourceCreates:1,resourceUpdates:0,resourceDeletes:0}' > "$OUTPUT_DIR/plan-manifest.json"
complete=true
printf '%s\n' 'CLOUDFLARE_BOOTSTRAP_PLAN=ENCRYPTED review=required provider_writes=0'
