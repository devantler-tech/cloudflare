#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck source=scripts/r2-backend-common.sh
source "$root/scripts/r2-backend-common.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/root" "$scratch/root/.github" "$scratch/root/recovery"
ln -s "$root/scripts" "$scratch/root/scripts"
age-keygen -o "$scratch/identity" 2>/dev/null
age-keygen -y "$scratch/identity" > "$scratch/root/.github/dns-recovery-recipient.txt"
printf '%s\n' '{"version":4,"terraform_version":"1.12.6","serial":1,"lineage":"12345678-1234-1234-1234-123456789abc","outputs":{},"resources":[{"mode":"managed","type":"cloudflare_zone","name":"primary","instances":[{"attributes":{"name":"example.invalid","account":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}]}]}' > "$scratch/state.json"
printf '%s\n' '{"account_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","zone_name":"example.invalid","dns_records":{},"r2_buckets":{"cloudflare-bootstrap-state":{}},"r2_lifecycle_rules":{},"account_tokens":{}}' > "$scratch/configuration.json"
bash "$root/scripts/prepare-state-recovery-package.sh" "$scratch/root" "$scratch/state.json" "$scratch/configuration.json" "$scratch/root/recovery/backend-source" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123456789 2026-11-02T12:00:00Z >/dev/null
backend_configuration "$scratch/root" "$scratch/configuration.json"
# The migration boundary must authenticate exact captured bytes before creating
# an output. This test fails if altered or noncanonical input can reach a backend.
jq -Rsj '@base64' "$scratch/state.json" > "$scratch/state.base64"
backend_migration_state "$scratch/root" "$scratch/configuration.json" "$scratch/accepted-state.json" < "$scratch/state.base64"
cmp "$scratch/state.json" "$scratch/accepted-state.json"
for scenario in changed-state malformed whitespace existing-output; do
  target="$scratch/rejected-$scenario.json"
  case "$scenario" in
    changed-state) jq '.serial+=1' "$scratch/state.json" | jq -Rsj '@base64' > "$scratch/bad-state.base64" ;;
    malformed) printf '%s' 'invalid-encoded-state!' > "$scratch/bad-state.base64" ;;
    whitespace) cp "$scratch/state.base64" "$scratch/bad-state.base64"; printf '\n' >> "$scratch/bad-state.base64" ;;
    existing-output) cp "$scratch/state.base64" "$scratch/bad-state.base64"; printf '%s\n' preserved > "$target" ;;
  esac
  if backend_migration_state "$scratch/root" "$scratch/configuration.json" "$target" < "$scratch/bad-state.base64"; then
    printf 'FAIL: migration input admitted %s\n' "$scenario" >&2; exit 1
  fi
  if [[ $scenario == existing-output ]]; then
    grep -qx preserved "$target"
  else
    [[ ! -e "$target" && ! -L "$target" ]]
  fi
done
# A green run from another source, workflow or attempt cannot authorize writes.
jq -n '{id:123456789,head_sha:("a"*40),head_branch:"main",event:"workflow_dispatch",path:".github/workflows/state-backend-proof.yaml",actor:{login:"devantler"},run_attempt:1,status:"completed",conclusion:"success"}' > "$scratch/proof-run.json"
backend_proof_run "$scratch/proof-run.json" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123456789 987654321
for mutation in '.head_sha=("b"*40)' '.head_branch="other"' '.event="push"' '.path=".github/workflows/other.yaml"' '.status="in_progress"' '.conclusion="failure"' '.run_attempt=2' '.actor.login="other"' '.id=111111111'; do
  jq "$mutation" "$scratch/proof-run.json" > "$scratch/wrong-proof.json"
  if backend_proof_run "$scratch/wrong-proof.json" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123456789 987654321; then
    printf '%s\n' 'FAIL: unrelated proof authorized migration' >&2; exit 1
  fi
done
if backend_proof_run "$scratch/proof-run.json" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123456789 123456789; then
  printf '%s\n' 'FAIL: migration authenticated itself as its prerequisite' >&2; exit 1
fi
# gh secret set reads stdin with trailing CR/LF removed. The native capture
# ends in LF, so both original and transported inputs must retain its exact hash.
backend_configuration_input < "$scratch/configuration.json" > "$scratch/transport-original.json"
cmp "$scratch/configuration.json" "$scratch/transport-original.json"
jq -Rsj 'rtrimstr("\n")' "$scratch/configuration.json" > "$scratch/transport-trimmed.json"
backend_configuration_input < "$scratch/transport-trimmed.json" > "$scratch/transport-restored.json"
cmp "$scratch/configuration.json" "$scratch/transport-restored.json"
backend_configuration "$scratch/root" "$scratch/transport-restored.json"
printf '\n' >> "$scratch/transport-restored.json"
backend_configuration_input < "$scratch/transport-restored.json" > "$scratch/transport-extra-line.json"
if backend_configuration "$scratch/root" "$scratch/transport-extra-line.json"; then printf '%s\n' 'FAIL: unrelated whitespace bypassed the full digest' >&2; exit 1; fi
jq '.account_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$scratch/configuration.json" > "$scratch/wrong-configuration.json"
if backend_configuration "$scratch/root" "$scratch/wrong-configuration.json"; then printf '%s\n' 'FAIL: configuration digest mismatch was accepted' >&2; exit 1; fi
ln -s "$scratch/configuration.json" "$scratch/linked-configuration.json"
if backend_configuration "$scratch/root" "$scratch/linked-configuration.json"; then printf '%s\n' 'FAIL: linked configuration was accepted' >&2; exit 1; fi
jq -n '{success:true,errors:[],result:{accessKeyId:("a"*32),secretAccessKey:("b"*64),sessionToken:"SYNTHETIC_SESSION_TOKEN"}}' > "$scratch/session.json"
backend_session "$scratch/session.json"
for scenario in missing-token duplicate-token null-token header-injection extra-result too-large; do
  case "$scenario" in
    missing-token) jq 'del(.result.sessionToken)' "$scratch/session.json" > "$scratch/bad.json" ;;
    duplicate-token)
      jq -c . "$scratch/session.json" | sed 's/"sessionToken":"SYNTHETIC_SESSION_TOKEN"/&,"sessionToken":"SYNTHETIC_SESSION_TOKEN_2"/' > "$scratch/bad.json"
      # Ordinary decoding erases the duplicate. Its result must still pass all
      # other checks, so this case tests duplicate rejection specifically.
      jq -c . "$scratch/bad.json" > "$scratch/normalized-session.json"
      backend_session "$scratch/normalized-session.json"
      ;;
    null-token) jq '.result.sessionToken=null' "$scratch/session.json" > "$scratch/bad.json" ;;
    header-injection) jq '.result.sessionToken="synthetic\r\nAuthorization: injected"' "$scratch/session.json" > "$scratch/bad.json" ;;
    extra-result) jq '.result.unreviewed="extra"' "$scratch/session.json" > "$scratch/bad.json" ;;
    too-large) jq '.result.sessionToken=("a"*6145)' "$scratch/session.json" > "$scratch/bad.json" ;;
  esac
  if backend_session "$scratch/bad.json"; then printf 'FAIL: session parser admitted %s\n' "$scenario" >&2; exit 1; fi
done
printf '%s\n' 'PASS: bounded session credentials and ambiguous/header-unsafe input refusals'
