#!/usr/bin/env bash
set -euo pipefail
umask 077
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/root" "$scratch/root/.github"
for file in main.tf variables.tf versions.tf providers.tf outputs.tf .terraform.lock.hcl; do cp "$root/$file" "$scratch/root/$file"; done
age-keygen -o "$scratch/key" 2>/dev/null
age-keygen -y "$scratch/key" > "$scratch/root/.github/dns-recovery-recipient.txt"
cat > "$scratch/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${CLOUDFLARE_API_TOKEN:-} ]]
url=''
while [[ $# -gt 0 ]]; do
 case $1 in
 --disable|--silent|--fail) shift ;;
 --config) [[ $2 == - ]]; shift 2 ;;
 --request) [[ $2 == GET ]]; shift 2 ;;
 --proto) [[ $2 == '=https' ]]; shift 2 ;;
 --noproxy) [[ $2 == '*' ]]; shift 2 ;;
 --max-redirs) [[ $2 == 0 ]]; shift 2 ;;
 --connect-timeout|--max-time|--max-filesize) shift 2 ;;
 --url) url=$2;shift 2 ;;
 *) exit 80 ;;
 esac
done
IFS= read -r header
[[ $header == 'header = "Authorization: Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' ]]
printf '%s\n' "$url" >> "$FIXTURE_DIR/api"
case $url in
'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50')
 jq -n '{success:true,result:[{id:"11111111111111111111111111111111",name:"devantler.tech",status:"active",account:{id:"22222222222222222222222222222222"}}],result_info:{total_count:1,total_pages:1}}' ;;
'https://api.cloudflare.com/client/v4/zones/11111111111111111111111111111111/dns_records?per_page=1000&page=1')
 jq -n '{success:true,result: [
 {id:"00000000000000000000000000000001",name:"devantler.tech",type:"MX",content:"mx.example.test",priority:10},
 {id:"00000000000000000000000000000002",name:"devantler.tech",type:"TXT",content:"\"v=spf1 -all\""},
 {id:"00000000000000000000000000000003",name:"_dmarc.devantler.tech",type:"TXT",content:"\"v=DMARC1; p=reject\""},
 {id:"00000000000000000000000000000004",name:"sig1._domainkey.devantler.tech",type:"CNAME",content:"sig1.keys.example.test"},
 {id:"00000000000000000000000000000005",name:"devantler.tech",type:"TXT",content:"\"apple-domain=PRIVATE_FIXTURE_DNS\""}
 ]|map({ttl:300,proxied:false,comment:null,tags:[],settings:{}}+.),result_info:{page:1,per_page:1000,count:5,total_count:5,total_pages:1}}' ;;
'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/cloudflare-bootstrap-state')
 [[ $FIXTURE_CASE != bucket-denied ]] || exit 22
 jq -n '{success:true,result:{name:"cloudflare-bootstrap-state",jurisdiction:"default",location:"EEUR",storage_class:"Standard"}}' ;;
*)exit 81 ;;
esac
CURL
cat > "$scratch/bin/tofu" <<'TOFU'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -chdir=* ]]
work=${1#-chdir=};shift
[[ ${CLOUDFLARE_API_TOKEN:-} == AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA && -z ${TF_LOG:-} && -z ${TF_CLI_ARGS_plan:-} && -z ${CLOUDFLARE_API_BASE_URL:-} ]]
printf '%s\n' "$1" >> "$FIXTURE_DIR/cli"
printf '%s\n' PRIVATE_FIXTURE_PROVIDER_OUTPUT >&2
case $1 in
 init)
  [[ $* == 'init -input=false -lockfile=readonly' ]]
  [[ $(cat "$work/backend_override.tf") == $'terraform {\n  backend "local" {}\n}' ]] ;;
 import)
  [[ $# == 4 && $2 == -input=false ]]
  jq -n --arg address "$3" --arg id "$4" '{address:$address,id:$id}' >> "$work/imports.executed.jsonl" ;;
 plan)
  [[ $* == 'plan -input=false -detailed-exitcode -out=migration.tfplan' ]]
  jq -s -e 'length==7' "$work/imports.executed.jsonl" >/dev/null
  printf '%s' PRIVATE_FIXTURE_SAVED_PLAN > "$work/migration.tfplan"
  jq -s --arg scenario "$FIXTURE_CASE" '{
   errored:false,
   resource_changes:[.[]|{address,mode:"managed",type:(if .address=="cloudflare_zone.primary" then "cloudflare_zone" elif (.address|startswith("cloudflare_r2_bucket.")) then "cloudflare_r2_bucket" else "cloudflare_dns_record" end),change:{actions:["no-op"],before:{id:(if .address=="cloudflare_zone.primary" then .id else (.id|split("/")[1]) end)},after:{id:(if .address=="cloudflare_zone.primary" then .id else (.id|split("/")[1]) end)},after_unknown:{}}}]
  }|if $scenario=="plan-update" then .resource_changes[0].change.actions=["update"] else . end' "$work/imports.executed.jsonl" > "$work/fixture-plan.json" ;;
 show)
  [[ $* == 'show -json migration.tfplan' ]]
  cat "$work/fixture-plan.json" ;;
 *)exit 82 ;;
