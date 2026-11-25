#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
guard="$repo_root/scripts/assert-no-destructive-plan.sh"
fixtures="$repo_root/scripts/tests/fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$guard" "$fixtures/create-update.json" >/tmp/cloudflare-plan-safe.out 2>&1 ||
  fail "create/update plan should be accepted"
grep -Fxq "OpenTofu plan contains 0 destructive resource changes" /tmp/cloudflare-plan-safe.out ||
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

# Reviewed DNS record retirements: the optional second argument is the
# reviewed list (.github/dns-retirements.json). Without it, the reviewed
# retirement of mail_mx_02 is refused like every other delete.
retire="$fixtures/retire-mx02.json"
list="$fixtures/retirements.json"
if "$guard" "$retire" >"$work/unlisted.out" 2>&1; then
  fail "a delete without a retirement list should be rejected"
fi
grep -Fq 'cloudflare_dns_record.mail_mx_02: delete' "$work/unlisted.out" ||
  fail "a delete without a retirement list should name the resource"

"$guard" "$retire" "$list" >"$work/listed.out" 2>&1 ||
  fail "a listed pure DNS record delete should be accepted"
grep -Fxq 'OpenTofu plan contains 0 destructive resource changes besides 1 reviewed DNS record retirement(s)' "$work/listed.out" ||
  fail "an accepted retirement should be counted"
"$guard" "$fixtures/create-update.json" "$list" >"$work/safe-listed.out" 2>&1 ||
  fail "a plan without deletes should be accepted with a list"
grep -Fxq 'OpenTofu plan contains 0 destructive resource changes besides 0 reviewed DNS record retirement(s)' "$work/safe-listed.out" ||
  fail "a plan without retirements should count none"

# reject <plan> <list> <reported line> <case>
reject() {
  if "$guard" "$1" "$2" >"$work/reject.out" 2>&1; then
    fail "$4 should be rejected"
  fi
  grep -Fq "$3" "$work/reject.out" || fail "$4 should be reported as: $3"
}
reject "$fixtures/delete.json" "$list" 'cloudflare_dns_record.legacy: delete' "an unlisted delete"
reject "$fixtures/delete-zone.json" "$list" 'cloudflare_zone.primary: delete' "a zone delete"
reject "$fixtures/replace.json" "$list" 'cloudflare_r2_bucket.backups["velero"]: delete,create' "a bucket replacement"

# A listed record is still never replaced.
for actions in delete,create create,delete; do
  jq --arg actions "$actions" '(.resource_changes[] | select(.address == "cloudflare_dns_record.mail_mx_02") | .change.actions) = ($actions | split(","))' \
    "$retire" >"$work/plan.json"
  reject "$work/plan.json" "$list" "cloudflare_dns_record.mail_mx_02: $actions" "a listed replacement ($actions)"
done

# The plan's record must be the listed one: a DNS record, managed here, with
# the listed name, type and content before the change.
for edit in '.type = "cloudflare_r2_bucket"' '.mode = "data"' '.change.before = null' '.change.before.content = "mx01.mail.icloud.com"'; do
  jq "(.resource_changes[] | select(.address == \"cloudflare_dns_record.mail_mx_02\")) |= ($edit)" "$retire" >"$work/plan.json"
  reject "$work/plan.json" "$list" 'cloudflare_dns_record.mail_mx_02: delete' "a retirement whose plan differs ($edit)"
done
for edit in '.content = "mx01.mail.icloud.com"' '.name = "www.devantler.tech"' '.type = "TXT"' '.address = "cloudflare_dns_record.mail_mx_03"'; do
  jq ".retire[0] |= ($edit)" "$list" >"$work/list.json"
  reject "$retire" "$work/list.json" 'cloudflare_dns_record.mail_mx_02: delete' "a retirement whose list entry differs ($edit)"
done

# Names compare in their full, lower-case form.
for name in Devantler.Tech. @; do
  jq --arg name "$name" '.retire[0].name = $name' "$list" >"$work/list.json"
  "$guard" "$retire" "$work/list.json" >"$work/name.out" 2>&1 ||
    fail "the listed name $name should match devantler.tech"
done

# At most 20 entries, each exactly {address, name, type, content}, with unique
# addresses of DNS records declared here. Anything else is refused before the
# plan is read, even when the plan deletes nothing.
jq '.retire += [range(19) | {address: "cloudflare_dns_record.r\(.)", name: "r\(.).devantler.tech", type: "TXT", content: "x"}]' \
  "$list" >"$work/list.json"
"$guard" "$retire" "$work/list.json" >"$work/twenty.out" 2>&1 ||
  fail "a list of 20 entries should be accepted"
cat >"$work/malformed" <<'EOF'
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"mx","content":"mx02.mail.icloud.com"}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"SRV","content":"mx02.mail.icloud.com"}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"MX","content":""}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"MX","content":10}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"MX"}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com","extra":1}]}
{"retire":[{"address":"cloudflare_zone.primary","name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com"}]}
{"retire":[{"address":"cloudflare_r2_bucket.backups","name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com"}]}
{"retire":[{"address":"cloudflare_dns_record.records[\"x\"]","name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com"}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler tech","type":"MX","content":"mx02.mail.icloud.com"}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"","type":"MX","content":"mx02.mail.icloud.com"}]}
{"retire":[{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com"},{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com"}]}
{"retire":["cloudflare_dns_record.mail_mx_02"]}
{"retire":{}}
{"retire":[],"extra":1}
{"other":[]}
{"retire":[]} {"retire":[]}
[]
not json
EOF
jq -c '.retire += [range(20) | {address: "cloudflare_dns_record.r\(.)", name: "r\(.).devantler.tech", type: "TXT", content: "x"}]' \
  "$list" >>"$work/malformed"
while IFS= read -r malformed; do
  printf '%s\n' "$malformed" >"$work/list.json"
  for plan in "$retire" "$fixtures/create-update.json"; do
    if "$guard" "$plan" "$work/list.json" >"$work/malformed.out" 2>&1; then
      fail "a malformed retirement list was accepted: $malformed"
    fi
    grep -Fq 'retirement list is invalid' "$work/malformed.out" ||
      fail "a malformed retirement list should be reported: $malformed"
  done
done <"$work/malformed"
if "$guard" "$fixtures/create-update.json" "$work/missing.json" >"$work/missing.out" 2>&1; then
  fail "a missing retirement list should be rejected"
fi
if "$guard" "$fixtures/create-update.json" "$list" "$list" >"$work/arguments.out" 2>&1; then
  fail "a third argument should be rejected"
fi

# The repository's own list is valid, so a typo in it cannot stop every DNS run.
"$guard" "$fixtures/create-update.json" "$repo_root/.github/dns-retirements.json" >"$work/repository.out" 2>&1 ||
  fail "the repository's retirement list should be valid"

echo "PASS: DNS records are deleted only through the reviewed retirement list"
