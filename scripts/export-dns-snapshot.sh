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

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
# shellcheck source=scripts/dns-snapshot-common.sh
source "$script_dir/dns-snapshot-common.sh"
collect_dns_snapshot "$scratch"
unset provider_token

age -r "$recipient" -o "$scratch/snapshot.age" "$scratch/snapshot.json" 2>/dev/null || stop ENCRYPTION_FAILED
mkdir -m 700 "$OUTPUT_DIR" || stop OUTPUT_REFUSED
mv "$scratch/snapshot.age" "$OUTPUT_DIR/dns-snapshot.json.age"
printf '%s\n' 'DNS_SNAPSHOT=ENCRYPTED_COMPLETE' 'DEPLOYMENT_READINESS=UNVERIFIED'
