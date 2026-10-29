#!/usr/bin/env bash
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
age-keygen -o "$scratch/key" 2>/dev/null
age-keygen -y "$scratch/key" > "$scratch/recipient"
actual_age=$(command -v age)
cat > "$scratch/bin/age" <<'AGE'
#!/usr/bin/env bash
set -euo pipefail
if [[ $FIXTURE_CASE == encryption-failed && " $* " == *'/inventory.age '* ]]; then
  exit 1
fi
exec "$FIXTURE_AGE" "$@"
AGE
chmod +x "$scratch/bin/age"
cat > "$scratch/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${CLOUDFLARE_API_TOKEN:-} && $1 == --disable ]]
url='' jurisdiction=default
while [[ $# -gt 0 ]]; do
  case $1 in
    --disable|--silent|--fail) shift ;;
    --config) [[ $2 == - ]]; shift 2 ;;
    --request) [[ $2 == GET ]]; shift 2 ;;
    --proto) [[ $2 == '=https' ]]; shift 2 ;;
    --noproxy) [[ $2 == '*' ]]; shift 2 ;;
    --max-redirs) [[ $2 == 0 ]]; shift 2 ;;
    --connect-timeout|--max-time|--max-filesize) shift 2 ;;
    --header) jurisdiction=${2#cf-r2-jurisdiction: }; shift 2 ;;
    --url) url=$2; shift 2 ;;
    *) exit 81 ;;
  esac
done
IFS= read -r header
[[ $header == 'header = "Authorization: Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' ]]
printf '%s %s\n' "$jurisdiction" "$url" >> "$FIXTURE_DIR/calls"
case "$url" in
  'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50')
    jq -n '{success:true,result:[{id:"11111111111111111111111111111111",name:"devantler.tech",status:"active",account:{id:"22222222222222222222222222222222"}}],result_info:{total_count:1,total_pages:1}}' ;;
  'https://api.cloudflare.com/client/v4/zones/11111111111111111111111111111111/dns_records?per_page=1000&page=1')
    jq -n '{success:true,result:[{id:"33333333333333333333333333333333",name:"devantler.tech",type:"TXT",content:"PRIVATE_FIXTURE_DNS"}],result_info:{page:1,per_page:1000,count:1,total_count:1,total_pages:1}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/tokens/verify')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:{id:"44444444444444444444444444444444",status:(if $scenario=="token-inactive" then "disabled" else "active" end)}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/tokens/44444444444444444444444444444444')
    [[ $FIXTURE_CASE != policy-denied ]] || exit 22
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:{id:(if $scenario=="token-mismatch" then "55555555555555555555555555555555" else "44444444444444444444444444444444" end),name:"PRIVATE_FIXTURE_TOKEN",status:"active",policies:[{id:"55555555555555555555555555555555",effect:"allow",permission_groups:[{id:"66666666666666666666666666666666",name:"PRIVATE_FIXTURE_PERMISSION"}],resources:{"com.cloudflare.api.account.*":"*"}}]}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/tokens?per_page=50&page=1&include_expired=true')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:([{id:"44444444444444444444444444444444",name:"PRIVATE_FIXTURE_TOKEN",status:"active"}]+(if $scenario=="multi-page" or $scenario=="token-drift-total" then [range(1;50)|{id:(("00000000000000000000000000000000"+(.|tostring))[-32:]),name:"PRIVATE_FIXTURE_TOKEN",status:"active"}] elif $scenario=="token-duplicate" then [{id:"44444444444444444444444444444444",name:"PRIVATE_FIXTURE_TOKEN",status:"active"}] else [] end)),result_info:{page:1,per_page:50,count:(if $scenario=="multi-page" or $scenario=="token-drift-total" then 50 elif $scenario=="token-duplicate" then 2 else 1 end),total_count:(if $scenario=="multi-page" or $scenario=="token-drift-total" then 51 elif $scenario=="token-short-page" or $scenario=="token-duplicate" then 2 else 1 end)}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/tokens?per_page=50&page=2&include_expired=true')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:[{id:"77777777777777777777777777777777",name:"PRIVATE_FIXTURE_LAST_TOKEN",status:"disabled"}],result_info:{page:2,per_page:50,count:1,total_count:(if $scenario=="token-drift-total" then 52 else 51 end)}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets?per_page=1000')
    jq -n --arg jurisdiction "$jurisdiction" --arg scenario "$FIXTURE_CASE" '{success:true,result:{buckets:(if $jurisdiction=="default" then [{name:"fixture-bucket",jurisdiction:(if $scenario=="bucket-wrong-jurisdiction" then "eu" else "default" end),location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}] else [] end)},result_info:{total_count:(if $jurisdiction=="default" then (if $scenario=="multi-page" then 2 else 1 end) else 0 end),per_page:1000,cursor:(if $scenario=="cursor-loop" then "repeated" elif $scenario=="multi-page" and $jurisdiction=="default" then "second" else null end)}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets?per_page=1000&cursor=repeated')
    jq -n '{success:true,result:{buckets:[]},result_info:{total_count:1,per_page:1000,cursor:"repeated"}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets?per_page=1000&cursor=second')
    jq -n '{success:true,result:{buckets:[{name:"fixture-bucket-two",jurisdiction:"default",location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}]},result_info:{total_count:2,per_page:1000,cursor:null}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket-two')
    jq -n '{success:true,result:{name:"fixture-bucket-two",jurisdiction:"default",location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket-two/lifecycle')
    jq -n '{success:true,result:{rules:[]}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:{name:(if $scenario=="bucket-mismatch" then "other-bucket" else "fixture-bucket" end),jurisdiction:"default",location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket/lifecycle')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:{rules:(if $scenario=="bad-lifecycle" then null else [{id:"fixture-expiry",enabled:true,conditions:{prefix:"PRIVATE_FIXTURE_PREFIX"}}] end)}}' ;;
  *) exit 82 ;;
