#!/usr/bin/env bash
# Native age transport with a bounded provider/CLI fixture; never applies.
set -euo pipefail
umask 077
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/root" "$scratch/root/.github"
for file in main.tf variables.tf versions.tf providers.tf outputs.tf .terraform.lock.hcl; do
  cp "$repo_root/$file" "$scratch/root/$file"
done
age-keygen -o "$scratch/key" 2>/dev/null
age-keygen -y "$scratch/key" > "$scratch/root/.github/dns-recovery-recipient.txt"
actual_shasum=$(command -v shasum)
cat > "$scratch/bin/shasum" <<'HASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == *'/migration.tfplan.json.age' ]]; then
  if [[ $FIXTURE_CASE == hash-failed ]]; then exit 1; fi
  if [[ $FIXTURE_CASE == hash-empty ]]; then printf '\n'; exit 0; fi
fi
exec "$FIXTURE_SHASUM" "$@"
HASH
cat > "$scratch/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${CLOUDFLARE_API_TOKEN:-} ]]
url='' output=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --disable|--silent) shift ;;
    --config) [[ $2 == - ]]; shift 2 ;;
    --request) [[ $2 == GET ]]; shift 2 ;;
    --proto) [[ $2 == '=https' ]]; shift 2 ;;
    --noproxy) [[ $2 == '*' ]]; shift 2 ;;
    --max-redirs) [[ $2 == 0 ]]; shift 2 ;;
    --connect-timeout|--max-time|--max-filesize) shift 2 ;;
    --output) output=$2; shift 2 ;;
    --write-out) [[ $2 == '%{http_code}' ]]; shift 2 ;;
    --url) url=$2; shift 2 ;;
    *) exit 81 ;;
  esac
done
IFS= read -r header
[[ $header == 'header = "Authorization: Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' ]]
printf '%s\n' "$url" >> "$FIXTURE_DIR/calls"
case $url in
  'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:[{id:"11111111111111111111111111111111",name:(if $scenario=="wrong-zone" then "other.invalid" else "devantler.tech" end),status:"active",account:{id:"22222222222222222222222222222222"}}],result_info:{total_count:1,total_pages:1}}' > "$output"
    if [[ $FIXTURE_CASE == duplicate-json ]]; then
      printf '%s\n' '{"success":false,"success":true,"result":[],"result_info":{}}' > "$output"
    fi
    printf '200' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/cloudflare-bootstrap-state')
    if [[ $FIXTURE_CASE == bucket-present ]]; then
      printf '%s\n' '{"success":true,"result":{"name":"cloudflare-bootstrap-state"}}' > "$output"
      printf '200'
    elif [[ $FIXTURE_CASE == bucket-denied ]]; then
      printf '%s\n' '{"success":false,"errors":[{"code":10003,"message":"PRIVATE_FIXTURE_ERROR"}]}' > "$output"
      printf '403'
    else
      printf '%s\n' '{"success":false,"errors":[{"code":10006,"message":"PRIVATE_FIXTURE_ERROR"}],"result":null}' > "$output"
      printf '404'
    fi ;;
  *) exit 82 ;;
