#!/usr/bin/env bash
# Reviewed DNS changes against the authoritative R2 state. The change phase
# imports declared records that already exist, refuses deletes, replacements
# and changing imports, and in apply mode captures encrypted state before and
# after the apply. The recover phase plans from a fresh runner and must find
# nothing to do. Only fixed verdict lines reach the log; values stay encrypted.
set +x
set -euo pipefail
umask 077
stage=dispatch scratch='' output_created=false
stop() { exit 2; }
finish() {
  local rc=$?
  if [[ -n $scratch ]]; then
    if [[ $output_created == true && -d $scratch/evidence ]]; then
      tar -czf "$scratch/evidence.tar.gz" -C "$scratch" evidence >/dev/null 2>&1 &&
        age -r "$recipient" -o "$OUTPUT_DIR/evidence.tar.gz.age" "$scratch/evidence.tar.gz" 2>/dev/null || rc=2
    fi
    rm -rf "$scratch"
  fi
  if [[ $rc != 0 ]]; then
    printf 'CLOUDFLARE_DNS_CHANGE=UNVERIFIED stage=%s\n' "$stage" >&2
    exit 2
  fi
  printf 'CLOUDFLARE_DNS_CHANGE=VERIFIED mode=%s phase=%s\n' "$DNS_MODE" "$DNS_PHASE"
}
trap finish EXIT
trap 'exit 2' INT TERM
[[ ${BASH_VERSINFO[0]} -ge 5 && $# == 1 && -d $1 && ! -L $1 &&
  ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare &&
  ${GITHUB_REF:-} == refs/heads/main && ${GITHUB_ACTOR:-} == devantler &&
  ${GITHUB_RUN_ATTEMPT:-} == 1 && ${RUNNER_ENVIRONMENT:-} == github-hosted &&
  ${GITHUB_WORKFLOW_REF:-} == devantler-tech/cloudflare/.github/workflows/dns-apply.yaml@refs/heads/main &&
  ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{5,15}$ &&
  ( ( ${DNS_MODE:-} == plan && ${CONFIRMATION:-} == PLAN_DNS && ${DNS_PHASE:-} == change ) ||
    ( ${DNS_MODE:-} == apply && ${CONFIRMATION:-} == APPLY_DNS &&
      ( ${DNS_PHASE:-} == change || ${DNS_PHASE:-} == recover ) ) ) ]] || stop
