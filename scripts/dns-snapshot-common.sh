#!/usr/bin/env bash
# Shared private DNS collector. Source only after dispatch and credential guards.
[[ ${BASH_SOURCE[0]} != "$0" ]] || exit 2

# Keep the complete, bounded same-zone inventory in caller-owned private scratch.
collect_dns_snapshot() {
  local scratch=$1 zone_id page pages total
  : "${provider_token:?}"
  # Send authorization on stdin for the caller's fixed HTTPS GET, never in argv.
  read_cloudflare() {
    printf 'header = "Authorization: Bearer %s"\n' "$provider_token" |
      curl --disable --config - --request GET --proto '=https' --noproxy '*' \
        --max-redirs 0 --connect-timeout 10 --max-time 20 --max-filesize 8388608 \
        --silent --fail --url "$1" 2>/dev/null
  }

  read_cloudflare 'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50' > "$scratch/zone.json" || stop ZONE_READ_UNVERIFIED
  state_unique_json "$scratch/zone.json" || stop ZONE_READ_UNVERIFIED
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
    state_unique_json "$scratch/page-$page.json" || stop PAGINATION_UNVERIFIED
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

  jq -s '[.[].result[]]' "$scratch"/page-*.json > "$scratch/records.json" 2>/dev/null || stop INVENTORY_UNVERIFIED
  jq -e --argjson total "$total" 'length == $total and ([.[].id]|unique|length) == $total' "$scratch/records.json" >/dev/null 2>&1 || stop DUPLICATE_OR_MISSING_RECORDS
  jq -n --slurpfile zone "$scratch/zone.json" --slurpfile records "$scratch/records.json" \
    --arg revision "$GITHUB_SHA" --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:1, source_revision:$revision, captured_at:$captured, zone:$zone[0].result[0], records:$records[0]}
  ' > "$scratch/snapshot.json" 2>/dev/null || stop INVENTORY_UNVERIFIED
}
