#!/usr/bin/env bash
# Fixed state-only migration, then recovery on a separate hosted runner.
# No import, resource apply, forced overwrite, new long-lived key or private age key.
set +x
set -euo pipefail
umask 077
stage=dispatch scratch='' output_created=false
stop() { exit 2; }
finish() {
  local rc=$?
  if [[ -n "$scratch" ]]; then
    if [[ $output_created == true && -d "$scratch/evidence" ]]; then
      tar -czf "$scratch/evidence.tar.gz" -C "$scratch" evidence >/dev/null 2>&1 &&
        age -r "$recipient" -o "$OUTPUT_DIR/evidence.tar.gz.age" "$scratch/evidence.tar.gz" 2>/dev/null || rc=2
    fi
    rm -rf "$scratch"
  fi
  if [[ $rc != 0 ]]; then
    printf 'CLOUDFLARE_STATE_MIGRATION=UNVERIFIED stage=%s\n' "$stage" >&2
    exit 2
  fi
  printf 'CLOUDFLARE_STATE_MIGRATION=VERIFIED phase=%s provider_writes=0 general_applies=disabled recovery_publication=required\n' "$MIGRATION_PHASE"
}
trap finish EXIT
trap 'exit 2' INT TERM
[[ ${BASH_VERSINFO[0]} -ge 5 && $# == 1 && -d $1 && ! -L $1 &&
  ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare &&
  ${GITHUB_REF:-} == refs/heads/main && ${GITHUB_ACTOR:-} == devantler &&
  ${GITHUB_RUN_ATTEMPT:-} == 1 && ${RUNNER_ENVIRONMENT:-} == github-hosted &&
  ${GITHUB_WORKFLOW_REF:-} == devantler-tech/cloudflare/.github/workflows/state-backend-migrate.yaml@refs/heads/main &&
  ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{5,15}$ &&
  ${CONFIRMATION:-} == MIGRATE_STATE_BACKEND &&
  (${MIGRATION_PHASE:-} == migrate || ${MIGRATION_PHASE:-} == recover) ]] || stop
