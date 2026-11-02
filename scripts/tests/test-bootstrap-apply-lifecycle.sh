#!/usr/bin/env bash
# Linux/tmpfs lifecycle proof with native age and offline provider/publication doubles.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if ! command -v findmnt >/dev/null || [[ ! -d /dev/shm ]] || [[ $(findmnt -n -o FSTYPE --target /dev/shm) != tmpfs ]]; then
  printf '%s\n' 'SKIP: Linux/tmpfs bootstrap lifecycle is exercised by Ubuntu CI'
  exit 0
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for scenario in success apply-failed drift capture-failed publication-failed existing-bucket failed-canary; do
  fixture="$scratch/$scenario"
  mkdir -p "$fixture/repo/.github" "$fixture/repo/recovery" "$fixture/bin"
  cp -R "$root/scripts" "$fixture/repo/"
  for file in main.tf variables.tf versions.tf providers.tf outputs.tf .terraform.lock.hcl; do cp "$root/$file" "$fixture/repo/"; done
  age-keygen -o "$fixture/identity" 2>/dev/null
  age-keygen -y "$fixture/identity" > "$fixture/repo/.github/dns-recovery-recipient.txt"
  printf '%s\n' '{"account_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","zone_name":"devantler.tech","dns_records":{},"r2_buckets":{"cloudflare-bootstrap-state":{"jurisdiction":"default","storage_class":"Standard"}},"r2_lifecycle_rules":{},"account_tokens":{}}' > "$fixture/configuration.json"
  printf '%s\n' '{"version":4,"terraform_version":"1.12.6","lineage":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","serial":1,"outputs":{},"resources":[{"mode":"managed","type":"cloudflare_zone","name":"primary","instances":[{"attributes":{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"devantler.tech","account":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}]}]}' > "$fixture/state.json"
  printf '%s\n' 'SYNTHETIC_APPROVED_BINARY' > "$fixture/plan"
  printf '%s\n' '{"resource_changes":[{"address":"cloudflare_zone.primary","mode":"managed","type":"cloudflare_zone","change":{"actions":["no-op"],"before":{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"after":{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}},{"address":"cloudflare_r2_bucket.buckets[\"cloudflare-bootstrap-state\"]","mode":"managed","type":"cloudflare_r2_bucket","change":{"actions":["create"],"before":null,"after":{"account_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"cloudflare-bootstrap-state","jurisdiction":"default","storage_class":"Standard"}}}]}' > "$fixture/plan.json"
  bash "$root/scripts/prepare-state-recovery-package.sh" "$fixture/repo" "$fixture/state.json" "$fixture/configuration.json" "$fixture/repo/recovery/state" 1111111111111111111111111111111111111111 123456789 2026-11-02T00:00:00Z >/dev/null
  # Bind this disposable scenario's native state and plan bytes to its fixture.
  hash() { shasum -a 256 "$1" | awk '{print $1}'; }
  # Supply base64 fixture DATA to the driver, never an actual provider credential.
  encode() { base64 < "$1" | tr -d '\n'; }
  jq -n --arg manifest "$(hash "$fixture/repo/recovery/state/manifest.json")" --arg binary "$(hash "$fixture/plan")" --arg json "$(hash "$fixture/plan.json")" '{schemaVersion:1,kind:"cloudflare-state-bootstrap-plan",sourceCommit:"1111111111111111111111111111111111111111",sourceRun:123456789,stateManifestSha256:$manifest,binaryPlaintextSha256:$binary,jsonPlaintextSha256:$json,resourceCreates:1,resourceUpdates:0,resourceDeletes:0}' > "$fixture/repo/.github/bootstrap-plan-approval.json"
  jq -n --arg state "$(encode "$fixture/state.json")" --arg configuration "$(encode "$fixture/configuration.json")" --arg plan "$(encode "$fixture/plan")" --arg planJson "$(encode "$fixture/plan.json")" '{state:$state,configuration:$configuration,plan:$plan,planJson:$planJson}' > "$fixture/input.json"
  cat > "$fixture/bin/tofu" <<'TOFU'
#!/usr/bin/env bash
set -euo pipefail
test -z "${GH_TOKEN+x}" && test -z "${GITHUB_TOKEN+x}"
work=${1#-chdir=}; shift
case "$1" in
  version) printf '%s\n' '{"terraform_version":"1.12.6"}' ;;
  init) test -z "${CLOUDFLARE_API_TOKEN+x}" ;;
  show) test -z "${CLOUDFLARE_API_TOKEN+x}"; cat "$FIXTURE/plan.json" ;;
  apply)
    test -n "${CLOUDFLARE_API_TOKEN:-}" && test -f "$FIXTURE/checkpoint" && test -f "$FIXTURE/canary"
    touch "$FIXTURE/applied"
    jq '.serial=2 | .resources+=[{mode:"managed",type:"cloudflare_r2_bucket",name:"buckets",instances:[{index_key:"cloudflare-bootstrap-state",attributes:{id:"cloudflare-bootstrap-state",name:"cloudflare-bootstrap-state",account_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",jurisdiction:"default",storage_class:"Standard"}}]}]' "$work/terraform.tfstate" > "$work/next.json"
    mv "$work/next.json" "$work/terraform.tfstate"
    if [[ $SCENARIO == apply-failed ]]; then exit 1; fi
    ;;
  plan) test -n "${CLOUDFLARE_API_TOKEN:-}"; if [[ $SCENARIO == drift ]]; then exit 2; fi ;;
  state)
    test -z "${CLOUDFLARE_API_TOKEN+x}"
    if [[ $SCENARIO == capture-failed ]]; then exit 1; fi
    cat "$work/terraform.tfstate"
    ;;
  *) exit 1 ;;
