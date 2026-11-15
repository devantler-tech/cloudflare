#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# 1. Every unreviewed dispatch stops before credentials, state or provider access.
for scenario in ref actor repository event attempt runner workflow confirmation plan-recover mode; do
  (
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main
    export GITHUB_ACTOR=devantler GITHUB_REPOSITORY=devantler-tech/cloudflare
    export GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_ID=123456789 GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    export RUNNER_ENVIRONMENT=github-hosted
    export GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/dns-apply.yaml@refs/heads/main
    export DNS_MODE=apply DNS_PHASE=change CONFIRMATION=APPLY_DNS
    case $scenario in
      ref) GITHUB_REF=refs/heads/unreviewed ;;
      actor) GITHUB_ACTOR=unapproved ;;
      repository) GITHUB_REPOSITORY=other/cloudflare ;;
      event) GITHUB_EVENT_NAME=pull_request ;;
      attempt) GITHUB_RUN_ATTEMPT=2 ;;
      runner) RUNNER_ENVIRONMENT=self-hosted ;;
      workflow) GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/other.yaml@refs/heads/main ;;
      confirmation) DNS_MODE=plan ;;
      plan-recover) DNS_MODE=plan CONFIRMATION=PLAN_DNS DNS_PHASE=recover ;;
      mode) DNS_MODE=destroy ;;
    esac
    rc=0
    bash "$root/scripts/apply-dns.sh" "$root" > "$scratch/refusal" 2>&1 || rc=$?
    [[ $rc == 2 ]]
    grep -qx 'CLOUDFLARE_DNS_CHANGE=UNVERIFIED stage=dispatch' "$scratch/refusal"
  )
done
printf '%s\n' 'PASS: DNS changes refuse unreviewed dispatches before credentials or state'

# 2. Import resolution: exact single match imports, unknown names stay creates,
# and drift, ambiguity or external-dns ownership refuses.
zone=11111111111111111111111111111111
jq -n --arg zone "$zone" '{zone:{id:$zone}, records:[
  {id:"00000000000000000000000000000001",name:"devantler.tech",type:"MX",content:"mx01.mail.icloud.com"},
  {id:"00000000000000000000000000000002",name:"devantler.tech",type:"TXT",content:"\"v=spf1 include:icloud.com ~all\""},
  {id:"00000000000000000000000000000003",name:"devantler.tech",type:"TXT",content:"\"apple-domain=x\""},
  {id:"00000000000000000000000000000004",name:"dup.devantler.tech",type:"TXT",content:"\"same\""},
  {id:"00000000000000000000000000000005",name:"dup.devantler.tech",type:"TXT",content:"\"same\""},
  {id:"00000000000000000000000000000006",name:"portal.devantler.tech",type:"A",content:"192.0.2.1"},
  {id:"00000000000000000000000000000007",name:"_externaldns.a-portal.devantler.tech",type:"TXT",content:"\"heritage=external-dns\""},
  {id:"00000000000000000000000000000008",name:"_externaldns.a-ghost.devantler.tech",type:"TXT",content:"\"heritage=external-dns\""}
]}' > "$scratch/snapshot.json"
create() { jq -n --arg address "$1" --arg name "$2" --arg type "$3" --arg content "$4" \
  '{address:$address,mode:"managed",type:"cloudflare_dns_record",change:{actions:["create"],after:{name:$name,type:$type,content:$content}}}'; }
resolve() { jq -s '{resource_changes:.}' | jq --slurpfile snapshot "$scratch/snapshot.json" -f "$root/scripts/dns-imports.jq"; }
result=$( { create cloudflare_dns_record.mail_mx_01 devantler.tech MX mx01.mail.icloud.com
  create cloudflare_dns_record.mail_spf devantler.tech TXT '"v=spf1 include:icloud.com ~all"'
  create cloudflare_dns_record.marker _externaldns.cname-www.devantler.tech TXT '"heritage=external-dns"'; } | resolve)
jq -e --arg zone "$zone" '.refused==[] and .imports==[
  {address:"cloudflare_dns_record.mail_mx_01",id:($zone+"/00000000000000000000000000000001")},
  {address:"cloudflare_dns_record.mail_spf",id:($zone+"/00000000000000000000000000000002")}]' <<<"$result" >/dev/null
for refusal in content-differs:devantler.tech:TXT:'"v=spf1 -all"' ambiguous:dup.devantler.tech:TXT:'"same"' \
  external-dns-owned:portal.devantler.tech:A:192.0.2.1 external-dns-owned:_externaldns.a-portal.devantler.tech:TXT:'"heritage=external-dns"' \
  external-dns-owned:ghost.devantler.tech:A:192.0.2.9 content-differs:Devantler.tech.:TXT:'"v=spf1 -all"' content-differs:@:MX:mx99.example.test; do
  IFS=: read -r reason name type content <<<"$refusal"
  result=$(create cloudflare_dns_record.case "$name" "$type" "$content" | resolve)
  jq -e --arg reason "$reason" '.imports==[] and .refused==[{address:"cloudflare_dns_record.case",refused:$reason}]' <<<"$result" >/dev/null
