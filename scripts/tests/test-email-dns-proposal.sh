#!/usr/bin/env bash
set -euo pipefail
umask 077
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp "$root/variables.tf" "$scratch/variables.tf"
jq -n '{account_id:"11111111111111111111111111111111",zone_name:"example.test",dns_records:{email:{name:"example.test",type:"TXT",content:"\"v=spf1 -all\"",comment:null}}}' > "$scratch/fixture.tfvars.json"
printf '%s\n' 'jsonencode({comment=var.dns_records["email"].comment,tags=var.dns_records["email"].tags})' |
  tofu -chdir="$scratch" console -no-color -var-file=fixture.tfvars.json > "$scratch/result.string.json"
jq -r . "$scratch/result.string.json" > "$scratch/result.json"
jq -e '.comment==null and .tags==[]' "$scratch/result.json" >/dev/null || {
  printf '%s\n' 'FAIL: existing Email DNS metadata would be changed by defaults' >&2
  exit 1
}
printf '%s\n' 'PASS: imported Email DNS keeps absent metadata'

jq -n '{
 schema:1,source_revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",captured_at:"2026-11-03T00:00:00Z",
 zone:{id:"11111111111111111111111111111111",name:"example.test",status:"active",account:{id:"22222222222222222222222222222222"}},
 records: [
  {id:"00000000000000000000000000000001",name:"example.test",type:"MX",content:"mx1.example.test",priority:10},
  {id:"00000000000000000000000000000002",name:"example.test",type:"MX",content:"mx2.example.test",priority:10},
  {id:"00000000000000000000000000000003",name:"example.test",type:"TXT",content:"\"v=spf1 -all\""},
  {id:"00000000000000000000000000000004",name:"_dmarc.example.test",type:"TXT",content:"\"v=DMARC1; p=reject\""},
  {id:"00000000000000000000000000000005",name:"sig1._domainkey.example.test",type:"CNAME",content:"sig1.keys.example.test",settings:{flatten_cname:false}},
  {id:"00000000000000000000000000000006",name:"example.test",type:"TXT",content:"\"apple-domain=private-fixture\""},
  {id:"00000000000000000000000000000007",name:"app.example.test",type:"A",content:"192.0.2.1"},
  {id:"00000000000000000000000000000008",name:"_acme-challenge.example.test",type:"TXT",content:"temporary-fixture"},
  {id:"00000000000000000000000000000009",name:"_externaldns.a-app.example.test",type:"TXT",content:"heritage=external-dns,external-dns/owner=example.test"}
 ] | map({ttl:300,proxied:false,comment:null,tags:[],settings:{}}+.)
}' > "$scratch/snapshot.json"
build() {
 jq --arg zone example.test --arg revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -f "$root/scripts/email-dns-proposal.jq" "$1"
}
build "$scratch/snapshot.json" > "$scratch/proposal.json"
jq -e '
 (.dns_records|length)==6 and (.imports|length)==6 and
 .dns_records.email_00000000000000000000000000000003.content=="\"v=spf1 -all\"" and
 .dns_records.email_00000000000000000000000000000005.settings.flatten_cname==false and
 .dns_records.email_00000000000000000000000000000001.priority==10 and
 all(.dns_records[];.comment==null and .tags==[]) and
 all(.imports[];.address|startswith("cloudflare_dns_record.records[\"email_"))