esac
TOFU
  cat > "$fixture/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
output=''
for argument in "$@"; do
  if [[ $output == pending ]]; then output=$argument; break; fi
  if [[ $argument == --output ]]; then output=pending; fi
done
if [[ $SCENARIO == existing-bucket ]]; then printf '%s\n' '{"success":true,"result":{}}' > "$output"; printf 200; else printf '%s\n' '{"success":false,"result":null,"errors":[{"code":10006}]}' > "$output"; printf 404; fi
CURL
  cat > "$fixture/repo/scripts/publish-bootstrap-state.sh" <<'PUBLISH'
#!/usr/bin/env bash
set -euo pipefail
test -z "${CLOUDFLARE_API_TOKEN+x}" && test -z "${CLOUDFLARE_BOOTSTRAP_APPROVED_DATA+x}"
if [[ $3 == verify ]]; then
  test -n "${CUSTODY_RUN:-}"
  if [[ $SCENARIO == failed-canary ]]; then exit 1; fi
  touch "$FIXTURE/canary"; exit 0
fi
if [[ $3 == checkpoint ]]; then test -f "$FIXTURE/canary"; touch "$FIXTURE/checkpoint"; exit 0; fi
bash "$1/scripts/check-state-recovery-package.sh" "$1" "$2" >/dev/null
cp -R "$2" "$FIXTURE/published"
if [[ $SCENARIO == publication-failed ]]; then exit 1; fi
PUBLISH
  chmod +x "$fixture/bin/tofu" "$fixture/bin/curl"
  result=0
  env PATH="$fixture/bin:$PATH" FIXTURE="$fixture" SCENARIO="$scenario" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR=devantler GITHUB_RUN_ATTEMPT=1 RUNNER_ENVIRONMENT=github-hosted \
    GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/state-bootstrap-apply.yaml@refs/heads/main GITHUB_RUN_ID=123456789 GITHUB_SHA=1111111111111111111111111111111111111111 \
    BOOTSTRAP_MODE=apply CONFIRMATION=APPLY_STATE_BOOTSTRAP CUSTODY_RUN=987654321 GH_TOKEN=SYNTHETIC_GITHUB_TOKEN CLOUDFLARE_API_TOKEN=SYNTHETIC_PROVIDER_TOKEN CLOUDFLARE_BOOTSTRAP_APPROVED_DATA="$(cat "$fixture/input.json")" OUTPUT_DIR="$fixture/output" \
    bash "$fixture/repo/scripts/apply-state-bootstrap.sh" "$fixture/repo" > "$fixture/stdout" 2> "$fixture/stderr" || result=$?
  if [[ $scenario == success ]]; then
    test "$result" == 0
    grep -q 'mode=apply provider_writes=1 custody=VERIFIED convergence=VERIFIED' "$fixture/stdout"
    bash "$root/scripts/check-state-recovery-package.sh" "$fixture/repo" "$fixture/published" --identity-file "$fixture/identity" >/dev/null
  else
    test "$result" != 0
    if grep -q 'CLOUDFLARE_BOOTSTRAP_APPLY=VERIFIED' "$fixture/stdout"; then exit 1; fi
    if [[ $scenario == existing-bucket || $scenario == failed-canary ]]; then
      test ! -f "$fixture/applied" && test ! -f "$fixture/checkpoint"
    else
      test -f "$fixture/applied"
      age -d -i "$fixture/identity" -o "$fixture/diagnostics.tar.gz" "$fixture/output/diagnostics.tar.gz.age" 2>/dev/null
      mkdir "$fixture/diagnostics"
      tar -xzf "$fixture/diagnostics.tar.gz" -C "$fixture/diagnostics"
      jq -e '.serial==2 and .lineage=="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"' "$fixture/diagnostics/work-terraform.tfstate" >/dev/null
      if [[ $scenario != capture-failed ]]; then
        bash "$root/scripts/check-state-recovery-package.sh" "$fixture/repo" "$fixture/published" --identity-file "$fixture/identity" >/dev/null
      fi
    fi
  fi
  if grep -q 'SYNTHETIC_GITHUB_TOKEN\|SYNTHETIC_PROVIDER_TOKEN' "$fixture/stdout" "$fixture/stderr"; then exit 1; fi
done
printf '%s\n' 'PASS: offline bootstrap lifecycle retains authentic recovery after partial apply and refused convergence'