done
result=$( { create cloudflare_dns_record.one devantler.tech MX mx01.mail.icloud.com
  create cloudflare_dns_record.two devantler.tech MX mx01.mail.icloud.com; } | resolve)
jq -e '.refused==[{address:"*",refused:"duplicate-target"}]' <<<"$result" >/dev/null
printf '%s\n' 'PASS: declared records import only from one exact unowned live record'

# 3. Plan boundary: imports must be unchanged, and nothing is deleted or replaced.
import_id="$zone/00000000000000000000000000000001"
printf '[{"address":"cloudflare_dns_record.mail_mx_01","id":"%s"}]\n' "$import_id" > "$scratch/imports.json"
record='{"name":"devantler.tech","type":"MX","content":"mx01.mail.icloud.com","ttl":3600}'
change() { jq -n --arg address "$1" --arg type "$2" --argjson actions "$3" --argjson before "$4" --argjson after "$5" --argjson importing "$6" \
  '{address:$address,mode:"managed",type:$type,change:({actions:$actions,before:$before,after:$after,after_unknown:{}} + (if $importing then {importing:$importing} else {} end))}'; }
plan() { jq -s '{resource_changes:.}'; }
check() { jq -e --slurpfile imports "$scratch/imports.json" -f "$root/scripts/check-dns-plan.jq" >/dev/null; }
noop_import=$(change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["no-op"]' "$record" "$record" "{\"id\":\"$import_id\"}")
zone_noop=$(change cloudflare_zone.primary cloudflare_zone '["no-op"]' '{}' '{}' null)
marker='{"name":"_externaldns.cname-www.devantler.tech","type":"TXT","content":"x"}'
{ printf '%s\n' "$noop_import" "$zone_noop"
  change cloudflare_dns_record.marker cloudflare_dns_record '["create"]' null "$marker" null
  change cloudflare_dns_record.apex cloudflare_dns_record '["update"]' '{"content":"a"}' '{"content":"b"}' null
  change cloudflare_dns_record.www cloudflare_dns_record '["forget"]' '{"content":"a"}' null null
} | plan | check
reject() { if plan | check; then printf 'FAIL: %s was admitted\n' "$1" >&2; exit 1; fi; }
change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["no-op"]' "$record" '{"name":"devantler.tech","type":"MX","content":"mx01.mail.icloud.com","ttl":300}' "{\"id\":\"$import_id\"}" | reject changing-import
change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["update"]' "$record" "$record" "{\"id\":\"$import_id\"}" | reject updating-import
change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["no-op"]' "$record" "$record" '{"id":"other/id"}' | reject wrong-import-target
printf '%s\n' "$zone_noop" | reject missing-import
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.mail_spf cloudflare_dns_record '["delete"]' "$record" null null; } | reject delete
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.mail_spf cloudflare_dns_record '["delete","create"]' "$record" "$record" null; } | reject replace
{ printf '%s\n' "$noop_import"; change cloudflare_zone.primary cloudflare_zone '["update"]' '{"a":1}' '{"a":2}' null; } | reject zone-update
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.bad cloudflare_dns_record '["create"]' null '{"name":"_externaldns.devantler.tech","type":"TXT","content":"x"}' null; } | reject typeless-apex-registry
for name in _externaldns _EXTERNALDNS.devantler.tech. _externaldns.Devantler.Tech; do
  { printf '%s\n' "$noop_import"; change cloudflare_dns_record.bad cloudflare_dns_record '["create"]' null "{\"name\":\"$name\",\"type\":\"TXT\",\"content\":\"x\"}" null; } | reject "typeless-apex-registry $name"
done
printf '%s\n' "$noop_import" | jq -s '{errored:true,resource_changes:.}' | if check; then exit 1; fi
printf '%s\n' "$noop_import" | jq -s '{deferred_changes:[{}],resource_changes:.}' | if check; then exit 1; fi
printf '%s\n' 'PASS: DNS plans admit unchanged imports, creates, updates and forgets only'

# 4. The declared mail records are the ones the company Email depends on.
grep -q 'content  = "mx01.mail.icloud.com"' "$root/dns.tf"
grep -q 'content  = "mx02.mail.icloud.com"' "$root/dns.tf"
if grep -q '"_externaldns.devantler.tech"' "$root/dns.tf"; then exit 1; fi
printf '%s\n' 'PASS: declared DNS keeps the Email records and never the typeless apex registry'
