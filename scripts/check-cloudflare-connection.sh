#!/usr/bin/env bash
# Read-only connection check. Provider responses and credentials never reach logs.
set +x
set -euo pipefail

stop() {
  printf 'CF_CONNECTION=%s\nDEPLOYMENT_READINESS=UNVERIFIED\n' "$1" >&2
  exit 2
}

[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main && ${CONFIRMATION:-} == VERIFY_READ_ONLY ]] || stop DISPATCH_REFUSED
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  stop TOOLS_UNAVAILABLE
fi
[[ -n ${CLOUDFLARE_API_TOKEN:-} ]] || stop MISSING_CREDENTIAL
[[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 && $CLOUDFLARE_API_TOKEN =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || stop INVALID_CREDENTIAL_FORMAT

read_cloudflare() {
  # The credential goes through stdin, never a process argument. Disabling
  # curlrc, proxies and redirects keeps the fixed provider destination intact.
  printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" |
    curl --disable --config - --request GET --proto '=https' --noproxy '*' \
      --max-redirs 0 --connect-timeout 10 --max-time 20 --max-filesize 1048576 \
      --silent --show-error --fail-with-body --url "$1" 2>/dev/null
}

zone_response=$(read_cloudflare 'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50') || stop ZONE_READ_UNVERIFIED
account_id=$(printf '%s' "$zone_response" | jq -er '
  if .success == true and (.result|type) == "array" and (.result|length) == 1
    and .result_info.total_count == 1 and .result_info.total_pages == 1
    and .result[0].name == "devantler.tech" and .result[0].status == "active"
    and (.result[0].account.id|type) == "string"
    and (.result[0].account.id|test("^[a-f0-9]{32}$"))
  then .result[0].account.id else error("owned zone binding unavailable") end
' 2>/dev/null) || stop ZONE_BINDING_UNVERIFIED
unset zone_response

token_response=$(read_cloudflare "https://api.cloudflare.com/client/v4/accounts/$account_id/tokens/verify") || stop TOKEN_READ_UNVERIFIED
printf '%s' "$token_response" | jq -e '
  .success == true and .result.status == "active"
  and (.result.id|type) == "string" and (.result.id|length) > 0 and (.result.id|length) <= 32
' >/dev/null 2>&1 || stop TOKEN_STATUS_UNVERIFIED
unset token_response account_id
printf '%s\n' 'CF_CONNECTION=READ_ACCESS_VERIFIED' 'DEPLOYMENT_READINESS=UNVERIFIED'
