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
url='' jurisdiction=default output='' write_out=''
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
    --output) output=$2; shift 2 ;;
    --write-out) [[ $2 == '%{http_code}' ]]; write_out=$2; shift 2 ;;
    --url) url=$2; shift 2 ;;
    *) exit 81 ;;
  esac
done
IFS= read -r header
[[ $header == 'header = "Authorization: Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' ]]
printf '%s %s\n' "$jurisdiction" "$url" >> "$FIXTURE_DIR/calls"
if [[ -n $output ]]; then
  [[ -n $write_out ]]
  exec 3>&1
  exec > "$output"
fi
if [[ $url == */r2/buckets\?* && $FIXTURE_CASE == bucket-http-denied ]]; then
  printf '%s\n' '{"success":false,"errors":[{"message":"PRIVATE_FIXTURE_PROVIDER_ERROR"}]}'
  [[ -z $output ]] || printf '403' >&3
  exit 22
fi
if [[ $url == */r2/buckets\?* && $FIXTURE_CASE == bucket-transport-failure ]]; then
  [[ -z $output ]] || printf '000' >&3
  exit 7
fi
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
    jq -n --arg jurisdiction "$jurisdiction" --arg scenario "$FIXTURE_CASE" '{success:true,result:{buckets:(if $jurisdiction=="default" then [{name:"fixture-bucket",jurisdiction:(if $scenario=="bucket-wrong-jurisdiction" then "eu" else "default" end),location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}] else [] end)},result_info:{total_count:(if $jurisdiction=="default" then (if $scenario=="multi-page" then 2 else 1 end) else 0 end),per_page:1000,cursor:(if $scenario=="cursor-loop" then "repeated" elif $scenario=="multi-page" and $jurisdiction=="default" then "second" else null end)}} |
      if $scenario=="multi-page" then .result_info.per_page=1
      elif $scenario=="bucket-clamped-page-size" then .result_info.per_page=(if $jurisdiction=="default" then 20 else 0 end)
      else . end |
      if $scenario=="bucket-missing-total" then del(.result_info.total_count)
      elif $scenario=="bucket-optional-metadata" then .result.buckets|=map(del(.jurisdiction,.location,.storage_class))
      elif $scenario=="bucket-null-metadata" then .result.buckets|=map(.jurisdiction=null|.location=null|.storage_class=null)
      elif $scenario=="bucket-location-type" then .result.buckets[0].location=123
      elif $scenario=="bucket-storage-class-invalid" then .result.buckets[0].storage_class="unsupported"
      elif $scenario=="bucket-missing-page-size" then del(.result_info.per_page)
      elif $scenario=="bucket-null-page-size" then .result_info.per_page=null
      elif $scenario=="bucket-page-size-type" then .result_info.per_page="20"
      elif $scenario=="bucket-page-size-negative" then .result_info.per_page = -1
      elif $scenario=="bucket-page-size-fraction" then .result_info.per_page=1.5
      elif $scenario=="bucket-page-size-overflow" then .result_info.per_page=1001
      elif $scenario=="bucket-page-size-short" then .result_info.per_page=0
      elif $scenario=="bucket-short-page" then .result_info.total_count=2 | .result_info.per_page=1
      elif $scenario=="bucket-drift-total" or $scenario=="bucket-duplicate" then .result_info.total_count=2 | .result_info.per_page=1 | .result_info.cursor="second"
      elif $scenario=="bucket-result-overflow" then .result_info.total_count=100 | .result.buckets=[range(0;101)|{name:("fixture-bucket-"+tostring),jurisdiction:"default",location:"weur",storage_class:"Standard"}]
      elif $scenario=="bucket-total-overflow" then .result_info.total_count=101
      elif ($scenario=="many-pages" or $scenario=="hundred-pages" or $scenario=="page-budget") and $jurisdiction=="default" then
        .result_info.total_count=(if $scenario=="many-pages" then 11 elif $scenario=="hundred-pages" then 100 else 1 end) |
        .result_info.per_page=1 | .result_info.cursor="page2"
      elif $scenario=="bucket-malformed-envelope" then .success=false | .errors=[{message:"PRIVATE_FIXTURE_PROVIDER_ERROR"}]
      else . end' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets?per_page=1000&cursor=repeated')
    jq -n '{success:true,result:{buckets:[]},result_info:{total_count:1,per_page:1000,cursor:"repeated"}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets?per_page=1000&cursor=second')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:{buckets:[{name:(if $scenario=="bucket-duplicate" then "fixture-bucket" else "fixture-bucket-two" end),jurisdiction:"default",location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}]},result_info:{total_count:(if $scenario=="bucket-drift-total" then 3 else 2 end),per_page:1,cursor:null}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets?per_page=1000&cursor=page'*)
    page=${url##*cursor=page}
    [[ $page =~ ^[0-9]+$ && $page -ge 2 && $page -le 100 ]]
    jq -n --arg scenario "$FIXTURE_CASE" --argjson page "$page" '
      (if $scenario=="many-pages" then 11 elif $scenario=="hundred-pages" then 100 else 1 end) as $total |
      {success:true,result:{buckets:(if $scenario=="page-budget" then [] else [{name:("fixture-page-"+($page|tostring)),jurisdiction:"default",location:"weur",storage_class:"Standard"}] end)},
        result_info:{total_count:$total,per_page:1,cursor:(if $scenario=="page-budget" or $page<$total then "page"+(($page+1)|tostring) else null end)}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-page-'*'/lifecycle')
    jq -n '{success:true,result:{rules:[]}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-page-'*)
    bucket=${url##*/}
    [[ $bucket =~ ^fixture-page-[0-9]+$ ]]
    jq -n --arg name "$bucket" '{success:true,result:{name:$name,jurisdiction:"default",location:"weur",storage_class:"Standard"}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket-two')
    jq -n '{success:true,result:{name:"fixture-bucket-two",jurisdiction:"default",location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket-two/lifecycle')
    jq -n '{success:true,result:{rules:[]}}' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:{name:(if $scenario=="bucket-mismatch" then "other-bucket" else "fixture-bucket" end),jurisdiction:"default",location:"weur",storage_class:"Standard",creation_date:"2026-10-29T00:00:00Z"}} |
      if $scenario=="bucket-optional-metadata" or $scenario=="bucket-detail-optional" then del(.result.jurisdiction,.result.location,.result.storage_class)
      elif $scenario=="bucket-null-metadata" then .result.jurisdiction=null | .result.location=null | .result.storage_class=null
      elif $scenario=="metadata-wrong-jurisdiction" then .result.jurisdiction="eu"
      elif $scenario=="metadata-location-type" then .result.location=123
      elif $scenario=="metadata-storage-class-invalid" then .result.storage_class="unsupported"
      else . end' ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/r2/buckets/fixture-bucket/lifecycle')
    jq -n --arg scenario "$FIXTURE_CASE" '{success:true,result:{rules:(if $scenario=="bad-lifecycle" then null else [{id:"fixture-expiry",enabled:true,conditions:{prefix:"PRIVATE_FIXTURE_PREFIX"}}] end)}} |
      if $scenario=="lifecycle-absent-rules" then del(.result.rules)
      elif $scenario=="lifecycle-null-result" then .result=null
      elif $scenario=="lifecycle-invalid-rule" then .result.rules=["PRIVATE_FIXTURE_INVALID_RULE"]
      elif $scenario=="lifecycle-missing-prefix" then del(.result.rules[0].conditions.prefix)
      elif $scenario=="lifecycle-null-prefix" then .result.rules[0].conditions.prefix=null
      elif $scenario=="lifecycle-numeric-prefix" then .result.rules[0].conditions.prefix=123
      elif $scenario=="lifecycle-missing-conditions" then del(.result.rules[0].conditions)
      else . end' ;;
  *) exit 82 ;;
