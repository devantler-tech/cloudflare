#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/parse"
age-keygen -o "$scratch/key" 2>/dev/null
age-keygen -y "$scratch/key" > "$scratch/recipient"
token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

cat > "$scratch/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${CLOUDFLARE_API_TOKEN:-} ]] || exit 80
[[ $1 == --disable ]] || exit 81
url=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --disable|--silent|--fail) shift ;;
    --config) [[ $2 == - ]] || exit 82; shift 2 ;;
    --request) [[ $2 == GET ]] || exit 83; shift 2 ;;
    --proto) [[ $2 == '=https' ]] || exit 84; shift 2 ;;
    --noproxy) [[ $2 == '*' ]] || exit 85; shift 2 ;;
    --max-redirs) [[ $2 == 0 ]] || exit 86; shift 2 ;;
    --connect-timeout|--max-time|--max-filesize) shift 2 ;;
    --url) url=$2; shift 2 ;;
    *) exit 87 ;;
  esac
done
IFS= read -r header
[[ $header == 'header = "Authorization: Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' ]] || exit 88
printf '%s\n' "$url" >> "$FIXTURE_DIR/calls"
case $url in
  'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50') cat "$FIXTURE_DIR/zone.json" ;;
  'https://api.cloudflare.com/client/v4/zones/11111111111111111111111111111111/dns_records?per_page=1000&page=1') cat "$FIXTURE_DIR/page1.json" ;;
  'https://api.cloudflare.com/client/v4/zones/11111111111111111111111111111111/dns_records?per_page=1000&page=2') cat "$FIXTURE_DIR/page2.json" ;;
  *) exit 89 ;;
esac
[[ $FIXTURE_CASE != http-error ]]
STUB
chmod +x "$scratch/bin/curl"

