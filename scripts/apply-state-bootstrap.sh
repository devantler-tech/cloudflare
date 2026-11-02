#!/usr/bin/env bash
# One frozen bootstrap proposal; no DNS adoption or remote-backend activation.
set -euo pipefail
set +x
umask 077
stage=dispatch
stop() { printf 'CLOUDFLARE_BOOTSTRAP_APPLY=UNVERIFIED stage=%s\n' "$stage" >&2; exit 2; }
[[ $# == 1 && -d $1 && ! -L $1 ]] || stop
root=$1
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main && ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_ACTOR:-} == devantler && ${GITHUB_RUN_ATTEMPT:-} == 1 && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${GITHUB_WORKFLOW_REF:-} == devantler-tech/cloudflare/.github/workflows/state-bootstrap-apply.yaml@refs/heads/main ]] || stop
[[ ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{6,19}$ && -n ${GH_TOKEN:-} ]] || stop
[[ (${BOOTSTRAP_MODE:-} == check && ${CONFIRMATION:-} == CHECK_STATE_CUSTODY) || (${BOOTSTRAP_MODE:-} == apply && ${CONFIRMATION:-} == APPLY_STATE_BOOTSTRAP) ]] || stop
provider_token=${CLOUDFLARE_API_TOKEN:-}
approved_data=${CLOUDFLARE_BOOTSTRAP_APPROVED_DATA:-}
unset CLOUDFLARE_API_TOKEN CLOUDFLARE_BOOTSTRAP_APPROVED_DATA CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL CLOUDFLARE_API_USER_SERVICE_KEY
while IFS= read -r variable; do
  case $variable in
    TF_*|TOFU_*|CLOUDFLARE_*|AWS_*|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy) unset "$variable" ;;
  esac