esac
if [[ $FIXTURE_CASE == double-document && $url == */tokens/44444444444444444444444444444444 ]]; then
  printf '%s\n' '{"success":true,"result":{}}'
fi
if [[ -n $output ]]; then
  if [[ $url == */r2/buckets\?* && $FIXTURE_CASE == bucket-status-private ]]; then
    printf 'PRIVATE_FIXTURE_STATUS' >&3
  else
    printf '200' >&3
  fi
fi
STUB
chmod +x "$scratch/bin/curl"

# Exercise encrypted output and closed failures without real provider access.
run_case() {
  local scenario=$1 expected=$2 rc=0 ref=refs/heads/main actor=devantler attempt=1 confirmation=EXPORT_BOOTSTRAP_INVENTORY credential=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
    absent-token) credential='' ;;
    invalid-token) credential=$'AAAAAAAAAAAAAAAAAAAA\nheader="injected"' ;;
  esac
  env PATH="$scratch/bin:$PATH" FIXTURE_DIR="$case_dir" FIXTURE_CASE="$scenario" FIXTURE_AGE="$actual_age" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR="$actor" GITHUB_REF="$ref" \
    GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_RUN_ATTEMPT="$attempt" CONFIRMATION="$confirmation" \
    CLOUDFLARE_API_TOKEN="$credential" \
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
      jq -e --arg scenario "$scenario" '.schema == 1 and .source_revision == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .account_id == "22222222222222222222222222222222" and .token_inventory.coverage == "credential-visible-only" and (.buckets|length)==(if $scenario=="multi-page" then 2 elif $scenario=="many-pages" then 11 elif $scenario=="hundred-pages" then 100 else 1 end) and (.token_inventory.tokens|length)==(if $scenario=="multi-page" then 51 else 1 end) and any(.buckets[];.metadata.name=="fixture-bucket" and (if $scenario=="lifecycle-absent-rules" then .lifecycle=={} elif $scenario=="lifecycle-missing-prefix" then .lifecycle.rules[0].conditions=={} else .lifecycle.rules[0].conditions.prefix=="PRIVATE_FIXTURE_PREFIX" end))' >/dev/null
    age --decrypt -i "$scratch/key" "$case_dir/out/dns-snapshot.json.age" 2>/dev/null |
      jq -e '.records[0].content == "PRIVATE_FIXTURE_DNS"' >/dev/null
    if [[ $scenario == bucket-optional-metadata ]]; then
      age --decrypt -i "$scratch/key" "$case_dir/out/bootstrap-inventory.json.age" 2>/dev/null |
        jq -e 'all(.buckets[]; .requested_jurisdiction=="default" and
          (.metadata|has("jurisdiction")|not) and (.metadata|has("location")|not) and
          (.metadata|has("storage_class")|not))' >/dev/null
    fi
    if [[ $scenario == bucket-detail-optional ]]; then
      age --decrypt -i "$scratch/key" "$case_dir/out/bootstrap-inventory.json.age" 2>/dev/null |
        jq -e '.buckets[0] | .requested_jurisdiction=="default" and
          .list_observation.name=="fixture-bucket" and .list_observation.jurisdiction=="default" and
          .list_observation.location=="weur" and .list_observation.storage_class=="Standard" and
          (.metadata|has("jurisdiction")|not) and (.metadata|has("location")|not) and
          (.metadata|has("storage_class")|not)' >/dev/null || { printf 'FAIL %s: list metadata was not retained\n' "$scenario"; exit 1; }
    fi
    if grep -Rq PRIVATE_FIXTURE_ "$case_dir/out"; then echo 'FAIL: plaintext artifact'; exit 1; fi
  else
    grep -qx 'BOOTSTRAP_INVENTORY=UNVERIFIED' "$case_dir/log"
    [[ ! -e "$case_dir/out" || $scenario == existing-output ]]
  fi
  local expected_reason='' expected_http=''
  case "$scenario" in
    page-budget) grep -q 'cursor=page100$' "$case_dir/calls"; ! grep -q 'cursor=page101' "$case_dir/calls" ;;
    lifecycle-null-result) expected_reason=lifecycle-object; expected_http=200 ;;
    bad-lifecycle) expected_reason=lifecycle-rules; expected_http=200 ;;
    lifecycle-invalid-rule) expected_reason=lifecycle-rule; expected_http=200 ;;
    lifecycle-null-prefix|lifecycle-numeric-prefix) expected_reason=lifecycle-rule-prefix; expected_http=200 ;;
    lifecycle-missing-conditions) expected_reason=lifecycle-rule-conditions; expected_http=200 ;;
    bucket-http-denied) expected_reason=provider-http; expected_http=403 ;;
    bucket-malformed-envelope) expected_reason=provider-envelope; expected_http=200 ;;
    bucket-missing-total) expected_reason=bucket-total; expected_http=200 ;;
    bucket-page-size-type|bucket-page-size-negative|bucket-page-size-fraction|bucket-page-size-overflow|bucket-page-size-short) expected_reason=bucket-page-size; expected_http=200 ;;
    bucket-result-overflow) expected_reason=bucket-result-bound; expected_http=200 ;;
    bucket-status-private) expected_reason=provider-status; expected_http=none ;;
    bucket-transport-failure) expected_reason=provider-transport; expected_http=none ;;
  esac
  if [[ -n $expected_reason ]]; then
    if ! grep -qx "INVENTORY_FAILURE=$expected_reason" "$case_dir/log" ||
      ! grep -qx "INVENTORY_HTTP_STATUS=$expected_http" "$case_dir/log"; then
      printf 'FAIL %s: missing safe failure reason or HTTP status\n' "$scenario"
      exit 1
    fi
  fi
  case "$scenario" in
    wrong-ref|wrong-actor|rerun|disabled|extra-recipient|existing-output|absent-token|invalid-token) [[ ! -s "$case_dir/calls" ]] ;;
  esac
}
run_case valid 0
run_case lifecycle-absent-rules 0
run_case lifecycle-missing-prefix 0
run_case multi-page 0
run_case bucket-clamped-page-size 0
run_case bucket-missing-page-size 0
run_case bucket-null-page-size 0
run_case bucket-optional-metadata 0
run_case bucket-null-metadata 0
run_case many-pages 0
run_case hundred-pages 0
run_case bucket-detail-optional 0
for scenario in wrong-ref wrong-actor rerun disabled extra-recipient existing-output absent-token invalid-token policy-denied token-mismatch token-inactive token-short-page token-drift-total token-duplicate cursor-loop bucket-mismatch bucket-wrong-jurisdiction bucket-location-type bucket-storage-class-invalid metadata-wrong-jurisdiction metadata-location-type metadata-storage-class-invalid bucket-http-denied bucket-malformed-envelope bucket-missing-total bucket-status-private bucket-transport-failure bucket-page-size-type bucket-page-size-negative bucket-page-size-fraction bucket-page-size-overflow bucket-page-size-short bucket-short-page bucket-drift-total bucket-duplicate bucket-result-overflow bucket-total-overflow bad-lifecycle double-document encryption-failed; do
  run_case "$scenario" 2
done
run_case page-budget 2
for scenario in lifecycle-null-result lifecycle-invalid-rule lifecycle-null-prefix lifecycle-numeric-prefix lifecycle-missing-conditions; do
  run_case "$scenario" 2
done
printf '%s\n' 'PASS: bounded bootstrap inventory and ciphertext-only refusals'
