#!/usr/bin/env bash
# Private, read-only inventory. Only authenticated ciphertext leaves scratch.
set +x
set -euo pipefail
umask 077

stop() { printf 'DNS_SNAPSHOT=%s\n' "$1" >&2; exit 2; }

[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main \
  && ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_ACTOR:-} == devantler \
  && ${GITHUB_RUN_ATTEMPT:-} == 1 && ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ \
  && ${CONFIRMATION:-} == EXPORT_ENCRYPTED_DNS ]] || stop DISPATCH_REFUSED
[[ -n ${CLOUDFLARE_API_TOKEN:-} ]] || stop MISSING_CREDENTIAL
provider_token=$CLOUDFLARE_API_TOKEN
unset CLOUDFLARE_API_TOKEN
[[ ${#provider_token} -ge 20 && ${#provider_token} -le 512 && $provider_token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop INVALID_CREDENTIAL_FORMAT
for tool in jq curl age; do command -v "$tool" >/dev/null 2>&1 || stop TOOLS_UNAVAILABLE; done
[[ -n ${OUTPUT_DIR:-} && $OUTPUT_DIR == /* && ! -e $OUTPUT_DIR && ! -L $OUTPUT_DIR \
  && -f ${RECIPIENT_FILE:-} && ! -L $RECIPIENT_FILE ]] || stop OUTPUT_OR_RECIPIENT_REFUSED
recipient=$(cat "$RECIPIENT_FILE")
[[ $recipient =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]] || stop RECIPIENT_REFUSED

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Validate the native recipient before contacting the provider.
printf 'recipient validation\n' | age -r "$recipient" -o "$scratch/probe.age" 2>/dev/null || stop RECIPIENT_REFUSED

read_cloudflare() {
  printf 'header = "Authorization: Bearer %s"\n' "$provider_token" |
    curl --disable --config - --request GET --proto '=https' --noproxy '*' \
      --max-redirs 0 --connect-timeout 10 --max-time 20 --max-filesize 8388608 \
      --silent --fail --url "$1" 2>/dev/null
}

read_cloudflare 'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50' > "$scratch/zone.json" || stop ZONE_READ_UNVERIFIED
zone_id=$(jq -er '
  if .success == true and (.result|type) == "array" and (.result|length) == 1
    and .result_info.total_count == 1 and .result_info.total_pages == 1
    and .result[0].name == "devantler.tech" and .result[0].status == "active"
    and (.result[0].id|type) == "string" and (.result[0].id|test("^[a-f0-9]{32}$"))
    and (.result[0].account.id|type) == "string" and (.result[0].account.id|test("^[a-f0-9]{32}$"))
  then .result[0].id else error("zone binding unavailable") end
' "$scratch/zone.json" 2>/dev/null) || stop ZONE_BINDING_UNVERIFIED

page=1 pages=1 total=0
while ((page <= pages)); do
  read_cloudflare "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=1000&page=$page" > "$scratch/page-$page.json" || stop RECORD_READ_UNVERIFIED
  jq -e --argjson page "$page" '
    .success == true and (.result|type) == "array"
    and .result_info.page == $page and .result_info.per_page == 1000
    and (.result_info.total_count|type) == "number"
    and (.result_info.total_count|floor) == .result_info.total_count
    and .result_info.total_count > 0 and .result_info.total_count <= 10000
    and .result_info.total_pages == ((.result_info.total_count / 1000)|ceil)
    and .result_info.count == (.result|length)
    and (.result|length) == ([1000, (.result_info.total_count - (($page-1)*1000))]|min)
    and all(.result[];
      (.id|type) == "string" and (.id|test("^[a-f0-9]{32}$"))
      and (.name|type) == "string" and (.name == "devantler.tech" or (.name|endswith(".devantler.tech")))
      and (.type|type) == "string" and (.type|length) > 0)
  ' "$scratch/page-$page.json" >/dev/null 2>&1 || stop PAGINATION_UNVERIFIED
  if ((page == 1)); then
    pages=$(jq -r .result_info.total_pages "$scratch/page-$page.json")
    total=$(jq -r .result_info.total_count "$scratch/page-$page.json")
  else
    jq -e --argjson pages "$pages" --argjson total "$total" '
      .result_info.total_pages == $pages and .result_info.total_count == $total
    ' "$scratch/page-$page.json" >/dev/null 2>&1 || stop INVENTORY_CHANGED
  fi
  page=$((page+1))
done
unset provider_token zone_id

jq -s '[.[].result[]]' "$scratch"/page-*.json > "$scratch/records.json" 2>/dev/null || stop INVENTORY_UNVERIFIED
jq -e --argjson total "$total" 'length == $total and ([.[].id]|unique|length) == $total' "$scratch/records.json" >/dev/null 2>&1 || stop DUPLICATE_OR_MISSING_RECORDS
jq -n --slurpfile zone "$scratch/zone.json" --slurpfile records "$scratch/records.json" \
  --arg revision "$GITHUB_SHA" --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {schema:1, source_revision:$revision, captured_at:$captured, zone:$zone[0].result[0], records:$records[0]}
' > "$scratch/snapshot.json" 2>/dev/null || stop INVENTORY_UNVERIFIED
age -r "$recipient" -o "$scratch/snapshot.age" "$scratch/snapshot.json" 2>/dev/null || stop ENCRYPTION_FAILED
mkdir -m 700 "$OUTPUT_DIR" || stop OUTPUT_REFUSED
mv "$scratch/snapshot.age" "$OUTPUT_DIR/dns-snapshot.json.age"
printf '%s\n' 'DNS_SNAPSHOT=ENCRYPTED_COMPLETE' 'DEPLOYMENT_READINESS=UNVERIFIED'