root=$1
# shellcheck source=scripts/r2-backend-common.sh
source "$root/scripts/r2-backend-common.sh"
stage=configuration
[[ -n ${CLOUDFLARE_BOOTSTRAP_CONFIGURATION:-} && ${#CLOUDFLARE_BOOTSTRAP_CONFIGURATION} -le 8388608 &&
  -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR &&
  $(findmnt -n -o FSTYPE --target /dev/shm) == tmpfs ]] || stop
for tool in tofu timeout jq curl age tar shasum; do command -v "$tool" >/dev/null 2>&1 || stop; done
scratch=$(mktemp -d /dev/shm/cloudflare-dns.XXXXXXXX)
mkdir "$scratch/evidence" "$scratch/home" "$scratch/work"
recipient=$(state_recipient "$root")
printf '%s' "$CLOUDFLARE_BOOTSTRAP_CONFIGURATION" | backend_configuration_input > "$scratch/configuration.json" || stop
unset CLOUDFLARE_BOOTSTRAP_CONFIGURATION
backend_configuration "$root" "$scratch/configuration.json" || stop
jq -e '.zone_name=="devantler.tech"' "$scratch/configuration.json" >/dev/null 2>&1 || stop
account=$(jq -er .account_id "$scratch/configuration.json")
retained="$root/recovery/backend-source/manifest.json"
mkdir "$OUTPUT_DIR"
output_created=true
stage=credential
root_token=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_API_TOKEN
[[ ${#root_token} -ge 20 && ${#root_token} -le 512 && $root_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop
# The account token reaches curl only through an inherited input pipe.
request() {
  local method=$1 url=$2 response=$3 body=${4:-} status rc=0
  local -a args=(--request "$method" --url "$url" --output "$response")
  if [[ -n $body ]]; then args+=(--header 'Content-Type: application/json' --data-binary "@$body"); fi
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
unset parent
# OpenTofu gets only the short-lived state session, plus the account token for
# provider steps. Nothing else from the runner environment reaches it.
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
tf() { native "$1" timeout --kill-after=10s 300 tofu -chdir="$scratch/work" "${@:2}"; }
# Plan to a saved file and render it as JSON in private evidence.
plan_json() {
  local name=$1 rc=0
  tf provider plan -input=false -lock-timeout=0s -no-color -out="$name.tfplan" > "$scratch/evidence/$name-plan.log" 2>&1 || rc=$?
  [[ $rc == 0 ]] || return 1
  tf local show -json "$name.tfplan" > "$scratch/evidence/$name.json" 2> "$scratch/evidence/$name-show.log" || return 1
  state_unique_json "$scratch/evidence/$name.json"
}
# Encrypt the current state with the unchanged configuration as one package.
capture() {
  local name=$1
  tf local state pull > "$scratch/evidence/$name-state.json" 2> "$scratch/evidence/$name-pull.log" || return 1
  bash "$root/scripts/prepare-state-recovery-package.sh" "$root" "$scratch/evidence/$name-state.json" \
    "$scratch/configuration.json" "$OUTPUT_DIR/$name" "$GITHUB_SHA" "$GITHUB_RUN_ID" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$scratch/evidence/$name-package.log" 2>&1
}
stage=source
for file in "$root"/*.tf "$root/.terraform.lock.hcl"; do
  [[ -f $file && ! -L $file && $file != *_override.tf ]] || stop
  cp "$file" "$scratch/work/"
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
tf local version -json > "$scratch/evidence/version.json" 2>/dev/null || stop
jq -e '.terraform_version=="1.12.6"' "$scratch/evidence/version.json" >/dev/null 2>&1 || stop
stage=initialize
tf local init -input=false -lockfile=readonly -no-color -backend-config="$scratch/backend.hcl" > "$scratch/evidence/init.log" 2>&1 || stop
stage=recovery-generation
# Bind the live state to the retained recovery generation: an apply that was
# not yet retained, or a different lineage, refuses every further change.
tf local state pull > "$scratch/evidence/start-state.json" 2> "$scratch/evidence/start-pull.log" || stop
state_unique_json "$scratch/evidence/start-state.json" || stop
if [[ $DNS_PHASE == change ]]; then
  jq -e --slurpfile retained "$retained" '.lineage==$retained[0].lineage and .serial==$retained[0].serial' \
    "$scratch/evidence/start-state.json" >/dev/null 2>&1 || stop
else
  # The change job just applied; recovery must find the same lineage, at least as new.
  jq -e --slurpfile retained "$retained" '.lineage==$retained[0].lineage and .serial>=$retained[0].serial' \
    "$scratch/evidence/start-state.json" >/dev/null 2>&1 || stop
  stage=recovery-capture
  capture recovered || stop
  stage=fresh-plan
  tf provider plan -input=false -lock-timeout=0s -detailed-exitcode -no-color > "$scratch/evidence/fresh-plan.log" 2>&1 || stop
  unset root_token
  exit 0
fi
stage=inventory
# shellcheck disable=SC2034 # collect_dns_snapshot reads it.
provider_token=$root_token
# shellcheck source=scripts/dns-snapshot-common.sh
source "$root/scripts/dns-snapshot-common.sh"
collect_dns_snapshot "$scratch"
unset provider_token
mv "$scratch/snapshot.json" "$scratch/evidence/snapshot.json"
rm -f "$scratch"/page-*.json "$scratch/records.json" "$scratch/zone.json"
jq -e --arg account "$account" '.zone.account.id==$account and .zone.name=="devantler.tech"' "$scratch/evidence/snapshot.json" >/dev/null 2>&1 || stop
stage=discover
plan_json discover || stop
jq --slurpfile snapshot "$scratch/evidence/snapshot.json" -f "$root/scripts/dns-imports.jq" \
  "$scratch/evidence/discover.json" > "$scratch/evidence/resolved.json" 2>/dev/null || stop
jq -r '.refused[]|"DNS_REFUSED address=\(.address) reason=\(.refused)"' "$scratch/evidence/resolved.json"
jq -e '.refused==[]' "$scratch/evidence/resolved.json" >/dev/null 2>&1 || stop
jq '.imports' "$scratch/evidence/resolved.json" > "$scratch/evidence/imports.json"
jq -r '.[]|"import {\n  to = \(.address)\n  id = \(.id|tojson)\n}\n"' "$scratch/evidence/imports.json" > "$scratch/work/imports.tf"
stage=plan
plan_json change || stop
# Public summary: addresses, actions and changed attribute names, never values.
jq -r '.resource_changes[] |
  (if .change.importing then "import" else (.change.actions|join("-")) end) as $action |
  select($action!="no-op") |
  ([(.change.before // {}), (.change.after // {})] as [$b,$a] |
    ([$b,$a]|map(keys)|add|unique) | map(select($b[.]!=$a[.]))) as $attributes |
  "DNS_PLAN address=\(.address) action=\($action)" +
  (if $action=="update" or ($action=="import" and .change.actions!=["no-op"]) then " attributes=\($attributes|join(","))" else "" end)
' "$scratch/evidence/change.json"
jq -r '.resource_drift[]? | "DNS_DRIFT address=\(.address) action=\(.change.actions|join("-"))"' "$scratch/evidence/change.json"
# Live records that nothing owns: not declared here, not external-dns, not a challenge.
jq -r --slurpfile plan "$scratch/evidence/change.json" --slurpfile imports "$scratch/evidence/imports.json" '
  ([$plan[0].prior_state.values.root_module.resources[]? | select(.type=="cloudflare_dns_record") | .values.id] +
   [$imports[0][] | .id | split("/")[1]]) as $managed |
  .records as $records |
  .records[] | . as $r |
  select((.id|IN($managed[]))|not) |
  select((.name|startswith("_externaldns.") or startswith("_acme-challenge."))|not) |
  select(any($records[]; .type=="TXT" and (.name=="_externaldns."+$r.name or .name=="_externaldns."+($r.type|ascii_downcase)+"-"+$r.name))|not) |
  "DNS_UNMANAGED name=\(.name) type=\(.type)"
' "$scratch/evidence/snapshot.json"
stage=boundary
bash "$root/scripts/assert-no-destructive-plan.sh" "$scratch/evidence/change.json" > "$scratch/evidence/destructive.log" 2>&1 || stop
jq -e --slurpfile imports "$scratch/evidence/imports.json" -f "$root/scripts/check-dns-plan.jq" "$scratch/evidence/change.json" >/dev/null 2>&1 || stop
if [[ $DNS_MODE == plan ]]; then unset root_token; exit 0; fi
stage=before-capture
capture before || stop
stage=apply
apply_rc=0
tf provider apply -input=false -lock-timeout=0s -no-color change.tfplan > "$scratch/evidence/apply.log" 2>&1 || apply_rc=$?
# Capture whatever the apply left behind before judging it.
stage=after-capture
capture after || stop
stage=apply
[[ $apply_rc == 0 ]] || stop
stage=convergence
rm "$scratch/work/imports.tf"
tf provider plan -input=false -lock-timeout=0s -detailed-exitcode -no-color > "$scratch/evidence/convergence-plan.log" 2>&1 || stop
unset root_token
