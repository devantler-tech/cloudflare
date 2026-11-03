#!/usr/bin/env bash
# Import only into isolated local state; publish an encrypted no-change proposal.
set +x
set -euo pipefail
umask 077
stop() { failure_stage=$1; printf 'EMAIL_DNS_PROPOSAL=UNVERIFIED stage=%s\n' "$1" >&2; exit 2; }
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main &&
   ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_ACTOR:-} == devantler &&
   ${GITHUB_RUN_ATTEMPT:-} == 1 && ${RUNNER_ENVIRONMENT:-} == github-hosted &&
   ${GITHUB_WORKFLOW_REF:-} == devantler-tech/cloudflare/.github/workflows/email-dns-proposal.yaml@refs/heads/main &&
   ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{0,15}$ &&
   ${CONFIRMATION:-} == PLAN_EMAIL_DNS ]] || stop dispatch
[[ $# == 1 && -d $1 && ! -L $1 ]] || stop root
root=$1
provider_token=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_API_TOKEN
[[ ${#provider_token} -ge 20 && ${#provider_token} -le 512 && $provider_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop credential
while IFS= read -r variable; do
 case $variable in
 TF_*|TOFU_*|CLOUDFLARE_*|AWS_*|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy) unset "$variable";;
 esac
done < <(compgen -e)
for tool in jq curl age tofu shasum tar; do command -v "$tool" >/dev/null 2>&1 || stop tools;done
[[ -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR ]] || stop destination
[[ -n ${DIAGNOSTICS_DIR:-} && $DIAGNOSTICS_DIR == /* && ! -e $DIAGNOSTICS_DIR && ! -L $DIAGNOSTICS_DIR && $DIAGNOSTICS_DIR != "$OUTPUT_DIR" ]] || stop diagnostics-destination
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
# shellcheck source=scripts/dns-snapshot-common.sh
source "$script_dir/dns-snapshot-common.sh"
recipient=$(state_recipient "$root")
scratch=$(mktemp -d)
owned_output=false complete=false failure_stage=unexpected

# Only fixed bounded files enter the encrypted archive; credentials, provider
# executables and the environment never enter either success or failure output.
pack_private() {
 local kind=$1 file
 local files=(metadata.json)
 jq -n --arg kind "$kind" --arg source "$GITHUB_SHA" --argjson run "$GITHUB_RUN_ID" --arg stage "$failure_stage" \
 '{schemaVersion:1,kind:$kind,sourceCommit:$source,sourceRun:$run,providerWrites:0,stage:$stage}' > "$scratch/metadata.json" || return 1
 if [[ $kind == cloudflare-email-dns-proposal ]]; then
  for file in snapshot.json bucket.json proposal.json imports.json plan.json work/production.auto.tfvars.json work/migration.tfplan; do
   [[ -f $scratch/$file && ! -L $scratch/$file && -s $scratch/$file && $(wc -c < "$scratch/$file") -le 16777216 ]] || return 1
  done
 fi
 for file in snapshot.json bucket.json proposal.json imports.json plan.json init.log import.log plan.log show.log work/production.auto.tfvars.json work/migration.tfplan; do
  if [[ -f $scratch/$file && ! -L $scratch/$file && $(wc -c < "$scratch/$file") -le 16777216 ]];then files+=("$file");fi
 done
 tar -czf "$scratch/bundle.tar.gz" -C "$scratch" "${files[@]}" 2>/dev/null || return 1
 [[ $(wc -c < "$scratch/bundle.tar.gz") -le 33554432 ]] || return 1
 age -r "$recipient" -o "$scratch/bundle.tar.gz.age" "$scratch/bundle.tar.gz" 2>/dev/null
}
cleanup() {
 local rc=$?
 if [[ $rc != 0 ]];then
  if pack_private cloudflare-email-dns-diagnostics && mkdir -m 700 "$DIAGNOSTICS_DIR" &&
     mv "$scratch/bundle.tar.gz.age" "$DIAGNOSTICS_DIR/diagnostics.tar.gz.age";then
   printf '%s\n' 'EMAIL_DNS_DIAGNOSTICS=ENCRYPTED'
  else printf '%s\n' 'EMAIL_DNS_DIAGNOSTICS=UNVERIFIED' >&2;fi
 fi
 rm -rf "$scratch"
 if "$owned_output" && ! "$complete";then rm -rf "$OUTPUT_DIR";fi
}
trap cleanup EXIT
trap 'exit 2' INT TERM
printf 'recipient validation\n' | age -r "$recipient" -o "$scratch/probe.age" 2>/dev/null || stop recipient
collect_dns_snapshot "$scratch"
state_unique_json "$scratch/snapshot.json" || stop snapshot
jq -e --arg source "$GITHUB_SHA" --argjson now "$(date -u +%s)" \
 '(.captured_at|fromdateiso8601) as $captured|.source_revision==$source and $captured<=$now and ($now-$captured)<=300' \
 "$scratch/snapshot.json" >/dev/null 2>&1 || stop snapshot-freshness
jq --arg zone devantler.tech --arg revision "$GITHUB_SHA" -f "$script_dir/email-dns-proposal.jq" "$scratch/snapshot.json" > "$scratch/proposal.json" 2>/dev/null || stop ownership
account_id=$(jq -er .zone.account.id "$scratch/snapshot.json")
zone_id=$(jq -er .zone.id "$scratch/snapshot.json")
read_cloudflare "https://api.cloudflare.com/client/v4/accounts/$account_id/r2/buckets/cloudflare-bootstrap-state" > "$scratch/bucket.json" || stop bucket-read
state_unique_json "$scratch/bucket.json" || stop bucket
jq -e '.success==true and .result.name=="cloudflare-bootstrap-state" and .result.jurisdiction=="default" and (.result.storage_class=="Standard" or .result.storage_class=="InfrequentAccess")' "$scratch/bucket.json" >/dev/null 2>&1 || stop bucket
mkdir "$scratch/work"
for file in main.tf variables.tf versions.tf providers.tf outputs.tf .terraform.lock.hcl;do
 [[ -f $root/$file && ! -L $root/$file ]] || stop source
 cp "$root/$file" "$scratch/work/$file" || stop source
done
printf 'terraform {\n  backend "local" {}\n}\n' > "$scratch/work/backend_override.tf"
printf '\n' > "$scratch/provider.rc"
jq -n --arg account "$account_id" --slurpfile dns "$scratch/proposal.json" --slurpfile bucket "$scratch/bucket.json" \
 '{account_id:$account,zone_name:"devantler.tech",dns_records:$dns[0].dns_records,r2_buckets:{"cloudflare-bootstrap-state":{jurisdiction:"default",storage_class:$bucket[0].result.storage_class}},r2_lifecycle_rules:{},account_tokens:{}}' > "$scratch/work/production.auto.tfvars.json"
jq --arg zone "$zone_id" --arg account "$account_id" \
 '.imports + [{address:"cloudflare_zone.primary",id:$zone},{address:"cloudflare_r2_bucket.buckets[\"cloudflare-bootstrap-state\"]",id:($account+"/cloudflare-bootstrap-state/default")}]|sort_by(.address)' "$scratch/proposal.json" > "$scratch/imports.json"
provider_tofu() (
 export CLOUDFLARE_API_TOKEN="$provider_token" TF_IN_AUTOMATION=true CHECKPOINT_DISABLE=1 TF_CLI_CONFIG_FILE="$scratch/provider.rc"
 tofu -chdir="$scratch/work" "$@"
)
provider_tofu init -input=false -lockfile=readonly > "$scratch/init.log" 2>&1 || stop init
while IFS=$'\t' read -r address identity;do
 provider_tofu import -input=false "$address" "$identity" >> "$scratch/import.log" 2>&1 || stop import
done < <(jq -r '.[]|[.address,.id]|@tsv' "$scratch/imports.json")
plan_rc=0
provider_tofu plan -input=false -detailed-exitcode -out=migration.tfplan > "$scratch/plan.log" 2>&1 || plan_rc=$?
[[ $plan_rc == 0 || $plan_rc == 2 ]] || stop plan
provider_tofu show -json migration.tfplan > "$scratch/plan.json" 2> "$scratch/show.log" || stop show
state_unique_json "$scratch/plan.json" || stop plan-json
jq -e --slurpfile wanted "$scratch/imports.json" -f "$script_dir/check-email-dns-plan.jq" "$scratch/plan.json" >/dev/null 2>&1 || stop change-boundary
[[ $plan_rc == 0 ]] || stop changed-plan
unset provider_token account_id zone_id
failure_stage=complete
pack_private cloudflare-email-dns-proposal || stop encryption
cipher_hash=$(state_hash "$scratch/bundle.tar.gz.age") || stop checksum
plain_hash=$(state_hash "$scratch/bundle.tar.gz") || stop checksum
[[ $cipher_hash =~ ^[a-f0-9]{64}$ && $plain_hash =~ ^[a-f0-9]{64}$ ]] || stop checksum
mkdir -m 700 "$OUTPUT_DIR" || stop destination
owned_output=true
mv "$scratch/bundle.tar.gz.age" "$OUTPUT_DIR/proposal.tar.gz.age"
jq -n --arg source "$GITHUB_SHA" --argjson run "$GITHUB_RUN_ID" --arg ciphertext "$cipher_hash" --arg plaintext "$plain_hash" \
 '{schemaVersion:1,kind:"cloudflare-email-dns-proposal",sourceCommit:$source,sourceRun:$run,providerWrites:0,ciphertextSha256:$ciphertext,plaintextSha256:$plaintext,authoritativeStateAdopted:false}' > "$OUTPUT_DIR/manifest.json"
complete=true
printf '%s\n' 'EMAIL_DNS_PROPOSAL=ENCRYPTED_UNCHANGED provider_writes=0'
