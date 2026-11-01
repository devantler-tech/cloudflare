#!/usr/bin/env bash
# Observe provider configuration; this is never adoption or write clearance.
set +x
set -euo pipefail
umask 077
scratch='' output_created=false stage=dispatch failure=validation http_status=none
# Remove private scratch and refuse partial exports while reporting safe diagnostics.
cleanup() {
  local rc=$?
  [[ -z "$scratch" ]] || rm -rf "$scratch"
  if [[ $rc != 0 ]]; then
    if [[ $output_created == true ]]; then
      rm -f "$OUTPUT_DIR/dns-snapshot.json.age" "$OUTPUT_DIR/bootstrap-inventory.json.age"
      rmdir "$OUTPUT_DIR" 2>/dev/null || true
    fi
    printf '%s\n' 'BOOTSTRAP_INVENTORY=UNVERIFIED' 'MIGRATION_READINESS=UNVERIFIED' >&2
    printf 'INVENTORY_STAGE=%s\n' "$stage" >&2
    printf 'INVENTORY_FAILURE=%s\n' "$failure" >&2
    printf 'INVENTORY_HTTP_STATUS=%s\n' "$http_status" >&2
    exit 2
  fi
}
trap cleanup EXIT
stop() { exit 2; }
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main &&
  ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_ACTOR:-} == devantler &&
  ${GITHUB_RUN_ATTEMPT:-} == 1 && ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ &&
  ${CONFIRMATION:-} == EXPORT_BOOTSTRAP_INVENTORY ]] || stop
stage=recipient
[[ -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR &&
  -f ${RECIPIENT_FILE:-} && ! -L $RECIPIENT_FILE ]] || stop