esac
TOFU
chmod +x "$scratch/bin/curl" "$scratch/bin/tofu"
# Exercise real encryption transport around controlled provider and CLI boundaries.
run_case(){
 local name=$1 expected=$2 ref=refs/heads/main confirmation=PLAN_EMAIL_DNS token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA rc=0
 local dir="$scratch/$name"
 mkdir "$dir"; : > "$dir/api"; : > "$dir/cli"
 case $name in
 wrong-ref)ref=refs/heads/feature;;
 wrong-confirmation)confirmation=APPLY;;
 missing-token)token='';;
 esac
 env PATH="$scratch/bin:$PATH" FIXTURE_DIR="$dir" FIXTURE_CASE="$name" \
 GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF="$ref" GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR=devantler GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_ID=12345 GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
 GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/email-dns-proposal.yaml@refs/heads/main RUNNER_ENVIRONMENT=github-hosted \
 CONFIRMATION="$confirmation" CLOUDFLARE_API_TOKEN="$token" TF_LOG=TRACE TF_CLI_ARGS_plan=-destroy CLOUDFLARE_API_BASE_URL=https://untrusted.invalid \
 OUTPUT_DIR="$dir/output" DIAGNOSTICS_DIR="$dir/diagnostics" bash "$root/scripts/plan-email-dns.sh" "$scratch/root" > "$dir/log" 2>&1 || rc=$?
 [[ $rc == "$expected" ]] || { echo "FAIL: Email proposal $name exit=$rc"; cat "$dir/log"; exit 1; }
 if grep -Eq 'AAAAAAAAAAAA|111111111111|222222222222|PRIVATE_FIXTURE_|Authorization:' "$dir/log"; then echo 'FAIL: private proposal detail escaped';exit 1;fi
 if [[ $expected == 0 ]]; then
  [[ $(wc -l < "$dir/api") -eq 3 && $(wc -l < "$dir/cli") -eq 10 ]]
  grep -q '^EMAIL_DNS_PROPOSAL=ENCRYPTED_UNCHANGED provider_writes=0$' "$dir/log"
  [[ $(find "$dir/output" -type f | wc -l) -eq 2 ]]
  age --decrypt -i "$scratch/key" "$dir/output/proposal.tar.gz.age" > "$dir/bundle.tar.gz" 2>/dev/null
  mkdir "$dir/plain";tar -xzf "$dir/bundle.tar.gz" -C "$dir/plain"
  jq -e '.kind=="cloudflare-email-dns-proposal" and .providerWrites==0 and .sourceRun==12345' "$dir/output/manifest.json" >/dev/null
  jq -e '.kind=="cloudflare-email-dns-proposal" and .providerWrites==0' "$dir/plain/metadata.json" >/dev/null
  jq -e '.dns_records|length==5' "$dir/plain/work/production.auto.tfvars.json" >/dev/null
  [[ $(cat "$dir/plain/work/migration.tfplan") == PRIVATE_FIXTURE_SAVED_PLAN ]]
  [[ ! -e "$dir/diagnostics" ]]
 else
  [[ ! -e "$dir/output" ]]
  case $name in wrong-ref|wrong-confirmation|missing-token) [[ ! -s "$dir/api" && ! -s "$dir/cli" ]];;esac
 fi
}
run_case success 0
run_case wrong-ref 2
run_case wrong-confirmation 2
run_case missing-token 2
run_case bucket-denied 2
run_case plan-update 2
printf '%s\n' 'PASS: private native Email DNS proposal lifecycle and refusal controls'

