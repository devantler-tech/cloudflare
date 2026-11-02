#!/usr/bin/env bash
# Main-only, synthetic native S3-backend proof. Never opens the authoritative
# state key, imports resources, runs a provider, or creates a long-lived token.
set +x
set -euo pipefail
umask 077
stage=dispatch scratch='' output_created=false
# Export only selected encrypted native evidence, erase caller-owned scratch,
# and emit acceptance only after encryption succeeds. Never archive credentials.
finish() {
  local rc=$?
  if [[ -n "$scratch" ]]; then
    # Credential responses and request headers are deliberately outside evidence.
    if [[ $output_created == true && -d "$scratch/evidence" ]]; then
      tar -czf "$scratch/evidence.tar.gz" -C "$scratch" evidence >/dev/null 2>&1 &&
        age -r "$recipient" -o "$OUTPUT_DIR/evidence.tar.gz.age" "$scratch/evidence.tar.gz" 2>/dev/null || rc=2
    fi
    rm -rf "$scratch"
  fi
  if [[ $rc != 0 ]]; then
    printf 'CLOUDFLARE_STATE_BACKEND=UNVERIFIED stage=%s\n' "$stage" >&2
    exit 2
  fi
  printf '%s\n' 'CLOUDFLARE_STATE_BACKEND=VERIFIED scope=synthetic-state locking=native recovery=fresh-directory provider_resources=0'
}
trap finish EXIT
trap 'exit 2' INT TERM
stop() { exit 2; }
[[ ${BASH_VERSINFO[0]} -ge 5 && $# == 1 && ${GITHUB_EVENT_NAME:-} == workflow_dispatch &&
  ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_REF:-} == refs/heads/main &&
  ${GITHUB_ACTOR:-} == devantler && ${GITHUB_RUN_ATTEMPT:-} == 1 &&
  ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{5,15}$ && ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ &&
  ${CONFIRMATION:-} == VERIFY_STATE_BACKEND && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || stop
root=$1
[[ -d "$root" && ! -L "$root" ]] || stop
# shellcheck source=scripts/r2-backend-common.sh
source "$root/scripts/r2-backend-common.sh"
stage=configuration
[[ -n ${CLOUDFLARE_BOOTSTRAP_CONFIGURATION:-} && ${#CLOUDFLARE_BOOTSTRAP_CONFIGURATION} -le 8388608 &&
  -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR ]] || stop
for tool in tofu timeout jq curl age tar; do command -v "$tool" >/dev/null 2>&1 || stop; done
scratch=$(mktemp -d)
mkdir "$scratch/evidence" "$scratch/home" "$scratch/first" "$scratch/fresh"
recipient=$(state_recipient "$root")
printf '%s' "$CLOUDFLARE_BOOTSTRAP_CONFIGURATION" | backend_configuration_input > "$scratch/configuration.json" || stop
unset CLOUDFLARE_BOOTSTRAP_CONFIGURATION
backend_configuration "$root" "$scratch/configuration.json" || stop
account=$(jq -er .account_id "$scratch/configuration.json")
prefix="proofs/state-backend-$GITHUB_RUN_ID"
mkdir "$OUTPUT_DIR"
output_created=true
stage=credential
root_token=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_API_TOKEN
[[ ${#root_token} -ge 20 && ${#root_token} -le 512 && $root_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop
# The root token appears only in this inherited input pipe, never argv, a file,
# an artifact, or an OpenTofu child's environment. No retries or redirects.
request() {
  local method=$1 url=$2 response=$3 body=${4:-} status
  local -a args=(--request "$method" --url "$url" --output "$response")
  if [[ -n "$body" ]]; then args+=(--header 'Content-Type: application/json' --data-binary "@$body"); fi
  local rc=0
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$root_token" |
    curl --disable --config - --proto '=https' --noproxy '*' --max-redirs 0 \
      --connect-timeout 10 --max-time 30 --max-filesize 32768 --silent --fail-with-body \
      --write-out '%{http_code}' "${args[@]}" 2>/dev/null) || rc=$?
  if [[ "$status" =~ ^[0-9]{3}$ ]]; then printf 'status=%s curl_exit=%s\n' "$status" "$rc" >> "$scratch/evidence/http.log"; fi
  # Retain numeric API codes only. Credential response bodies are never archived.
  jq -r '.errors[]?.code | select(type=="number") | "provider_code=\(.)"' "$response" >> "$scratch/evidence/http.log" 2>/dev/null || true
  [[ $rc == 0 ]] || return 1
  [[ "$status" == 200 ]] && state_unique_json "$response" &&
    jq -e '.success==true and (.errors==null or .errors==[])' "$response" >/dev/null 2>&1
}
request GET "https://api.cloudflare.com/client/v4/accounts/$account/tokens/verify" "$scratch/parent.json" || stop
parent=$(jq -er 'if .result.status=="active" and (.result.id|type=="string" and test("^[a-f0-9]{32}$")) then .result.id else error("invalid parent") end' "$scratch/parent.json" 2>/dev/null) || stop
jq -n --arg parent "$parent" --arg prefix "$prefix/" '{parentAccessKeyId:$parent,bucket:"cloudflare-bootstrap-state",permission:"object-read-write",ttlSeconds:900,prefixes:[$prefix]}' > "$scratch/request.json"
stage=session
request POST "https://api.cloudflare.com/client/v4/accounts/$account/r2/temp-access-credentials" "$scratch/session.json" "$scratch/request.json" || stop
unset root_token parent
backend_session "$scratch/session.json" || stop
# Export only the short-lived credentials to a clean native tool environment.
# Shell assignments keep credential values out of process arguments.
native() (
  while IFS= read -r name; do [[ "$name" == PATH ]] || unset "$name"; done < <(compgen -e)
  export HOME="$scratch/home" TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1 AWS_EC2_METADATA_DISABLED=true
  AWS_ACCESS_KEY_ID=$(jq -er .result.accessKeyId "$scratch/session.json")
  AWS_SECRET_ACCESS_KEY=$(jq -er .result.secretAccessKey "$scratch/session.json")
  AWS_SESSION_TOKEN=$(jq -er .result.sessionToken "$scratch/session.json")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  "$@"
)
cat > "$scratch/first/main.tf" <<'HCL'
terraform {
  required_version = "= 1.12.6"
  backend "s3" {}
}
output "proof" { value = "synthetic-state-backend-v1" }
HCL
cat > "$scratch/backend.hcl" <<HCL
bucket = "cloudflare-bootstrap-state"
key = "$prefix/state.tfstate"
workspace_key_prefix = "$prefix/workspaces"
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
stage=initialize
native timeout 60 tofu -chdir="$scratch/first" init -input=false -no-color -backend-config="$scratch/backend.hcl" > "$scratch/evidence/init.log" 2>&1 || stop
stage=synthetic-state
native timeout 60 tofu -chdir="$scratch/first" apply -auto-approve -lock-timeout=0s -input=false -no-color > "$scratch/evidence/apply.log" 2>&1 || stop
native timeout 30 tofu -chdir="$scratch/first" state pull > "$scratch/evidence/before.json" 2> "$scratch/evidence/pull.log" || stop
jq -e '.version==4 and (.resources|length)==0 and .outputs.proof.value=="synthetic-state-backend-v1" and (.lineage|type=="string" and length>0)' "$scratch/evidence/before.json" >/dev/null 2>&1 || stop
stage=lock
native bash "$root/scripts/prove-native-state-lock.sh" "$scratch/first" "$scratch/evidence" > "$scratch/evidence/lock.log" 2>&1 || stop
stage=fresh-recovery
# Copy HCL only. The new directory receives no local state, cache or backend
# metadata from the first directory and must recover from R2 independently.
cp "$scratch/first/main.tf" "$scratch/fresh/main.tf"
native timeout 60 tofu -chdir="$scratch/fresh" init -input=false -no-color -backend-config="$scratch/backend.hcl" > "$scratch/evidence/fresh-init.log" 2>&1 || stop
native timeout 30 tofu -chdir="$scratch/fresh" state pull > "$scratch/evidence/after.json" 2> "$scratch/evidence/fresh-pull.log" || stop
jq -e --slurpfile before "$scratch/evidence/before.json" '.lineage==$before[0].lineage and .serial==$before[0].serial and .outputs==$before[0].outputs and .resources==$before[0].resources' "$scratch/evidence/after.json" >/dev/null 2>&1 || stop
native timeout 30 tofu -chdir="$scratch/fresh" plan -lock-timeout=0s -detailed-exitcode -input=false -no-color > "$scratch/evidence/fresh-plan.log" 2>&1 || stop
# The EXIT handler encrypts evidence successfully before emitting the verdict.
