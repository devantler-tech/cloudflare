#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
guard="$repo_root/scripts/assert-no-destructive-plan.sh"
fixtures="$repo_root/scripts/tests/fixtures"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$guard" "$fixtures/create-update.json" >/tmp/cloudflare-plan-safe.out 2>&1 ||
  fail "create/update plan should be accepted"
grep -Fq "0 destructive resource changes" /tmp/cloudflare-plan-safe.out ||
  fail "safe-plan confirmation is missing"

if "$guard" "$fixtures/delete.json" >/tmp/cloudflare-plan-delete.out 2>&1; then
  fail "delete plan should be rejected"
fi
grep -Fq 'cloudflare_dns_record.legacy: delete' /tmp/cloudflare-plan-delete.out ||
  fail "delete rejection should name the resource and action"

if "$guard" "$fixtures/replace.json" >/tmp/cloudflare-plan-replace.out 2>&1; then
  fail "replacement plan should be rejected"
fi
grep -Fq 'cloudflare_r2_bucket.backups["velero"]: delete,create' /tmp/cloudflare-plan-replace.out ||
  fail "replacement rejection should name the resource and action sequence"

echo "PASS: destructive OpenTofu plans fail closed"
