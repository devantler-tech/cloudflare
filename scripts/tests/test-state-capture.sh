#!/usr/bin/env bash
# Exercise the runbook conversion with native OpenTofu, a local backend and
# synthetic values. No provider is installed and no infrastructure is applied.
set -euo pipefail
umask 077
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for variable in account_id zone_name dns_records r2_buckets r2_lifecycle_rules account_tokens; do
  printf 'variable "%s" {}\n' "$variable" >> "$scratch/main.tf"
done
cat > "$scratch/production.auto.tfvars" <<'VARS'
account_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
zone_name = "example.invalid"
dns_records = { fixture = { name = "example.invalid", type = "TXT", content = "synthetic \"quoted\" configuration" } }
r2_buckets = {}
r2_lifecycle_rules = {}
account_tokens = {}
VARS
printf '%s\n' '{"version":4,"terraform_version":"1.12.0","serial":7,"lineage":"12345678-1234-1234-1234-123456789abc","outputs":{},"resources":[]}' > "$scratch/terraform.tfstate"
export TF_DATA_DIR="$scratch/.terraform" TF_WORKSPACE=default
tofu -chdir="$scratch" init -backend=false -input=false > "$scratch/init.log" 2>&1
tofu -chdir="$scratch" state pull > "$scratch/state.json" 2> "$scratch/capture.err"
jq -e '.version==4 and .serial==7 and .lineage=="12345678-1234-1234-1234-123456789abc"' "$scratch/state.json" >/dev/null
# Execute the actual single expression published in the runbook, not a second
# hand-maintained copy that could continue passing after the instructions break.
expression=$(sed -n '/^jsonencode({ account_id = var.account_id,/p' "$repo_root/docs/runbooks/bootstrap-and-recovery.md")
[[ -n "$expression" && $(printf '%s\n' "$expression" | wc -l) -eq 1 ]]
printf '%s\n' "$expression" | tofu -chdir="$scratch" console -var-file=production.auto.tfvars > "$scratch/variables.console.json" 2>> "$scratch/capture.err"
jq -er 'select(type == "string") | fromjson | select(type == "object")' "$scratch/variables.console.json" > "$scratch/configuration.json"
jq -e '
  keys==["account_id","account_tokens","dns_records","r2_buckets","r2_lifecycle_rules","zone_name"] and
  .account_id=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .zone_name=="example.invalid" and
  .dns_records.fixture.content=="synthetic \"quoted\" configuration" and
  .r2_buckets=={} and .r2_lifecycle_rules=={} and .account_tokens=={}
' "$scratch/configuration.json" >/dev/null
printf '%s\n' 'PASS: native private state capture and HCL-to-JSON runbook conversion'