esac
CURL
cat > "$scratch/bin/tofu" <<'TOFU'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -chdir=* ]]
work=${1#-chdir=}; shift
[[ -n ${CLOUDFLARE_API_TOKEN:-} && -z ${TF_CLI_ARGS_plan:-} && -z ${TF_LOG:-} && -z ${CLOUDFLARE_API_BASE_URL:-} ]]
printf '%s\n' "$1" >> "$FIXTURE_DIR/tofu-calls"
printf 'PRIVATE_FIXTURE_PROVIDER_OUTPUT\n' >&2
case $1 in
  init) [[ -f $work/backend_override.tf && -f $work/production.auto.tfvars.json ]] ;;
  import)
    [[ ${*: -2:1} == cloudflare_zone.primary && ${*: -1} == 11111111111111111111111111111111 ]]
    [[ $FIXTURE_CASE != import-failed ]] ;;
  state)
    [[ $2 == pull ]]
    # State output is data, not a log.
    jq -n --arg scenario "$FIXTURE_CASE" '{version:4,terraform_version:"1.12.6",serial:1,lineage:"12345678-1234-1234-1234-123456789abc",outputs:{},resources:[{mode:"managed",type:"cloudflare_zone",name:"primary",provider:"provider[\"registry.opentofu.org/cloudflare/cloudflare\"]",instances:[{attributes:{id:"11111111111111111111111111111111",name:"devantler.tech",account:{id:(if $scenario=="wrong-state-account" then "33333333333333333333333333333333" else "22222222222222222222222222222222" end)}}}]}]}'
    ;;
  plan)
    [[ $FIXTURE_CASE != plan-failed ]]
    printf 'PRIVATE_FIXTURE_SAVED_PLAN' > "$work/migration.tfplan"
    exit 2 ;;
  show)
    jq --arg scenario "$FIXTURE_CASE" '
      if $scenario=="zone-update" then .resource_changes[0].change.actions=["update"]
      elif $scenario=="extra-resource" then .resource_changes += [{address:"cloudflare_dns_record.records[\"unowned\"]",mode:"managed",type:"cloudflare_dns_record",change:{actions:["create"]}}]
      elif $scenario=="delete" then .resource_changes[1].change.actions=["delete","create"]
      elif $scenario=="wrong-plan-account" then .resource_changes[1].change.after.account_id="33333333333333333333333333333333"
      elif $scenario=="wrong-bucket" then .resource_changes[1].change.after.name="another-bucket"
      elif $scenario=="deferred" then .deferred_changes=[{reason:"resource_config_unknown"}]
      elif $scenario=="errored" then .errored=true
      else . end' "$FIXTURE_PLAN" ;;
  *) exit 83 ;;