done < <(compgen -e)
if [[ $BOOTSTRAP_MODE == apply ]]; then
  stage=credential
  [[ ${#provider_token} -ge 20 && ${#provider_token} -le 512 && $provider_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop
fi
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
stage=destination
[[ -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || stop
mkdir -m 700 "$OUTPUT_DIR" || stop
if [[ $BOOTSTRAP_MODE == check ]]; then
  cp -R "$root/recovery/state" "$OUTPUT_DIR/state"
  stage=checkpoint
  bash "$script_dir/publish-bootstrap-state.sh" "$root" "$OUTPUT_DIR/state" checkpoint || stop
  stage=publication
  BOOTSTRAP_APPLY_EXIT=0 BOOTSTRAP_PLAN_EXIT=0 bash "$script_dir/publish-bootstrap-state.sh" "$root" "$OUTPUT_DIR/state" result || stop
  printf '%s\n' 'CLOUDFLARE_BOOTSTRAP_APPLY=VERIFIED mode=check provider_writes=0'
  exit 0
fi
stage=private-workspace
[[ -n $provider_token && -n $approved_data && $(findmnt -n -o FSTYPE --target /dev/shm) == tmpfs ]] || stop
scratch=$(mktemp -d /dev/shm/cloudflare-bootstrap-apply.XXXXXXXX) || stop
recipient=$(state_recipient "$root")
cleanup() {
  local result=$? file
  if [[ $result != 0 ]]; then
    mkdir "$scratch/diagnostics"
    jq -n --arg source "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg stage "$stage" --argjson code "$result" '{schemaVersion:1,kind:"cloudflare-state-bootstrap-apply-diagnostics",sourceCommit:$source,sourceRun:$run,stage:$stage,exitCode:$code}' > "$scratch/diagnostics/metadata.json" || true
    for file in init.log version.json show.log apply.log convergence.log capture.log package.log publication.log bucket.json captured-state.json work/terraform.tfstate; do
      if [[ -f "$scratch/$file" && ! -L "$scratch/$file" && $(wc -c < "$scratch/$file") -le 16777216 ]]; then
        cp "$scratch/$file" "$scratch/diagnostics/${file//\//-}" || true
      fi
    done
    tar -czf "$scratch/diagnostics.tar.gz" -C "$scratch/diagnostics" . 2>/dev/null &&
      age -r "$recipient" -o "$OUTPUT_DIR/diagnostics.tar.gz.age" "$scratch/diagnostics.tar.gz" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 2' INT TERM
printf '%s' "$approved_data" > "$scratch/input.json"
unset approved_data
stage=approved-input
bash "$script_dir/decode-bootstrap-apply-input.sh" "$root" "$scratch/input.json" "$scratch/accepted" > "$scratch/input.log" 2>&1 || stop
mkdir "$scratch/work" "$scratch/home"
for file in main.tf variables.tf versions.tf providers.tf outputs.tf .terraform.lock.hcl; do
  [[ -f "$root/$file" && ! -L "$root/$file" ]] || stop
  cp "$root/$file" "$scratch/work/$file"
done
printf 'terraform {\n  backend "local" {}\n}\n' > "$scratch/work/backend_override.tf"
cp "$scratch/accepted/state.json" "$scratch/work/terraform.tfstate"
cp "$scratch/accepted/configuration.json" "$scratch/work/production.auto.tfvars.json"
cp "$scratch/accepted/plan" "$scratch/work/migration.tfplan"
run_tofu() (
  mode=$1; shift
  # Neither workflow credentials nor ambient CLI arguments enter the provider.
  unset GH_TOKEN GITHUB_TOKEN
  for variable in ${!TF_@}; do unset "$variable"; done
  export HOME="$scratch/home" TF_IN_AUTOMATION=true CHECKPOINT_DISABLE=1
  if [[ $mode == provider ]]; then export CLOUDFLARE_API_TOKEN="$provider_token"; else unset CLOUDFLARE_API_TOKEN; fi
  tofu -chdir="$scratch/work" "$@"
)
stage=runtime-version
run_tofu local version -json > "$scratch/version.json" 2>/dev/null || stop
jq -e '.terraform_version=="1.12.6"' "$scratch/version.json" >/dev/null 2>&1 || stop
stage=initialization
run_tofu local init -input=false -lockfile=readonly > "$scratch/init.log" 2>&1 || stop
stage=native-plan
run_tofu local show -json migration.tfplan > "$scratch/native-plan.json" 2> "$scratch/show.log" || stop
state_unique_json "$scratch/native-plan.json" || stop
jq -Sc . "$scratch/native-plan.json" > "$scratch/native-canonical.json"
jq -Sc . "$scratch/accepted/plan.json" > "$scratch/approved-canonical.json"
cmp -s "$scratch/native-canonical.json" "$scratch/approved-canonical.json" || stop
bash "$script_dir/assert-no-destructive-plan.sh" "$scratch/native-plan.json" > "$scratch/guard.log" 2>&1 || stop
account_id=$(jq -r .account_id "$scratch/accepted/configuration.json")
zone_id=$(jq -r '.resources[]|select(.type=="cloudflare_zone" and .name=="primary")|.instances[0].attributes.id' "$scratch/accepted/state.json")
stage=change-boundary
jq -e --arg account "$account_id" --arg zone "$zone_id" '
  .errored!=true and ((.deferred_changes // [])|length==0) and
  (.resource_changes|type=="array" and length==2) and
  ([.resource_changes[].address]|sort)==["cloudflare_r2_bucket.buckets[\"cloudflare-bootstrap-state\"]","cloudflare_zone.primary"] and
  all(.resource_changes[]; .mode=="managed" and
    if .address=="cloudflare_zone.primary" then .type=="cloudflare_zone" and .change.actions==["no-op"] and .change.before.id==$zone and .change.after.id==$zone
    else .type=="cloudflare_r2_bucket" and .change.actions==["create"] and .change.before==null and .change.after.account_id==$account and .change.after.name=="cloudflare-bootstrap-state" and .change.after.jurisdiction=="default" and .change.after.storage_class=="Standard" end)
' "$scratch/native-plan.json" >/dev/null 2>&1 || stop
stage=bucket-absence
status=$(printf 'header = "Authorization: Bearer %s"\n' "$provider_token" |
  curl --disable --config - --request GET --proto '=https' --noproxy '*' --max-redirs 0 --connect-timeout 10 --max-time 20 --max-filesize 8388608 --silent --output "$scratch/bucket.json" --write-out '%{http_code}' --url "https://api.cloudflare.com/client/v4/accounts/$account_id/r2/buckets/cloudflare-bootstrap-state" 2>/dev/null) || stop
if [[ $status != 404 ]] || ! state_unique_json "$scratch/bucket.json"; then stop; fi
jq -e '.success==false and .result==null and (.errors|type=="array" and length>0) and all(.errors[];.code==10006)' "$scratch/bucket.json" >/dev/null 2>&1 || stop
stage=custody-canary
bash "$script_dir/publish-bootstrap-state.sh" "$root" "$root/recovery/state" verify > "$scratch/publication.log" 2>&1 || stop
stage=checkpoint
bash "$script_dir/publish-bootstrap-state.sh" "$root" "$root/recovery/state" checkpoint > "$scratch/publication.log" 2>&1 || stop
stage=apply
apply_exit=0
run_tofu provider apply -input=false migration.tfplan > "$scratch/apply.log" 2>&1 || apply_exit=$?
plan_exit=255
if [[ $apply_exit == 0 ]]; then
  plan_exit=0
  run_tofu provider plan -input=false -detailed-exitcode > "$scratch/convergence.log" 2>&1 || plan_exit=$?
fi
unset provider_token
stage=capture
run_tofu local state pull > "$scratch/captured-state.json" 2> "$scratch/capture.log" || stop
stage=recovery-package
bash "$script_dir/prepare-state-recovery-package.sh" "$root" "$scratch/captured-state.json" "$scratch/work/production.auto.tfvars.json" "$OUTPUT_DIR/state" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$scratch/package.log" 2>&1 || stop
stage=publication
BOOTSTRAP_APPLY_EXIT=$apply_exit BOOTSTRAP_PLAN_EXIT=$plan_exit bash "$script_dir/publish-bootstrap-state.sh" "$root" "$OUTPUT_DIR/state" result > "$scratch/publication.log" 2>&1 || stop
stage=provider-convergence
[[ $apply_exit == 0 && $plan_exit == 0 ]] || stop
printf '%s\n' 'CLOUDFLARE_BOOTSTRAP_APPLY=VERIFIED mode=apply provider_writes=1 custody=VERIFIED convergence=VERIFIED'