root=$1
source "$root/scripts/r2-backend-common.sh"
stage=configuration
[[ -n ${CLOUDFLARE_BOOTSTRAP_CONFIGURATION:-} && ${#CLOUDFLARE_BOOTSTRAP_CONFIGURATION} -le 8388608 &&
  -n ${CLOUDFLARE_BOOTSTRAP_MIGRATION_STATE:-} && ${#CLOUDFLARE_BOOTSTRAP_MIGRATION_STATE} -le 49152 &&
  -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR &&
  ${PROOF_RUN:-} =~ ^[1-9][0-9]{5,15}$ && -n ${GH_TOKEN:-} &&
  $(findmnt -n -o FSTYPE --target /dev/shm) == tmpfs ]] || stop
for tool in tofu timeout jq curl age tar gh; do command -v "$tool" >/dev/null 2>&1 || stop; done
scratch=$(mktemp -d /dev/shm/cloudflare-state-migration.XXXXXXXX)
mkdir "$scratch/evidence" "$scratch/home" "$scratch/work"
recipient=$(state_recipient "$root")
printf '%s' "$CLOUDFLARE_BOOTSTRAP_CONFIGURATION" | backend_configuration_input > "$scratch/configuration.json" || stop
unset CLOUDFLARE_BOOTSTRAP_CONFIGURATION
printf '%s' "$CLOUDFLARE_BOOTSTRAP_MIGRATION_STATE" | backend_migration_state "$root" "$scratch/configuration.json" "$scratch/source.json" || stop
unset CLOUDFLARE_BOOTSTRAP_MIGRATION_STATE
mkdir "$OUTPUT_DIR"
output_created=true
stage=prerequisite
unset GH_HOST GH_ENTERPRISE_HOST GH_ENTERPRISE_TOKEN GH_DEBUG GH_FORCE_TTY
export GH_CONFIG_DIR="$scratch/gh" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER=cat
gh api "repos/devantler-tech/cloudflare/actions/runs/$PROOF_RUN" > "$scratch/proof-run.json" 2> "$scratch/gh.err" || stop
backend_proof_run "$scratch/proof-run.json" "$GITHUB_SHA" "$PROOF_RUN" "$GITHUB_RUN_ID" || stop
unset GH_TOKEN GITHUB_TOKEN
account=$(jq -er .account_id "$scratch/configuration.json")
stage=credential
root_token=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_API_TOKEN
[[ ${#root_token} -ge 20 && ${#root_token} -le 512 && $root_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop
request() {
  local method=$1 url=$2 response=$3 body=${4:-} status rc=0
  local -a args=(--request "$method" --url "$url" --output "$response")
  if [[ -n "$body" ]]; then args+=(--header 'Content-Type: application/json' --data-binary "@$body"); fi
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$root_token" |
    curl --disable --config - --proto '=https' --noproxy '*' --max-redirs 0 \
      --connect-timeout 10 --max-time 30 --max-filesize 32768 --silent --fail-with-body \
      --write-out '%{http_code}' "${args[@]}" 2>/dev/null) || rc=$?
  if [[ $status =~ ^[0-9]{3}$ ]]; then printf 'status=%s curl_exit=%s\n' "$status" "$rc" >> "$scratch/evidence/http.log"; fi
  jq -r '.errors[]?.code | select(type=="number") | "provider_code=\(.)"' "$response" >> "$scratch/evidence/http.log" 2>/dev/null || true
  [[ $rc == 0 && $status == 200 ]] && state_unique_json "$response" &&
    jq -e '.success==true and (.errors==null or .errors==[])' "$response" >/dev/null 2>&1
}
request GET "https://api.cloudflare.com/client/v4/accounts/$account/tokens/verify" "$scratch/parent.json" || stop
parent=$(jq -er 'if .result.status=="active" and (.result.id|type=="string" and test("^[a-f0-9]{32}$")) then .result.id else error("invalid parent") end' "$scratch/parent.json" 2>/dev/null) || stop
jq -n --arg parent "$parent" '{parentAccessKeyId:$parent,bucket:"cloudflare-bootstrap-state",permission:"object-read-write",ttlSeconds:900,prefixes:["cloudflare/"]}' > "$scratch/request.json"
stage=session
request POST "https://api.cloudflare.com/client/v4/accounts/$account/r2/temp-access-credentials" "$scratch/session.json" "$scratch/request.json" || stop
backend_session "$scratch/session.json" || stop
# Native tools receive only the selected short-lived backend session. The
# existing account token enters provider validation/plans, never init/copy.
native() (
  local provider_mode=$1; shift
  while IFS= read -r name; do [[ $name == PATH ]] || unset "$name"; done < <(compgen -e)
  export HOME="$scratch/home" TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1 AWS_EC2_METADATA_DISABLED=true
  AWS_ACCESS_KEY_ID=$(jq -er .result.accessKeyId "$scratch/session.json")
  AWS_SECRET_ACCESS_KEY=$(jq -er .result.secretAccessKey "$scratch/session.json")
  AWS_SESSION_TOKEN=$(jq -er .result.sessionToken "$scratch/session.json")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if [[ $provider_mode == provider ]]; then export CLOUDFLARE_API_TOKEN="$root_token"; fi
  "$@"
)
for file in main.tf variables.tf versions.tf providers.tf outputs.tf .terraform.lock.hcl; do
  [[ -f "$root/$file" && ! -L "$root/$file" ]] || stop
  cp "$root/$file" "$scratch/work/$file"
done
cp "$scratch/configuration.json" "$scratch/work/production.auto.tfvars.json"
cat > "$scratch/backend.hcl" <<HCL
bucket = "cloudflare-bootstrap-state"
key = "cloudflare/production.tfstate"
workspace_key_prefix = "cloudflare/workspaces"
region = "auto"
endpoints = { s3 = "https://$account.r2.cloudflarestorage.com" }
use_path_style = true
skip_credentials_validation = true
skip_region_validation = true
skip_requesting_account_id = true
skip_metadata_api_check = true
skip_s3_checksum = true
use_lockfile = true
HCL
stage=runtime-version
native local tofu version -json > "$scratch/evidence/version.json" 2>/dev/null || stop
jq -e '.terraform_version=="1.12.6"' "$scratch/evidence/version.json" >/dev/null 2>&1 || stop
if [[ $MIGRATION_PHASE == migrate ]]; then
  printf 'terraform {\n  backend "local" {}\n}\n' > "$scratch/work/backend_override.tf"
  cp "$scratch/source.json" "$scratch/work/terraform.tfstate"
  stage=local-initialize
  native local timeout --kill-after=10s 120 tofu -chdir="$scratch/work" init -input=false -lockfile=readonly -no-color > "$scratch/evidence/local-init.log" 2>&1 || stop
  stage=local-convergence
  native provider timeout --kill-after=10s 120 tofu -chdir="$scratch/work" plan -lock-timeout=0s -detailed-exitcode -input=false -no-color > "$scratch/evidence/local-plan.log" 2>&1 || stop
  rm "$scratch/work/backend_override.tf"
  stage=migrate
  native local bash "$root/scripts/migrate-native-backend.sh" "$scratch/work" "$scratch/backend.hcl" "$scratch/evidence" > "$scratch/evidence/migration-proof.log" 2>&1 || stop
else
  # This runner receives HCL only: no prior .terraform, backend metadata, local
  # state, plan or artifact is copied from the migration job.
  stage=fresh-initialize
  native local timeout --kill-after=10s 120 tofu -chdir="$scratch/work" init -input=false -lockfile=readonly -no-color -backend-config="$scratch/backend.hcl" > "$scratch/evidence/fresh-init.log" 2>&1 || stop
fi
stage=capture
native local timeout 30 tofu -chdir="$scratch/work" state pull > "$scratch/evidence/state.json" 2> "$scratch/evidence/pull.log" || stop
jq -e --slurpfile source "$scratch/source.json" '.serial>=$source[0].serial and (del(.serial))==($source[0]|del(.serial))' "$scratch/evidence/state.json" >/dev/null 2>&1 || stop
stage=recovery-package
bash "$root/scripts/prepare-state-recovery-package.sh" "$root" "$scratch/evidence/state.json" "$scratch/configuration.json" "$OUTPUT_DIR/state" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$scratch/evidence/package.log" 2>&1 || stop
stage=lock
native provider bash "$root/scripts/prove-native-state-lock.sh" "$scratch/work" "$scratch/evidence" > "$scratch/evidence/lock.log" 2>&1 || stop
stage=provider-convergence
native provider timeout --kill-after=10s 120 tofu -chdir="$scratch/work" plan -lock-timeout=0s -detailed-exitcode -input=false -no-color > "$scratch/evidence/provider-plan.log" 2>&1 || stop
unset root_token parent