esac
TOFU
chmod +x "$scratch/bin/curl" "$scratch/bin/tofu" "$scratch/bin/shasum"
jq -n '{format_version:"1.2",terraform_version:"1.12.6",resource_changes:[{address:"cloudflare_zone.primary",mode:"managed",type:"cloudflare_zone",change:{actions:["no-op"],before:{id:"11111111111111111111111111111111"},after:{id:"11111111111111111111111111111111"}}},{address:"cloudflare_r2_bucket.buckets[\"cloudflare-bootstrap-state\"]",mode:"managed",type:"cloudflare_r2_bucket",change:{actions:["create"],before:null,after:{account_id:"22222222222222222222222222222222",name:"cloudflare-bootstrap-state",jurisdiction:"default",storage_class:"Standard"}}}]}' > "$scratch/plan.json"
# Exercise one successful or refused run and independently inspect its transport.
run_case() {
  local scenario=$1 expected=$2 rc=0 ref=refs/heads/main confirmation=PLAN_STATE_BOOTSTRAP credential=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  local case_dir="$scratch/$scenario"
  mkdir "$case_dir"
  [[ $scenario != wrong-ref ]] || ref=refs/heads/feature
  [[ $scenario != wrong-confirmation ]] || confirmation=APPLY
  [[ $scenario != missing-credential ]] || credential=''
  PATH="$scratch/bin:$PATH" FIXTURE_DIR="$case_dir" FIXTURE_CASE="$scenario" FIXTURE_PLAN="$scratch/plan.json" FIXTURE_SHASUM="$actual_shasum" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF="$ref" GITHUB_REPOSITORY=devantler-tech/cloudflare \
    GITHUB_ACTOR=devantler GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_RUN_ID=12345 \
    CONFIRMATION="$confirmation" CLOUDFLARE_API_TOKEN="$credential" TF_LOG=TRACE TF_CLI_ARGS_plan=-destroy \
    CLOUDFLARE_API_BASE_URL=https://untrusted.invalid OUTPUT_DIR="$case_dir/output" DIAGNOSTICS_DIR="$case_dir/diagnostics" \
    bash "$repo_root/scripts/plan-state-bootstrap.sh" "$scratch/root" > "$case_dir/result" 2>&1 || rc=$?
  if [[ $expected == success ]]; then
    [[ $rc == 0 ]] || { cat "$case_dir/result"; exit 1; }
    grep -q '^CLOUDFLARE_BOOTSTRAP_PLAN=ENCRYPTED review=required provider_writes=0$' "$case_dir/result"
    [[ $(find "$case_dir/output" -type f | wc -l) -eq 6 ]]
    bash "$repo_root/scripts/check-state-recovery-package.sh" "$scratch/root" "$case_dir/output/state" --identity-file "$scratch/key" >/dev/null
    age --decrypt -i "$scratch/key" "$case_dir/output/migration.tfplan.json.age" > "$case_dir/plan.json" 2>/dev/null
    cmp -s "$scratch/plan.json" "$case_dir/plan.json"
    age --decrypt -i "$scratch/key" "$case_dir/output/migration.tfplan.age" > "$case_dir/plan" 2>/dev/null
    [[ $(cat "$case_dir/plan") == PRIVATE_FIXTURE_SAVED_PLAN ]]
    jq -e '.schemaVersion==1 and .kind=="cloudflare-state-bootstrap-plan" and .sourceRun==12345 and .sourceCommit=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .resourceCreates==1 and .resourceUpdates==0 and .resourceDeletes==0' "$case_dir/output/plan-manifest.json" >/dev/null
    for pair in "stateManifestSha256:$case_dir/output/state/manifest.json" "binaryPlaintextSha256:$case_dir/plan" "binaryCiphertextSha256:$case_dir/output/migration.tfplan.age" "jsonPlaintextSha256:$case_dir/plan.json" "jsonCiphertextSha256:$case_dir/output/migration.tfplan.json.age"; do
      expected_hash=$("$actual_shasum" -a 256 "${pair#*:}")
      jq -e --arg field "${pair%%:*}" --arg expected "${expected_hash%% *}" '.[$field]==$expected' "$case_dir/output/plan-manifest.json" >/dev/null
    done
    [[ $(wc -l < "$case_dir/calls") -eq 2 ]]
    [[ $(tr '\n' ' ' < "$case_dir/tofu-calls") == 'init import plan show state ' ]]
    [[ ! -e $case_dir/diagnostics ]]
  else
    [[ $rc == 2 && ! -e $case_dir/output ]] || { cat "$case_dir/result"; exit 1; }
    if [[ $scenario != wrong-ref && $scenario != wrong-confirmation && $scenario != missing-credential ]]; then
      [[ -f $case_dir/diagnostics/diagnostics.tar.gz.age ]]
      age --decrypt -i "$scratch/key" "$case_dir/diagnostics/diagnostics.tar.gz.age" > "$case_dir/diagnostics.tar.gz" 2>/dev/null
      mkdir "$case_dir/decrypted-diagnostics"
      tar -xzf "$case_dir/diagnostics.tar.gz" -C "$case_dir/decrypted-diagnostics"
      jq -e '.schemaVersion==1 and .kind=="cloudflare-state-bootstrap-diagnostics" and .sourceRun==12345 and .exitCode==2 and (.stage|type=="string")' "$case_dir/decrypted-diagnostics/diagnostics-metadata.json" >/dev/null
      if [[ $scenario == import-failed || $scenario == plan-failed ]]; then
        grep -q PRIVATE_FIXTURE_PROVIDER_OUTPUT "$case_dir/decrypted-diagnostics/"*.log
      fi
    fi
  fi
  if grep -Eq 'PRIVATE_FIXTURE|AAAAAAAAAAAAAAAAAAAA|22222222222222222222222222222222|devantler.tech|untrusted.invalid' "$case_dir/result"; then
    printf 'FAIL: private fixture data reached the result\n' >&2
    exit 1
  fi
  if [[ $scenario == wrong-ref || $scenario == wrong-confirmation || $scenario == missing-credential ]]; then
    [[ ! -e $case_dir/calls && ! -e $case_dir/tofu-calls ]]
  fi
}
run_case good success
for scenario in wrong-ref wrong-confirmation missing-credential wrong-zone duplicate-json bucket-present bucket-denied import-failed plan-failed wrong-state-account zone-update extra-resource delete wrong-plan-account wrong-bucket deferred errored hash-failed hash-empty; do
  run_case "$scenario" refused
done
printf '%s\n' 'PASS: read-only bootstrap plan, exact change boundary and native encrypted transport'