mkdir "$scratch/parse"
workflow="$root/.github/workflows/email-dns-proposal.yaml"
expression=$(jq -nr --arg path "$workflow" '"jsonencode(yamldecode(file(" + ($path|tojson) + ")))"')
printf '%s\n' "$expression" | tofu -chdir="$scratch/parse" console -no-color > "$scratch/workflow.string.json"
jq -r . "$scratch/workflow.string.json" > "$scratch/workflow.json"
# Check declared workflow custody and reject privilege, trigger and export changes.
check_workflow(){
 jq -e '
  .permissions=={contents:"read"} and (.on|keys)==["workflow_dispatch"] and
  (.jobs|keys)==["plan"] and .jobs.plan["runs-on"]=="ubuntu-latest" and .jobs.plan["timeout-minutes"]==12 and
  .concurrency=={group:"cloudflare-bootstrap-migration","cancel-in-progress":false} and
  (.env // {})=={} and (.jobs.plan.env // {})=={} and (.jobs.plan.permissions // {})=={} and
  (.jobs.plan.steps|length)==7 and
  all(.jobs.plan.steps[];(has("continue-on-error")|not)) and
  .jobs.plan.steps[0].env=={CONFIRMATION:"${{ inputs.confirmation }}"} and
  (.jobs.plan.steps[0].run|contains("${{")|not) and
  .jobs.plan.steps[1].with=={ref:"${{ github.sha }}","persist-credentials":false} and
  .jobs.plan.steps[2].with=={tofu_version:"1.12.6",tofu_wrapper:false} and
  .jobs.plan.steps[4].run=="bash scripts/plan-email-dns.sh \"$GITHUB_WORKSPACE\"" and
  .jobs.plan.steps[4].env=={CONFIRMATION:"${{ inputs.confirmation }}",CLOUDFLARE_API_TOKEN:"${{ secrets.CLOUDFLARE_API_TOKEN }}",OUTPUT_DIR:"${{ runner.temp }}/email-dns-proposal",DIAGNOSTICS_DIR:"${{ runner.temp }}/email-dns-diagnostics"} and
  .jobs.plan.steps[5].uses=="actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9" and
  .jobs.plan.steps[5].with.path=="${{ runner.temp }}/email-dns-proposal/proposal.tar.gz.age\n${{ runner.temp }}/email-dns-proposal/manifest.json\n" and
  .jobs.plan.steps[5].with["retention-days"]==1 and
  .jobs.plan.steps[6].with.path=="${{ runner.temp }}/email-dns-diagnostics/diagnostics.tar.gz.age" and
  .jobs.plan.steps[6].with["retention-days"]==1
 ' "$1" >/dev/null
}
check_workflow "$scratch/workflow.json"
jq -r '.jobs.plan.steps[0].run' "$scratch/workflow.json" > "$scratch/guard.sh"
for scenario in accepted wrong-ref wrong-workflow wrong-runner wrong-actor retry wrong-event wrong-confirmation;do
 ref=refs/heads/main workflow_ref=devantler-tech/cloudflare/.github/workflows/email-dns-proposal.yaml@refs/heads/main runner=github-hosted actor=devantler attempt=1 event=workflow_dispatch confirmation=PLAN_EMAIL_DNS
 case $scenario in
 wrong-ref)ref=refs/heads/feature;;
 wrong-workflow)workflow_ref=devantler-tech/cloudflare/.github/workflows/other.yaml@refs/heads/main;;
 wrong-runner)runner=self-hosted;;
 wrong-actor)actor=foreign;;
 retry)attempt=2;;
 wrong-event)event=pull_request;;
 wrong-confirmation)confirmation='PLAN_EMAIL_DNS"; echo unexpected';;
 esac
 rc=0
 env GITHUB_EVENT_NAME="$event" GITHUB_REF="$ref" GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR="$actor" GITHUB_RUN_ATTEMPT="$attempt" GITHUB_WORKFLOW_REF="$workflow_ref" RUNNER_ENVIRONMENT="$runner" CONFIRMATION="$confirmation" bash "$scratch/guard.sh" > "$scratch/guard.log" 2>&1 || rc=$?
 if [[ $scenario == accepted ]];then [[ $rc == 0 ]];else [[ $rc == 2 ]];fi
done
for mutation in '.permissions.contents="write"' '.on.push={}' '.jobs.plan.steps[5].with.path="/tmp"' '.jobs.plan.steps[4].run="tofu apply"' '.jobs.plan.steps[0].env.CLOUDFLARE_API_TOKEN="early"';do
 jq "$mutation" "$scratch/workflow.json" > "$scratch/workflow-mutant.json"
 if check_workflow "$scratch/workflow-mutant.json";then echo 'FAIL: unsafe Email proposal workflow was accepted' >&2;exit 1;fi
done
printf '%s\n' 'PASS: main-only Email proposal workflow guards and ciphertext boundaries'