' "$scratch/proposal.json" >/dev/null
for mutation in \
 '.records += [.records[0]]' \
 '.zone.name="foreign.test"' \
 '.source_revision="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
 '.records[0].priority=null' \
 '.records[2].proxied=true' \
 '.records[4].settings.unsupported=true' \
 '.records[4].meta={managed_by_apps:true}' \
 '.records[4].tags=["owner:external-dns"]' \
 '.records[8].name="_externaldns.cname-sig1._domainkey.example.test"' \
 '.records[8].name="_externaldns.sig1._domainkey.example.test"' \
 '.records[2].content="unrecognized"' \
 '.records[1].id="../foreign"' \
 '.records[3].ttl=0'; do
 jq "$mutation" "$scratch/snapshot.json" > "$scratch/mutant.json"
 if build "$scratch/mutant.json" > "$scratch/rejected.json" 2> "$scratch/rejected.log"; then
   echo 'FAIL: ambiguous or controller-owned Email DNS was accepted' >&2; exit 1
 fi
 if grep -q 'private-fixture' "$scratch/rejected.log"; then
   echo 'FAIL: DNS proposal exposed record content' >&2; exit 1
 fi
done
printf '%s\n' 'PASS: only existing unambiguous static Email DNS is proposed'

jq --slurpfile proposal "$scratch/proposal.json" '.dns_records=$proposal[0].dns_records' "$scratch/fixture.tfvars.json" > "$scratch/proposal.tfvars.json"
printf '%s\n' 'jsonencode(var.dns_records)' | tofu -chdir="$scratch" console -no-color -var-file=proposal.tfvars.json > "$scratch/roundtrip.string.json"
jq -r . "$scratch/roundtrip.string.json" > "$scratch/roundtrip.json"
jq -e '.email_00000000000000000000000000000005.settings.flatten_cname==false and .email_00000000000000000000000000000003.content=="\"v=spf1 -all\""' "$scratch/roundtrip.json" >/dev/null || {
  echo 'FAIL: declared DNS variables discarded existing provider settings' >&2; exit 1
}
printf '%s\n' 'PASS: native variables preserve the complete proposed DNS values'

jq '.imports + [{address:"cloudflare_zone.primary",id:"11111111111111111111111111111111"},{address:"cloudflare_r2_bucket.buckets[\"cloudflare-bootstrap-state\"]",id:"22222222222222222222222222222222/cloudflare-bootstrap-state/default"}]' "$scratch/proposal.json" > "$scratch/imports.json"
jq -n --slurpfile wanted "$scratch/imports.json" '{errored:false,resource_changes:[$wanted[0][]|. as $r|{address,mode:"managed",type:(if .address=="cloudflare_zone.primary" then "cloudflare_zone" elif (.address|startswith("cloudflare_r2_bucket.")) then "cloudflare_r2_bucket" else "cloudflare_dns_record" end),change:{actions:["no-op"],before:{id:(if .address=="cloudflare_zone.primary" then .id else (.id|split("/")[1]) end)},after:{id:(if .address=="cloudflare_zone.primary" then .id else (.id|split("/")[1]) end)},after_unknown:{}}}]}' > "$scratch/plan.json"
check_plan() { jq -e --slurpfile wanted "$scratch/imports.json" -f "$root/scripts/check-email-dns-plan.jq" "$1" >/dev/null; }
check_plan "$scratch/plan.json"
for mutation in \
 '.resource_changes[0].change.actions=["update"]' \
 '.resource_changes[0].change.actions=["delete","create"]' \
 '.resource_changes[0].change.actions=["create"]' \
 '.resource_changes[0].change.after.id="foreign"' \
 '.resource_changes[0].change.before.id="foreign"' \
 '.resource_changes[0].change.after_unknown.id=true' \
 '.resource_changes[0].mode="data"' \
 '.resource_changes += [.resource_changes[0]]' \
 'del(.resource_changes[0])' \
 '.resource_changes[0].address="foreign"' \
 '.deferred_changes=[{}]' \
 '.resource_drift=[{}]' \
 '.errored=true'; do
 jq "$mutation" "$scratch/plan.json" > "$scratch/mutant-plan.json"
 if check_plan "$scratch/mutant-plan.json" 2>/dev/null; then echo 'FAIL: an incomplete or changing provider plan was accepted' >&2; exit 1; fi
done
printf '%s\n' 'PASS: only the complete unchanged imported provider plan is accepted'