run_case() {
  local scenario=$1 expected=$2 calls=$3 rc=0
  local ref=refs/heads/main confirmation=EXPORT_ENCRYPTED_DNS event=workflow_dispatch actor=devantler credential=$token
  local case_dir="$scratch/$scenario"
  mkdir "$case_dir"
  cp "$scratch/recipient" "$case_dir/recipient"
  : > "$case_dir/calls"
  jq -n '{success:true,result:[{id:"11111111111111111111111111111111",name:"devantler.tech",status:"active",account:{id:"22222222222222222222222222222222"}}],result_info:{total_count:1,total_pages:1}}' > "$case_dir/zone.json"
  jq -n '{success:true,result:[range(1;1001)|{id:(("00000000000000000000000000000000"+(.|tostring))[-32:]),name:"devantler.tech",type:"TXT",content:("PRIVATE_FIXTURE_"+(.|tostring)),extra:{preserve:true}}],result_info:{page:1,per_page:1000,count:1000,total_count:1001,total_pages:2}}' > "$case_dir/page1.json"
  jq -n '{success:true,result:[{id:"ffffffffffffffffffffffffffffffff",name:"mail.devantler.tech",type:"TXT",content:"PRIVATE_FIXTURE_LAST",extra:{preserve:true}}],result_info:{page:2,per_page:1000,count:1,total_count:1001,total_pages:2}}' > "$case_dir/page2.json"
  case $scenario in
    wrong-ref) ref=refs/heads/unreviewed ;;
    wrong-event) event=pull_request ;;
    wrong-actor) actor=other-user ;;
    disabled) confirmation='' ;;
    invalid-confirmation) confirmation='EXPORT_ENCRYPTED_DNS"; exit 0; #' ;;
    absent-token) credential='' ;;
    invalid-token) credential=$'AAAAAAAAAAAAAAAAAAAA\nheader="injected"' ;;
    invalid-recipient) printf '%s\n' age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq > "$case_dir/recipient" ;;
    existing-output) mkdir "$case_dir/out" ;;
    invalid-json) printf 'not JSON' > "$case_dir/zone.json" ;;
    ambiguous-zone) jq '.result += .result' "$case_dir/zone.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/zone.json" ;;
    invalid-zone-id) jq '.result[0].id="../other"' "$case_dir/zone.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/zone.json" ;;
    zero-records) jq '.result=[]|.result_info.count=0|.result_info.total_count=0' "$case_dir/page1.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page1.json" ;;
    short-page) jq 'del(.result[0])' "$case_dir/page1.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page1.json" ;;
    wrong-page) jq '.result_info.page=1' "$case_dir/page2.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page2.json" ;;
    drift-total) jq '.result_info.total_count=1002' "$case_dir/page2.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page2.json" ;;
    duplicate) jq '.result[0].id="00000000000000000000000000000001"' "$case_dir/page2.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page2.json" ;;
    foreign-name) jq '.result[0].name="notdevantler.tech"' "$case_dir/page2.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page2.json" ;;
    invalid-record-id) jq '.result[0].id="../other"' "$case_dir/page2.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page2.json" ;;
    provider-error) jq '.success=false' "$case_dir/page2.json" > "$case_dir/mutant"; mv "$case_dir/mutant" "$case_dir/page2.json" ;;
  esac
  set -- bash "$repo_root/scripts/export-dns-snapshot.sh"
  [[ $scenario != inherited-trace ]] || set -- bash -x "$repo_root/scripts/export-dns-snapshot.sh"
  env PATH="$scratch/bin:$PATH" FIXTURE_DIR="$case_dir" FIXTURE_CASE="$scenario" \
    GITHUB_EVENT_NAME="$event" GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR="$actor" GITHUB_REF="$ref" \
    GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_RUN_ATTEMPT=1 \
    CONFIRMATION="$confirmation" CLOUDFLARE_API_TOKEN="$credential" \
    RECIPIENT_FILE="$case_dir/recipient" OUTPUT_DIR="$case_dir/out" "$@" > "$case_dir/log" 2>&1 || rc=$?
  [[ $rc == "$expected" ]] || { printf 'FAIL %s: exit %s\n' "$scenario" "$rc"; exit 1; }
  [[ $(wc -l < "$case_dir/calls" | tr -d ' ') == "$calls" ]] || { printf 'FAIL %s: request count\n' "$scenario"; exit 1; }
  if grep -Eq 'AAAAAAAAAAAA|111111111111|222222222222|PRIVATE_FIXTURE_|Authorization:' "$case_dir/log"; then
    printf 'FAIL %s: private log material\n' "$scenario"; exit 1
  fi
  if [[ $expected == 0 ]]; then
    [[ $(find "$case_dir/out" -type f | wc -l | tr -d ' ') == 1 ]]
    if grep -q PRIVATE_FIXTURE_ "$case_dir/out/dns-snapshot.json.age"; then echo 'FAIL: plaintext export'; exit 1; fi
    age -d -i "$scratch/key" "$case_dir/out/dns-snapshot.json.age" > "$case_dir/decrypted.json"
    jq -e --slurpfile first "$case_dir/page1.json" --slurpfile last "$case_dir/page2.json" '
      .schema == 1 and .source_revision == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      and .records == ($first[0].result+$last[0].result)
    ' "$case_dir/decrypted.json" >/dev/null
  else
    [[ ! -e "$case_dir/out/dns-snapshot.json.age" ]]
  fi
}

run_case success 0 3
run_case inherited-trace 0 3
for scenario in wrong-ref wrong-event wrong-actor disabled invalid-confirmation absent-token invalid-token invalid-recipient existing-output; do run_case "$scenario" 2 0; done
for scenario in http-error invalid-json ambiguous-zone invalid-zone-id; do run_case "$scenario" 2 1; done
for scenario in zero-records short-page; do run_case "$scenario" 2 2; done
for scenario in wrong-page drift-total duplicate foreign-name invalid-record-id provider-error; do run_case "$scenario" 2 3; done
printf '%s\n' 'PASS: complete private DNS snapshots and rejected unsafe reads'

