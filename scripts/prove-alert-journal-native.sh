#!/usr/bin/env bash
# Exercise the reviewed journal implementation against one isolated R2 object.
# No provider resource, infrastructure state, route or permanent key is changed.
set +x
set -euo pipefail
umask 077
stage=dispatch
# Report a closed refusal stage without printing provider output.
stop() { stage=$1; printf 'R2_JOURNAL_NATIVE=UNVERIFIED stage=%s\n' "$stage" >&2; exit 2; }
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main &&
   ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_ACTOR:-} == devantler &&
   ${GITHUB_RUN_ATTEMPT:-} == 1 && ${RUNNER_ENVIRONMENT:-} == github-hosted &&
   ${GITHUB_WORKFLOW_REF:-} == devantler-tech/cloudflare/.github/workflows/alert-journal-native.yaml@refs/heads/main &&
   ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{6,15}$ &&
   ${CONFIRMATION:-} == PROVE_ALERT_JOURNAL ]] || stop dispatch
provider_token=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_API_TOKEN
[[ ${#provider_token} -ge 20 && ${#provider_token} -le 512 && $provider_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop credential
[[ $# == 1 && -d $1 && ! -L $1 ]] || stop root
root=$1
source_revision=19accd41ee1e12493b7d56ddf175dde3efb7ce00
stage=configuration
[[ -n ${RUNNER_TEMP:-} && $RUNNER_TEMP == /* && -d $RUNNER_TEMP && ! -L $RUNNER_TEMP &&
   -f $RUNNER_TEMP/native-alert-journal.test && ! -L $RUNNER_TEMP/native-alert-journal.test &&
   -x $RUNNER_TEMP/native-alert-journal.test &&
   -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR &&
   $(git -C "$root" rev-parse HEAD) == "$GITHUB_SHA" &&
   $(git -C "$root/journal-source" rev-parse HEAD) == "$source_revision" ]] || stop configuration
for tool in jq curl age tar shasum timeout findmnt; do command -v "$tool" >/dev/null 2>&1 || stop tools;done
[[ $(findmnt -n -o FSTYPE --target /dev/shm) == tmpfs ]] || stop scratch
# No caller-selected TLS roots, proxy, curl configuration or AWS credentials.
unset CURL_HOME CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
# shellcheck source=scripts/r2-backend-common.sh
source "$root/scripts/r2-backend-common.sh"
recipient=$(state_recipient "$root")
scratch=$(mktemp -d /dev/shm/alert-journal-proof.XXXXXXXX)
mkdir "$scratch/home"
scope_verified=false native_exit=255
# Retain encrypted bounded diagnostics, never API responses or credentials.
finish() {
  local rc=$? file cipher_hash
  local files=(metadata.json)
  trap - EXIT
  jq -n --arg source "$GITHUB_SHA" --argjson run "$GITHUB_RUN_ID" --arg journal "$source_revision" \
    --arg stage "$stage" --argjson code "$native_exit" --argjson scope "$scope_verified" \
    '{schemaVersion:1,kind:"cloudflare-alert-journal-native-proof",sourceCommit:$source,sourceRun:$run,journalSource:$journal,stage:$stage,nativeExitCode:$code,scopeVerified:$scope,providerResourceWrites:0}' > "$scratch/metadata.json" || rc=2
  for file in api-status.log head-status.log native.log curl.log;do
    if [[ -f $scratch/$file && ! -L $scratch/$file && $(wc -c < "$scratch/$file") -le 1048576 ]];then files+=("$file");fi
  done
  if tar -czf "$scratch/evidence.tar.gz" -C "$scratch" "${files[@]}" 2>/dev/null &&
     age -r "$recipient" -o "$scratch/evidence.tar.gz.age" "$scratch/evidence.tar.gz" 2>/dev/null &&
     mkdir -m 700 "$OUTPUT_DIR" && mv "$scratch/evidence.tar.gz.age" "$OUTPUT_DIR/evidence.tar.gz.age";then
    cipher_hash=$(state_hash "$OUTPUT_DIR/evidence.tar.gz.age")
    jq -n --arg source "$GITHUB_SHA" --argjson run "$GITHUB_RUN_ID" --arg journal "$source_revision" \
      --arg hash "$cipher_hash" --argjson result "$rc" \
      '{schemaVersion:1,kind:"cloudflare-alert-journal-native-proof",sourceCommit:$source,sourceRun:$run,journalSource:$journal,ciphertextSha256:$hash,exitCode:$result,providerResourceWrites:0}' > "$OUTPUT_DIR/manifest.json" || rc=2
  else rc=2;fi
  rm -rf "$scratch"
  if [[ $rc == 0 ]];then
    printf '%s\n' 'R2_JOURNAL_NATIVE=PASS conditional_conflict=VERIFIED lost_ack=VERIFIED restart=VERIFIED scope=VERIFIED'
  else printf 'R2_JOURNAL_NATIVE=UNVERIFIED stage=%s\n' "$stage" >&2;fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 2' INT TERM
printf 'recipient validation\n' | age -r "$recipient" -o "$scratch/probe.age" 2>/dev/null || stop recipient
# The parent token is used only for these fixed provider API calls. It is never
# inherited by the journal binary or retained in evidence.
request() {
  local method=$1 url=$2 response=$3 body=${4:-} status
  local -a args=(--request "$method" --url "$url" --output "$response")
  if [[ -n "$body" ]];then args+=(--header 'Content-Type: application/json' --data-binary "@$body");fi
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$provider_token" |
    curl --disable --config - --proto '=https' --noproxy '*' --max-redirs 0 \
      --connect-timeout 10 --max-time 30 --max-filesize 32768 --silent \
      --write-out '%{http_code}' "${args[@]}" 2>> "$scratch/curl.log") || return 1
  [[ $status =~ ^[0-9]{3}$ ]] || return 1
  printf '%s %s\n' "$stage" "$status" >> "$scratch/api-status.log"
  [[ $status == 200 ]] && state_unique_json "$response" &&
    jq -e '.success==true and (.errors==null or .errors==[])' "$response" >/dev/null 2>&1
}
stage=zone
request GET 'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50' "$scratch/zone.json" || stop zone
jq -e '.result_info.total_count==1 and .result_info.total_pages==1 and (.result|type=="array" and length==1) and .result[0].name=="devantler.tech" and .result[0].status=="active" and (.result[0].account.id|type=="string" and test("^[a-f0-9]{32}$"))' "$scratch/zone.json" >/dev/null 2>&1 || stop zone-binding
account=$(jq -er .result[0].account.id "$scratch/zone.json")
stage=parent
request GET "https://api.cloudflare.com/client/v4/accounts/$account/tokens/verify" "$scratch/parent.json" || stop parent
parent=$(jq -er 'if .result.status=="active" and (.result.id|type=="string" and test("^[a-f0-9]{32}$")) then .result.id else error("invalid") end' "$scratch/parent.json" 2>/dev/null) || stop parent-binding
stage=bucket
request GET "https://api.cloudflare.com/client/v4/accounts/$account/r2/buckets/cloudflare-bootstrap-state" "$scratch/bucket.json" || stop bucket
jq -e '.result.name=="cloudflare-bootstrap-state" and .result.jurisdiction=="default"' "$scratch/bucket.json" >/dev/null 2>&1 || stop bucket-binding
stage=session
jq -n --arg parent "$parent" '{parentAccessKeyId:$parent,bucket:"cloudflare-bootstrap-state",permission:"object-read-write",ttlSeconds:900,objects:["proofs/alert-journal-native-v1.json"]}' > "$scratch/request.json"
request POST "https://api.cloudflare.com/client/v4/accounts/$account/r2/temp-access-credentials" "$scratch/session.json" "$scratch/request.json" || stop session
backend_session "$scratch/session.json" || stop session-binding
jq .result "$scratch/session.json" > "$scratch/credential.json"
unset provider_token parent
# curl's native SigV4 implementation receives its credential through stdin.
# HEAD observes metadata only. Positive authentication must succeed first, so
# an invalid signature cannot masquerade as the required scope denial.
scoped_head() {
  jq -r '"user = \((.accessKeyId+":"+.secretAccessKey)|@json)\nheader = \(("x-amz-security-token: "+.sessionToken)|@json)"' "$scratch/credential.json" |
    curl --disable --config - --aws-sigv4 aws:amz:auto:s3 --head --proto '=https' \
      --noproxy '*' --max-redirs 0 --connect-timeout 5 --max-time 15 --silent \
      --output /dev/null --write-out '%{http_code}' \
      --url "https://$account.r2.cloudflarestorage.com/cloudflare-bootstrap-state/$1" 2>> "$scratch/curl.log"
}
stage=proof-absence
status=$(scoped_head proofs/alert-journal-native-v1.json) || stop proof-absence
printf 'proof-absence %s\n' "$status" >> "$scratch/head-status.log"
[[ $status == 404 ]] || stop proof-absence
stage=scope
status=$(scoped_head cloudflare/production.tfstate) || stop scope
printf 'outside-proof %s\n' "$status" >> "$scratch/head-status.log"
[[ $status == 403 ]] || stop scope
scope_verified=true
jq -n --arg account "$account" '{accountId:$account,bucket:"cloudflare-bootstrap-state",key:"proofs/alert-journal-native-v1.json",instance:"alert-journal-native-proof"}' > "$scratch/configuration.json"
stage=native-proof
native_exit=0
env -i PATH="$PATH" HOME="$scratch/home" TMPDIR="$scratch" \
  ALERT_R2_PROVIDER_PROOF=run-once ALERT_R2_PROOF_CONFIG_FILE="$scratch/configuration.json" \
  ALERT_R2_PROOF_CREDENTIAL_FILE="$scratch/credential.json" \
  timeout --kill-after=5s 110 "$RUNNER_TEMP/native-alert-journal.test" \
    -test.run='^TestR2NativeProviderConflictLostResponseAndProcessExit$' -test.count=1 -test.timeout=105s -test.v \
    > "$scratch/native.log" 2>&1 || native_exit=$?
[[ $native_exit == 0 ]] || stop native-proof
grep -Fq 'R2_PROVIDER_STORAGE_PROOF=PASS conditional-conflict lost-response durable-intent' "$scratch/native.log" || stop native-receipt
stage=complete