esac
if [[ $FIXTURE_CASE == double-document && $url == */tokens/44444444444444444444444444444444 ]]; then
  printf '%s\n' '{"success":true,"result":{}}'
fi
STUB
chmod +x "$scratch/bin/curl"

# Exercise encrypted output and closed failures without real provider access.
run_case() {
  local scenario=$1 expected=$2 rc=0 ref=refs/heads/main actor=devantler attempt=1 confirmation=EXPORT_BOOTSTRAP_INVENTORY
  local case_dir="$scratch/$scenario"
  mkdir "$case_dir"
  cp "$scratch/recipient" "$case_dir/recipient"
  : > "$case_dir/calls"
  case "$scenario" in
    wrong-ref) ref=refs/heads/other ;;
    wrong-actor) actor=other ;;
    rerun) attempt=2 ;;
    disabled) confirmation='' ;;
    extra-recipient) printf 'unterminated' >> "$case_dir/recipient" ;;
    existing-output) mkdir "$case_dir/out" ;;
  esac
  env PATH="$scratch/bin:$PATH" FIXTURE_DIR="$case_dir" FIXTURE_CASE="$scenario" FIXTURE_AGE="$actual_age" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR="$actor" GITHUB_REF="$ref" \
    GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_RUN_ATTEMPT="$attempt" CONFIRMATION="$confirmation" \
    CLOUDFLARE_API_TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
    RECIPIENT_FILE="$case_dir/recipient" OUTPUT_DIR="$case_dir/out" \
    bash "$repo_root/scripts/export-bootstrap-inventory.sh" > "$case_dir/log" 2>&1 || rc=$?
  [[ $rc == "$expected" ]] || { printf 'FAIL %s: exit %s\n' "$scenario" "$rc"; exit 1; }
  if grep -Eq 'AAAAAAAAAAAA|111111111111|222222222222|PRIVATE_FIXTURE_|Authorization:' "$case_dir/log"; then
    printf 'FAIL %s: private log material\n' "$scenario"; exit 1
  fi
  if [[ "$expected" == 0 ]]; then
    grep -qx 'BOOTSTRAP_INVENTORY=ENCRYPTED_READS' "$case_dir/log"
    [[ $(find "$case_dir/out" -type f | wc -l) -eq 2 ]]
    age --decrypt -i "$scratch/key" "$case_dir/out/bootstrap-inventory.json.age" 2>/dev/null |
      jq -e --arg scenario "$scenario" '.schema == 1 and .source_revision == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .account_id == "22222222222222222222222222222222" and .token_inventory.coverage == "credential-visible-only" and (.buckets|length)==(if $scenario=="multi-page" then 2 else 1 end) and (.token_inventory.tokens|length)==(if $scenario=="multi-page" then 51 else 1 end) and any(.buckets[];.metadata.name=="fixture-bucket" and .lifecycle.rules[0].conditions.prefix=="PRIVATE_FIXTURE_PREFIX")' >/dev/null
    age --decrypt -i "$scratch/key" "$case_dir/out/dns-snapshot.json.age" 2>/dev/null |
      jq -e '.records[0].content == "PRIVATE_FIXTURE_DNS"' >/dev/null
    if grep -Rq PRIVATE_FIXTURE_ "$case_dir/out"; then echo 'FAIL: plaintext artifact'; exit 1; fi
  else
    grep -qx 'BOOTSTRAP_INVENTORY=UNVERIFIED' "$case_dir/log"
    [[ ! -e "$case_dir/out" || $scenario == existing-output ]]
  fi
  case "$scenario" in
    wrong-ref|wrong-actor|rerun|disabled|extra-recipient|existing-output) [[ ! -s "$case_dir/calls" ]] ;;
  esac
}
run_case valid 0
run_case multi-page 0
for scenario in wrong-ref wrong-actor rerun disabled extra-recipient existing-output policy-denied token-mismatch token-inactive token-short-page token-drift-total token-duplicate cursor-loop bucket-mismatch bucket-wrong-jurisdiction bad-lifecycle double-document encryption-failed; do
  run_case "$scenario" 2
done
printf '%s\n' 'PASS: bounded bootstrap inventory and ciphertext-only refusals'