workflow="$repo_root/.github/workflows/dns-snapshot.yaml"
expression=$(jq -nr --arg path "$workflow" '"jsonencode(yamldecode(file(" + ($path|tojson) + ")))"')
printf '%s\n' "$expression" | tofu -chdir="$scratch/parse" console -no-color > "$scratch/workflow-string.json"
jq -r . "$scratch/workflow-string.json" > "$scratch/workflow.json"
check_workflow() {
  jq -e '
    .permissions == {contents:"read"} and (.on|keys) == ["workflow_dispatch"]
    and (.jobs|keys) == ["snapshot"]
    and .concurrency == {group:"encrypted-dns-snapshot", "cancel-in-progress":false}
    and .jobs.snapshot["runs-on"] == "ubuntu-latest" and .jobs.snapshot["timeout-minutes"] == 8
    and (.env // {}) == {} and (.jobs.snapshot.env // {}) == {}
    and (.jobs.snapshot.permissions // {}) == {}
    and (.jobs.snapshot.steps|length) == 5
    and all(.jobs.snapshot.steps[]; (has("if")|not) and (has("continue-on-error")|not))
    and .jobs.snapshot.steps[0].env == {CONFIRMATION:"${{ inputs.confirmation }}"}
    and (.jobs.snapshot.steps[0].run|contains("${{")|not)
    and .jobs.snapshot.steps[1].uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    and .jobs.snapshot.steps[1].with == {ref:"${{ github.sha }}","persist-credentials":false}
    and (.jobs.snapshot.steps[1].env // {}) == {}
    and (.jobs.snapshot.steps[2].env // {}) == {}
    and (.jobs.snapshot.steps[2].run|contains("cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"))
    and .jobs.snapshot.steps[3].run == "bash scripts/export-dns-snapshot.sh"
    and .jobs.snapshot.steps[3].env == {CONFIRMATION:"${{ inputs.confirmation }}",CLOUDFLARE_API_TOKEN:"${{ secrets.CLOUDFLARE_API_TOKEN }}",RECIPIENT_FILE:".github/dns-recovery-recipient.txt",OUTPUT_DIR:"${{ runner.temp }}/cloudflare-export"}
    and .jobs.snapshot.steps[4].uses == "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"
    and .jobs.snapshot.steps[4].with == {name:"encrypted-dns-snapshot",path:"${{ runner.temp }}/cloudflare-export/dns-snapshot.json.age","if-no-files-found":"error","retention-days":1,"compression-level":0,overwrite:false,"include-hidden-files":false}
    and (.jobs.snapshot.steps[4].env // {}) == {}
  ' "$1" >/dev/null
}
check_workflow "$scratch/workflow.json"
jq -r '.jobs.snapshot.steps[0].run' "$scratch/workflow.json" > "$scratch/guard.sh"
env GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR=devantler GITHUB_RUN_ATTEMPT=1 CONFIRMATION=EXPORT_ENCRYPTED_DNS bash "$scratch/guard.sh"
for mutation in '.permissions.contents="write"' '.on.push={}' '.jobs.snapshot.steps|=.[1:]' '.jobs.snapshot.steps[0].env.CLOUDFLARE_API_TOKEN="early"' '.jobs.snapshot.steps[4].with.path="/tmp"' '.jobs.snapshot.steps[4].with["retention-days"]=90'; do
  jq "$mutation" "$scratch/workflow.json" > "$scratch/mutant.json"
  if check_workflow "$scratch/mutant.json"; then echo 'FAIL: unsafe export workflow'; exit 1; fi
done
for scenario in wrong-ref wrong-actor retry wrong-event disabled; do
  ref=refs/heads/main actor=devantler attempt=1 event=workflow_dispatch confirmation=EXPORT_ENCRYPTED_DNS
  case $scenario in
    wrong-ref) ref=refs/heads/unreviewed ;;
    wrong-actor) actor=other-user ;;
    retry) attempt=2 ;;
    wrong-event) event=pull_request ;;
    disabled) confirmation='' ;;
  esac
  if env GITHUB_EVENT_NAME="$event" GITHUB_REF="$ref" GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR="$actor" GITHUB_RUN_ATTEMPT="$attempt" CONFIRMATION="$confirmation" bash "$scratch/guard.sh" >/dev/null 2>&1; then echo "FAIL: inline guard $scenario"; exit 1; fi
done
printf '%s\n' 'PASS: encrypted export workflow boundaries'