IFS= read -r recipient < "$RECIPIENT_FILE" || stop
[[ $recipient =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]] || stop
cmp -s "$RECIPIENT_FILE" <(printf '%s\n' "$recipient") || stop
stage=credential
[[ -n ${CLOUDFLARE_API_TOKEN:-} ]] || stop
provider_token=$CLOUDFLARE_API_TOKEN
unset CLOUDFLARE_API_TOKEN
[[ ${#provider_token} -ge 20 && ${#provider_token} -le 512 && $provider_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop
for tool in jq curl age shasum; do command -v "$tool" >/dev/null 2>&1 || stop; done
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
printf 'recipient validation\n' | age -r "$recipient" -o "$scratch/probe.age" 2>/dev/null || stop

# Reuse the reviewed complete DNS exporter; its result stays private until all
# remaining reads succeed. It retains its own source and account bindings.
stage='dns-export'
CONFIRMATION=EXPORT_ENCRYPTED_DNS CLOUDFLARE_API_TOKEN="$provider_token" \
  OUTPUT_DIR="$scratch/dns" bash "$root/scripts/export-dns-snapshot.sh" > "$scratch/dns.log" 2>&1 || stop

# Fixed provider origin, GET only, no redirects/proxies/retries or credential argv.
read_cloudflare() {
  local url=$1 jurisdiction=${2:-default} observed_status=''
  failure='provider-transport'
  http_status=none
  if ! observed_status=$(printf 'header = "Authorization: Bearer %s"\n' "$provider_token" |
    curl --disable --config - --request GET --proto '=https' --noproxy '*' \
      --max-redirs 0 --connect-timeout 10 --max-time 20 --max-filesize 8388608 \
      --header "cf-r2-jurisdiction: $jurisdiction" --silent --fail --url "$url" \
      --output "$scratch/http-response" --write-out '%{http_code}' 2>/dev/null); then
    if [[ $observed_status =~ ^[1-5][0-9]{2}$ ]]; then
      http_status=$observed_status
      [[ $http_status =~ ^[45][0-9]{2}$ ]] && failure='provider-http'
    fi
    return 1
  fi
  failure='provider-status'
  [[ $observed_status =~ ^[1-5][0-9]{2}$ ]] || return 1
  http_status=$observed_status
  failure='provider-http'
  [[ $http_status =~ ^2[0-9]{2}$ ]] || return 1
  failure='provider-envelope'
  jq -s -e 'length == 1 and (.[0]|type == "object" and .success == true and
    (.errors == null or .errors == []))' "$scratch/http-response" >/dev/null 2>&1 || return 1
  failure='provider-duplicate-json'
  jq --stream -s -e '[.[]|select(length == 2)|.[0]] as $paths |
    ($paths|length) == ($paths|unique|length)' "$scratch/http-response" >/dev/null 2>&1 || return 1
  failure=validation
  cat "$scratch/http-response"
}
stage='zone-binding'
read_cloudflare 'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50' > "$scratch/zone.json" || stop
account_id=$(jq -er '
  if .success == true and (.result|type) == "array" and (.result|length) == 1 and
    .result_info.total_count == 1 and .result_info.total_pages == 1 and
    .result[0].name == "devantler.tech" and .result[0].status == "active" and
    (.result[0].id|type == "string" and test("^[a-f0-9]{32}$")) and
    (.result[0].account.id|type == "string" and test("^[a-f0-9]{32}$"))
  then .result[0].account.id else error("binding unavailable") end
' "$scratch/zone.json" 2>/dev/null) || stop
base="https://api.cloudflare.com/client/v4/accounts/$account_id"
stage='token-verification'
read_cloudflare "$base/tokens/verify" > "$scratch/verify.json" || stop
token_id=$(jq -er 'if .success == true and .result.status == "active" and
  (.result.id|type == "string" and test("^[a-f0-9]{32}$"))
  then .result.id else error("token unavailable") end' "$scratch/verify.json" 2>/dev/null) || stop
stage='token-policy'
read_cloudflare "$base/tokens/$token_id" > "$scratch/current-token.json" || stop
jq -e --arg id "$token_id" '.success == true and .result.id == $id and .result.status == "active" and
  (.result.policies|type == "array" and length > 0) and
  all(.result.policies[]; (.id|type == "string") and (.effect == "allow" or .effect == "deny") and
    (.permission_groups|type == "array" and length > 0) and
    all(.permission_groups[]; .id|type == "string" and test("^[a-f0-9]{32}$")) and
    (.resources|type == "object" and length > 0))' "$scratch/current-token.json" >/dev/null 2>&1 || stop

# Completeness is relative to the credential-visible result set. Cloudflare can
# restrict listing to self-created tokens; never infer account-wide visibility.
page=1 pages=1 total=0
stage='token-list'
while ((page <= pages)); do
  read_cloudflare "$base/tokens?per_page=50&page=$page&include_expired=true" > "$scratch/token-$page.json" || stop
  jq -e --argjson page "$page" '.success == true and (.result|type) == "array" and
    .result_info.page == $page and .result_info.per_page == 50 and
    (.result_info.total_count|type == "number") and
    .result_info.total_count == (.result_info.total_count|floor) and
    .result_info.total_count >= 1 and .result_info.total_count <= 1000 and
    .result_info.count == (.result|length) and
    (.result|length) == ([50, (.result_info.total_count-(($page-1)*50))]|min) and
    all(.result[]; (.id|type == "string" and test("^[a-f0-9]{32}$")) and
      (.name|type == "string") and (.status == "active" or .status == "disabled" or .status == "expired"))
  ' "$scratch/token-$page.json" >/dev/null 2>&1 || stop
  if ((page == 1)); then
    total=$(jq -r .result_info.total_count "$scratch/token-$page.json")
    pages=$(((total+49)/50))
  else
    jq -e --argjson total "$total" '.result_info.total_count == $total' "$scratch/token-$page.json" >/dev/null 2>&1 || stop
  fi
  page=$((page+1))
done
jq -s '[.[].result[]]' "$scratch"/token-*.json > "$scratch/tokens.json" 2>/dev/null || stop
jq -e --arg id "$token_id" --argjson total "$total" 'length == $total and
  ([.[].id]|unique|length) == $total and ([.[]|select(.id == $id)]|length) == 1
' "$scratch/tokens.json" >/dev/null 2>&1 || stop

mkdir "$scratch/buckets"
for jurisdiction in default eu us; do
  cursor='' seen=() count=0 expected=-1 page=0
  while :; do
    stage='bucket-list'
    page=$((page+1))
    ((page <= 10)) || stop
    url="$base/r2/buckets?per_page=1000"
    [[ -z "$cursor" ]] || url+="&cursor=$(jq -nr --arg cursor "$cursor" '$cursor|@uri')"
    response="$scratch/buckets-$jurisdiction-$page.json"
    read_cloudflare "$url" "$jurisdiction" > "$response" || stop
    failure='bucket-shape'
    bucket_failure=$(jq -r --arg jurisdiction "$jurisdiction" '
      # R2 may omit or clamp this optional hint. Completeness comes from
      # stable totals, cursor exhaustion and unique observed bucket names.
      def page_size_matches($count):
        if . == null then true
        elif type != "number" then false
        else . == floor and . >= 0 and . <= 1000 and . >= $count end;
      if (.result.buckets|type) != "array" then "bucket-array"
      elif (.result_info.total_count|type) != "number" then "bucket-total"
      elif .result_info.total_count != (.result_info.total_count|floor) or
        .result_info.total_count < 0 or .result_info.total_count > 100 then "bucket-total"
      elif (.result.buckets|length) > 100 then "bucket-result-bound"
      elif ((.result.buckets|length) as $count |
        .result_info.per_page | page_size_matches($count) | not) then "bucket-page-size"
      elif any(.result.buckets[]; (.name|type != "string") or
        (.name|test("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")|not)) then "bucket-name"
      elif any(.result.buckets[]; .jurisdiction != null and .jurisdiction != $jurisdiction) then "bucket-jurisdiction"
      elif any(.result.buckets[]; .location != null and (.location|type) != "string") then "bucket-location"
      elif any(.result.buckets[]; .storage_class != null and .storage_class != "Standard" and
        .storage_class != "InfrequentAccess") then "bucket-storage-class"
      elif .result_info.cursor != null and
        (.result_info.cursor|type != "string" or length > 2048) then "bucket-cursor"
      else "none" end
    ' "$response" 2>/dev/null) || stop
    [[ $bucket_failure == none ]] || { failure=$bucket_failure; stop; }
    failure=validation
    current_total=$(jq -r .result_info.total_count "$response")
    if ((expected == -1)); then expected=$current_total; else [[ $current_total == "$expected" ]] || stop; fi
    count=$((count+$(jq '.result.buckets|length' "$response")))
    ((count <= expected)) || stop
    cursor=$(jq -r '.result_info.cursor // ""' "$response")
    [[ -n "$cursor" ]] || break
    for previous in "${seen[@]}"; do [[ $previous != "$cursor" ]] || stop; done
    seen+=("$cursor")
  done
  ((count == expected)) || stop
  jq -s '[.[].result.buckets[]]' "$scratch"/buckets-"$jurisdiction"-*.json > "$scratch/list-$jurisdiction.json" 2>/dev/null || stop
  jq -e '([.[].name]|length) == ([.[].name]|unique|length)' "$scratch/list-$jurisdiction.json" >/dev/null 2>&1 || stop
  jq -r '.[].name' "$scratch/list-$jurisdiction.json" > "$scratch/bucket-names" 2>/dev/null || stop
  while IFS= read -r bucket; do
    stage='bucket-metadata'
    read_cloudflare "$base/r2/buckets/$bucket" "$jurisdiction" > "$scratch/metadata.json" || stop
    jq -e --arg name "$bucket" --arg jurisdiction "$jurisdiction" '.success == true and
      .result.name == $name and (.result.jurisdiction == null or .result.jurisdiction == $jurisdiction) and
      (.result.location == null or (.result.location|type == "string")) and
      (.result.storage_class == null or .result.storage_class == "Standard" or .result.storage_class == "InfrequentAccess")
    ' "$scratch/metadata.json" >/dev/null 2>&1 || stop
    stage='bucket-lifecycle'
    read_cloudflare "$base/r2/buckets/$bucket/lifecycle" "$jurisdiction" > "$scratch/lifecycle.json" || stop
    jq -e '.success == true and (.result.rules|type == "array") and
      all(.result.rules[]; (.id|type == "string" and length > 0 and length <= 255) and
        (.enabled|type == "boolean") and (.conditions.prefix|type == "string")) and
      ([.result.rules[].id]|length) == ([.result.rules[].id]|unique|length)
    ' "$scratch/lifecycle.json" >/dev/null 2>&1 || stop
    jq -n --arg jurisdiction "$jurisdiction" --slurpfile metadata "$scratch/metadata.json" --slurpfile lifecycle "$scratch/lifecycle.json" \
      '{requested_jurisdiction:$jurisdiction,metadata:$metadata[0].result,lifecycle:$lifecycle[0].result}' > "$scratch/buckets/$jurisdiction-$bucket.json" 2>/dev/null || stop
  done < "$scratch/bucket-names"
done
unset provider_token
stage=encryption
shopt -s nullglob
bucket_files=("$scratch/buckets/"*.json)
if ((${#bucket_files[@]})); then jq -s . "${bucket_files[@]}" > "$scratch/buckets.json" 2>/dev/null || stop; else printf '[]\n' > "$scratch/buckets.json"; fi
dns_digest=$(shasum -a 256 "$scratch/dns/dns-snapshot.json.age")
jq -n --arg revision "$GITHUB_SHA" --arg account "$account_id" --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg dns_digest "${dns_digest%% *}" --slurpfile current "$scratch/current-token.json" \
  --slurpfile tokens "$scratch/tokens.json" --slurpfile buckets "$scratch/buckets.json" '
  {schema:1,source_revision:$revision,captured_at:$captured,account_id:$account,dns_ciphertext_sha256:$dns_digest,
   token_inventory:{coverage:"credential-visible-only",current:$current[0].result,tokens:$tokens[0]},
   bucket_jurisdictions:["default","eu","us"],buckets:$buckets[0],migration_readiness:"UNVERIFIED"}
' > "$scratch/inventory.json" 2>/dev/null || stop
age -r "$recipient" -o "$scratch/inventory.age" "$scratch/inventory.json" 2>/dev/null || stop
stage=publication
mkdir -m 700 "$OUTPUT_DIR" || stop
output_created=true
mv "$scratch/dns/dns-snapshot.json.age" "$OUTPUT_DIR/dns-snapshot.json.age"
mv "$scratch/inventory.age" "$OUTPUT_DIR/bootstrap-inventory.json.age"
printf '%s\n' 'BOOTSTRAP_INVENTORY=ENCRYPTED_READS' 'MIGRATION_READINESS=UNVERIFIED'
