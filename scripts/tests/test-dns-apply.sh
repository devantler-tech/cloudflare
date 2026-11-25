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
  {id:"00000000000000000000000000000008",name:"_externaldns.a-ghost.devantler.tech",type:"TXT",content:"\"heritage=external-dns\""},
  {id:"00000000000000000000000000000009",name:"www.devantler.tech",type:"CNAME",content:"pages.example.test"},
  {id:"0000000000000000000000000000000a",name:"sig1._domainkey.devantler.tech",type:"CNAME",content:"dkim.example.test"},
  {id:"0000000000000000000000000000000b",name:"sig2._domainkey.devantler.tech",type:"CNAME",content:"dkim2.example.test"},
  {id:"0000000000000000000000000000000c",name:"www.devantler.tech",type:"A",content:"192.0.2.10"},
  {id:"0000000000000000000000000000000d",name:"www.devantler.tech",type:"AAAA",content:"2001:db8::10"}
]}' > "$scratch/snapshot.json"
create() { jq -n --arg address "$1" --arg name "$2" --arg type "$3" --arg content "$4" \
  '{address:$address,mode:"managed",type:"cloudflare_dns_record",change:{actions:["create"],after:{name:$name,type:$type,content:$content}}}'; }
# A plan from the real backend always has the zone in its prior state.
state() { jq -s --argjson ids "$1" '{prior_state:{values:{root_module:{resources:([{type:"cloudflare_zone",values:{id:"z"}}] +
  [$ids[]|{type:"cloudflare_dns_record",values:{id:.}}])}}},resource_changes:.}'; }
resolve() { state '[]' | jq --slurpfile snapshot "$scratch/snapshot.json" -f "$root/scripts/dns-imports.jq"; }
# Without the zone in prior state the managed set is unproven, so resolution stops.
if create cloudflare_dns_record.mail_mx_01 devantler.tech MX mx01.mail.icloud.com |
  jq -s '{prior_state:{values:{root_module:{resources:[{type:"cloudflare_dns_record",values:{id:"00000000000000000000000000000002"}}]}}},resource_changes:.}' |
  jq --slurpfile snapshot "$scratch/snapshot.json" -f "$root/scripts/dns-imports.jq" >/dev/null 2>&1; then exit 1; fi
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
# A record already managed here is never adopted a second time, and managed
# siblings do not block a genuinely new record at the same name and type.
result=$(create cloudflare_dns_record.mail_mx_03 devantler.tech MX mx01.mail.icloud.com |
  state '["00000000000000000000000000000001"]' | jq --slurpfile snapshot "$scratch/snapshot.json" -f "$root/scripts/dns-imports.jq")
jq -e '.imports==[] and .refused==[{address:"cloudflare_dns_record.mail_mx_03",refused:"already-managed"}]' <<<"$result" >/dev/null
result=$(create cloudflare_dns_record.new_txt devantler.tech TXT '"new-proof"' |
  state '["00000000000000000000000000000002","00000000000000000000000000000003"]' | jq --slurpfile snapshot "$scratch/snapshot.json" -f "$root/scripts/dns-imports.jq")
jq -e '.imports==[] and .refused==[]' <<<"$result" >/dev/null
result=$(create cloudflare_dns_record.lower devantler.tech txt '"apple-domain=x"' | resolve)
jq -e --arg zone "$zone" '.refused==[] and .imports==[{address:"cloudflare_dns_record.lower",id:($zone+"/00000000000000000000000000000003")}]' <<<"$result" >/dev/null
printf '%s\n' 'PASS: declared records import only from one exact unowned live record'

# 3. Plan boundary: imports must be unchanged, nothing is replaced, nothing is
# deleted while the retirement list is empty (3c covers listed retirements),
# and an ownership record may only claim a record this plan stops managing.
import_id="$zone/00000000000000000000000000000001"
printf '[{"address":"cloudflare_dns_record.mail_mx_01","id":"%s"}]\n' "$import_id" > "$scratch/imports.json"
record='{"name":"devantler.tech","type":"MX","content":"mx01.mail.icloud.com","ttl":3600}'
dkim='{"name":"sig1._domainkey.devantler.tech","type":"CNAME","content":"dkim.example.test"}'
www='{"id":"00000000000000000000000000000009","name":"www.devantler.tech","type":"CNAME","content":"pages.example.test"}'
change() { jq -n --arg address "$1" --arg type "$2" --argjson actions "$3" --argjson before "$4" --argjson after "$5" --argjson importing "$6" \
  '{address:$address,mode:"managed",type:$type,change:({actions:$actions,before:$before,after:$after,after_unknown:{}} + (if $importing then {importing:$importing} else {} end))}'; }
plan() { jq -s '{resource_changes:.}'; }
printf '%s\n' '{"externalDnsHandover":[]}' > "$scratch/handover.json"
printf '%s\n' '{"retire":[]}' > "$scratch/retirements.json"
check() { jq -e --slurpfile imports "$scratch/imports.json" --slurpfile snapshot "$scratch/snapshot.json" --slurpfile handover "$scratch/handover.json" \
  --slurpfile retirements "$scratch/retirements.json" -f "$root/scripts/check-dns-plan.jq" >/dev/null; }
noop_import=$(change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["no-op"]' "$record" "$record" "{\"id\":\"$import_id\"}")
zone_noop=$(change cloudflare_zone.primary cloudflare_zone '["no-op"]' '{}' '{}' null)
dkim_kept=$(change cloudflare_dns_record.mail_dkim_sig1 cloudflare_dns_record '["no-op"]' "$dkim" "$dkim" null)
marker() { change cloudflare_dns_record.marker cloudflare_dns_record '["create"]' null "{\"name\":\"$1\",\"type\":\"TXT\",\"content\":\"x\"}" null; }
# The www handover: the marker claims www, which the same plan forgets.
{ printf '%s\n' "$noop_import" "$zone_noop" "$dkim_kept"
  marker _externaldns.cname-www.devantler.tech
  change cloudflare_dns_record.apex cloudflare_dns_record '["update"]' '{"name":"devantler.tech","type":"CNAME","content":"a"}' '{"name":"devantler.tech","type":"CNAME","content":"b"}' null
  change cloudflare_dns_record.www cloudflare_dns_record '["forget"]' "$www" null null
} | plan | check
reject() { if plan | check; then printf 'FAIL: %s was admitted\n' "$1" >&2; exit 1; fi; }
change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["no-op"]' "$record" '{"name":"devantler.tech","type":"MX","content":"mx01.mail.icloud.com","ttl":300}' "{\"id\":\"$import_id\"}" | reject changing-import
change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["update"]' "$record" "$record" "{\"id\":\"$import_id\"}" | reject updating-import
change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["no-op"]' "$record" "$record" '{"id":"other/id"}' | reject wrong-import-target
printf '%s\n' "$zone_noop" | reject missing-import
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.mail_spf cloudflare_dns_record '["delete"]' "$record" null null; } | reject delete
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.mail_spf cloudflare_dns_record '["delete","create"]' "$record" "$record" null; } | reject replace
{ printf '%s\n' "$noop_import"; change cloudflare_zone.primary cloudflare_zone '["update"]' '{"a":1}' '{"a":2}' null; } | reject zone-update
for name in _externaldns.devantler.tech _externaldns _EXTERNALDNS.devantler.tech. _externaldns.Devantler.Tech; do
  { printf '%s\n' "$noop_import"; marker "$name"; } | reject "typeless-apex-registry $name"
done
# Markers that would hand a record still managed here, such as mail, to external-dns.
for name in _externaldns.cname-sig1._domainkey.devantler.tech _externaldns.CNAME-sig1._domainkey.devantler.tech. _externaldns.sig1._domainkey.devantler.tech; do
  { printf '%s\n' "$noop_import" "$dkim_kept"; marker "$name"; } | reject "mail-claiming marker $name"
done
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.www cloudflare_dns_record '["no-op"]' "$www" "$www" null
  marker _externaldns.cname-www.devantler.tech; } | reject "marker for a record still managed here"
{ printf '%s\n' "$noop_import"; marker _externaldns.cname-www.devantler.tech
  change cloudflare_dns_record.www cloudflare_dns_record '["forget"]' '{"name":"www.devantler.tech","type":"CNAME"}' null null; } | reject "forget without the record id"
{ printf '%s\n' "$noop_import"; marker _externaldns.cname-www.devantler.tech
  change cloudflare_dns_record.www cloudflare_dns_record '["forget"]' '{"id":"0000000000000000000000000000000b","name":"www.devantler.tech","type":"CNAME"}' null null; } | reject "forget of a different record"
# A marker must claim a live record, and only records this plan forgets.
{ printf '%s\n' "$noop_import"; marker _externaldns.cname-nothing.devantler.tech; } | reject "marker that claims nothing"
for name in _externaldns.cname-sig2._domainkey.devantler.tech _externaldns.sig2._domainkey.devantler.tech; do
  { printf '%s\n' "$noop_import"; marker "$name"; } | reject "marker for an unmanaged live record $name"
done
# The reviewed handover list admits a claim on an unmanaged live record it names, and nothing else.
{ printf '%s\n' "$noop_import"; marker _externaldns.a-www.devantler.tech; } | reject "unlisted handover of www A"
printf '%s\n' '{"externalDnsHandover":[{"type":"A","name":"www.devantler.tech"}]}' > "$scratch/handover.json"
{ printf '%s\n' "$noop_import"; marker _externaldns.a-www.devantler.tech; } | plan | check
{ printf '%s\n' "$noop_import"; marker _externaldns.cname-sig2._domainkey.devantler.tech; } | reject "handover of an unlisted record"
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.www_a cloudflare_dns_record '["no-op"]' '{"name":"www.devantler.tech","type":"A","content":"192.0.2.10"}' '{"name":"www.devantler.tech","type":"A","content":"192.0.2.10"}' null
  marker _externaldns.a-www.devantler.tech; } | reject "listed record that is still declared here"
{ printf '%s\n' "$noop_import"; marker _externaldns.cname-www.devantler.tech; } | reject "listed name, unlisted type"
# A listed record may only be claimed by its own typed marker, never a wider typeless one.
printf '%s\n' '{"externalDnsHandover":[{"type":"A","name":"www.devantler.tech"},{"type":"AAAA","name":"www.devantler.tech"},{"type":"CNAME","name":"www.devantler.tech"}]}' > "$scratch/handover.json"
{ printf '%s\n' "$noop_import"; marker _externaldns.www.devantler.tech; } | reject "typeless marker for listed records"
twenty_one=$(jq -cn '{externalDnsHandover:([{type:"A",name:"www.devantler.tech"}] + [range(20)|{type:"A",name:"h\(.).devantler.tech"}])}')
for list in '{"externalDnsHandover":[{"type":"a","name":"www.devantler.tech"}]}' '{"externalDnsHandover":[{"type":"TXT","name":"devantler.tech"}]}' \
  '{"externalDnsHandover":[{"type":"A","name":"www.devantler.tech","extra":1}]}' '{"other":[]}' \
  '{"externalDnsHandover":[{"type":"A","name":"www.devantler.tech"}],"extra":1}' "$twenty_one" \
  '{"externalDnsHandover":[{"type":"A","name":"www.devantler.tech"},{"type":"CNAME","name":"sig2._domainkey.devantler.tech"}]}'; do
  printf '%s\n' "$list" > "$scratch/handover.json"
  { printf '%s\n' "$noop_import"; marker _externaldns.a-www.devantler.tech; } | reject "invalid handover list $list"
done
# The repository's own list is valid, so a typo in it cannot stop every DNS run.
cp "$root/.github/dns-handover.json" "$scratch/handover.json"
printf '%s\n' "$noop_import" | plan | check
printf '%s\n' '{"externalDnsHandover":[]}' > "$scratch/handover.json"
# A record external-dns owns is never written here, and every write has a known
# name (OpenTofu writes an unknown value as null).
portal='{"name":"portal.devantler.tech","type":"A","content":"192.0.2.2"}'
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.portal cloudflare_dns_record '["update"]' '{"name":"portal.devantler.tech","type":"A","content":"192.0.2.1"}' "$portal" null; } | reject owned-update
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.portal cloudflare_dns_record '["update"]' "$portal" '{"name":"archive.devantler.tech","type":"A","content":"192.0.2.2"}' null; } | reject rename-away-from-owned
{ printf '%s\n' "$noop_import" "$dkim_kept"; change cloudflare_dns_record.marker cloudflare_dns_record '["create"]' null '{"name":"_externaldns.cname-sig1._domainkey.devantler.tech","type":"txt","content":"x"}' null; } | reject lower-case-marker-type
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.nameless cloudflare_dns_record '["create"]' null '{"type":"TXT","content":"x"}' null; } | reject missing-name
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.spaced cloudflare_dns_record '["create"]' null '{"name":" _externaldns.devantler.tech","type":"TXT","content":"x"}' null; } | reject non-hostname-name
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.newline cloudflare_dns_record '["create"]' null '{"name":"portal.devantler.tech\n","type":"A","content":"192.0.2.3"}' null; } | reject trailing-newline-name
printf '%s\n' "$noop_import" | jq -s '{errored:true,resource_changes:.}' | if check; then exit 1; fi
printf '%s\n' "$noop_import" | jq -s '{deferred_changes:[{}],resource_changes:.}' | if check; then exit 1; fi
printf '%s\n' 'PASS: DNS plans admit unchanged imports, creates, updates and forgets only'

# 3b. The zone's single-instance settings are always imported, may then be updated,
# and are never created, forgotten or widened to other zone settings.
setting() { jq -n --arg address "$1" --arg type "$2" --arg setting "$3" '{address:$address,mode:"managed",type:$type,change:{actions:["create"],after:({zone_id:null} + (if $setting=="" then {} else {setting_id:$setting,value:"off"} end))}}'; }
result=$( { setting cloudflare_bot_management.primary cloudflare_bot_management ""
  setting cloudflare_zone_setting.email_obfuscation cloudflare_zone_setting email_obfuscation
  setting cloudflare_zone_setting.nel cloudflare_zone_setting nel
  setting cloudflare_zone_setting.rocket_loader cloudflare_zone_setting rocket_loader; } | resolve)
jq -e --arg zone "$zone" '.refused==[] and .imports==[
  {address:"cloudflare_bot_management.primary",id:$zone},
  {address:"cloudflare_zone_setting.email_obfuscation",id:($zone+"/email_obfuscation")},
  {address:"cloudflare_zone_setting.nel",id:($zone+"/nel")}]' <<<"$result" >/dev/null
printf '%s\n' "[{\"address\":\"cloudflare_bot_management.primary\",\"id\":\"$zone\"},{\"address\":\"cloudflare_zone_setting.email_obfuscation\",\"id\":\"$zone/email_obfuscation\"}]" > "$scratch/imports.json"
bot_import=$(change cloudflare_bot_management.primary cloudflare_bot_management '["update"]' '{"fight_mode":true,"enable_js":true}' '{"fight_mode":false,"enable_js":false}' "{\"id\":\"$zone\"}")
obfuscation_import=$(change cloudflare_zone_setting.email_obfuscation cloudflare_zone_setting '["update"]' '{"setting_id":"email_obfuscation","value":"on"}' '{"setting_id":"email_obfuscation","value":"off"}' "{\"id\":\"$zone/email_obfuscation\"}")
printf '%s\n' "$bot_import" "$obfuscation_import" | plan | check
# The import list names only the other resource, so only the action rule can refuse these.
printf '%s\n' "[{\"address\":\"cloudflare_zone_setting.email_obfuscation\",\"id\":\"$zone/email_obfuscation\"}]" > "$scratch/imports.json"
{ printf '%s\n' "$obfuscation_import"; change cloudflare_bot_management.primary cloudflare_bot_management '["create"]' null '{"fight_mode":false}' null; } | reject "created bot management"
printf '%s\n' "[{\"address\":\"cloudflare_bot_management.primary\",\"id\":\"$zone\"}]" > "$scratch/imports.json"
{ printf '%s\n' "$bot_import"; change cloudflare_zone_setting.email_obfuscation cloudflare_zone_setting '["forget"]' '{"setting_id":"email_obfuscation","value":"on"}' null null; } | reject "forgotten zone setting"
printf '%s\n' "[{\"address\":\"cloudflare_bot_management.primary\",\"id\":\"$zone\"},{\"address\":\"cloudflare_zone_setting.email_obfuscation\",\"id\":\"$zone/email_obfuscation\"}]" > "$scratch/imports.json"
{ printf '%s\n' "$bot_import" "$obfuscation_import"
  change cloudflare_zone_setting.rocket_loader cloudflare_zone_setting '["update"]' '{"setting_id":"rocket_loader","value":"off"}' '{"setting_id":"rocket_loader","value":"on"}' null; } | reject "update of an unlisted zone setting"
printf '%s\n' "$bot_import" | reject "missing zone-setting import"
printf '%s\n' "[{\"address\":\"cloudflare_dns_record.mail_mx_01\",\"id\":\"$import_id\"}]" > "$scratch/imports.json"
printf '%s\n' 'PASS: zone settings are imported, may be updated, and never created, forgotten or widened'

# 3c. A DNS record is deleted only as a reviewed retirement: a pure delete whose
# address, name, type and content .github/dns-retirements.json names, of a
# record external-dns does not own. Nothing else is ever deleted or replaced.
mx02='{"name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com","ttl":3600}'
retire_mx02=$(change cloudflare_dns_record.mail_mx_02 cloudflare_dns_record '["delete"]' "$mx02" null null)
entry='{"address":"cloudflare_dns_record.mail_mx_02","name":"devantler.tech","type":"MX","content":"mx02.mail.icloud.com"}'
listed() { jq -cn --argjson entry "$entry" "{retire:[\$entry | $1]}" > "$scratch/retirements.json"; }
printf '%s\n' "$noop_import" "$retire_mx02" | reject "unlisted retirement"
listed .
printf '%s\n' "$noop_import" "$retire_mx02" | plan | check
# The company Email cutover: mx01 moves in place and mx02 is retired.
printf '%s\n' '[]' > "$scratch/imports.json"
{ change cloudflare_dns_record.mail_mx_01 cloudflare_dns_record '["update"]' "$record" '{"name":"devantler.tech","type":"MX","content":"mail.devantler.tech","ttl":3600}' null
  printf '%s\n' "$retire_mx02"; } | plan | check
printf '%s\n' "[{\"address\":\"cloudflare_dns_record.mail_mx_01\",\"id\":\"$import_id\"}]" > "$scratch/imports.json"
for name in Devantler.Tech. @; do
  listed ".name=\"$name\""
  printf '%s\n' "$noop_import" "$retire_mx02" | plan | check
done
for edit in '.content="mx01.mail.icloud.com"' '.name="www.devantler.tech"' '.type="TXT"' '.address="cloudflare_dns_record.mail_mx_03"'; do
  listed "$edit"
  printf '%s\n' "$noop_import" "$retire_mx02" | reject "retirement that differs from its entry ($edit)"
done
listed .
for actions in '["delete","create"]' '["create","delete"]'; do
  { printf '%s\n' "$noop_import"; change cloudflare_dns_record.mail_mx_02 cloudflare_dns_record "$actions" "$mx02" "$mx02" null; } | reject "listed replacement $actions"
done
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.mail_mx_02 cloudflare_dns_record '["delete"]' null null null; } | reject "retirement without its prior record"
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.mail_mx_02 cloudflare_zone '["delete"]' "$mx02" null null; } | reject "listed address of a resource that is not a DNS record"
{ printf '%s\n' "$noop_import"; change cloudflare_zone.primary cloudflare_zone '["delete"]' '{"name":"devantler.tech"}' null null; } | reject "zone delete"
{ printf '%s\n' "$noop_import"; change 'cloudflare_r2_bucket.buckets["state"]' cloudflare_r2_bucket '["delete"]' '{"name":"state"}' null null; } | reject "bucket delete"
{ printf '%s\n' "$noop_import"; change cloudflare_zone_setting.nel cloudflare_zone_setting '["delete"]' '{"setting_id":"nel","value":"on"}' null null; } | reject "zone setting delete"
# A listed record that external-dns owns is never deleted here; one it does not own is.
printf '%s\n' '{"retire":[{"address":"cloudflare_dns_record.www","name":"www.devantler.tech","type":"CNAME","content":"pages.example.test"},
  {"address":"cloudflare_dns_record.portal","name":"portal.devantler.tech","type":"A","content":"192.0.2.1"}]}' > "$scratch/retirements.json"
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.www cloudflare_dns_record '["delete"]' "$www" null null; } | plan | check
{ printf '%s\n' "$noop_import"; change cloudflare_dns_record.portal cloudflare_dns_record '["delete"]' '{"name":"portal.devantler.tech","type":"A","content":"192.0.2.1"}' null null; } | reject "retirement of an external-dns record"
# A malformed list refuses every plan, like the handover list.
reject_list() {
  if printf '%s\n' "$noop_import" | plan | check 2> "$scratch/list-error"; then printf 'FAIL: retirement list %s was admitted\n' "$1" >&2; exit 1; fi
  grep -Fq 'dns-retirements: invalid list' "$scratch/list-error"
}
twenty=$(jq -cn --argjson entry "$entry" '{retire:([$entry] + [range(19)|{address:"cloudflare_dns_record.r\(.)",name:"r\(.).devantler.tech",type:"TXT",content:"x"}])}')
printf '%s\n' "$twenty" > "$scratch/retirements.json"
printf '%s\n' "$noop_import" "$retire_mx02" | plan | check
twenty_one=$(jq -c '.retire += [{address:"cloudflare_dns_record.r19",name:"r19.devantler.tech",type:"TXT",content:"x"}]' <<<"$twenty")
for list in "$twenty_one" '{"retire":[{"address":"cloudflare_dns_record.a","name":"devantler.tech","type":"mx","content":"x"}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"devantler.tech","type":"SRV","content":"x"}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"devantler.tech","type":"MX","content":""}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"devantler.tech","type":"MX","content":10}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"devantler.tech","type":"MX"}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"devantler.tech","type":"MX","content":"x","extra":1}]}' \
  '{"retire":[{"address":"cloudflare_zone.primary","name":"devantler.tech","type":"MX","content":"x"}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.records[\"x\"]","name":"devantler.tech","type":"MX","content":"x"}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"devantler tech","type":"MX","content":"x"}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"","type":"MX","content":"x"}]}' \
  '{"retire":[{"address":"cloudflare_dns_record.a","name":"a.devantler.tech","type":"A","content":"x"},{"address":"cloudflare_dns_record.a","name":"b.devantler.tech","type":"A","content":"y"}]}' \
  '{"retire":["cloudflare_dns_record.a"]}' '{"retire":{}}' '{"retire":[],"extra":1}' '{"other":[]}' '[]' '{"retire":[]} {"retire":[]}'; do
  printf '%s\n' "$list" > "$scratch/retirements.json"
  reject_list "$list"
done
printf '%s\n' 'not json' > "$scratch/retirements.json"
if printf '%s\n' "$noop_import" | plan | check 2>/dev/null; then printf 'FAIL: unparsable retirement list was admitted\n' >&2; exit 1; fi
# The repository's own list is valid, so a typo in it cannot stop every DNS run,
# and the apply passes it to both guards.
cp "$root/.github/dns-retirements.json" "$scratch/retirements.json"
printf '%s\n' "$noop_import" | plan | check
# shellcheck disable=SC2016 # The patterns are literal apply-dns.sh text.
{ grep -Fq 'retirements="$root/.github/dns-retirements.json"' "$root/scripts/apply-dns.sh"
  grep -Fq 'assert-no-destructive-plan.sh" "$scratch/evidence/change.json" "$retirements"' "$root/scripts/apply-dns.sh"
  grep -Fq -- '--slurpfile retirements "$retirements"' "$root/scripts/apply-dns.sh"; }
printf '%s\n' '{"retire":[]}' > "$scratch/retirements.json"
printf '%s\n' 'PASS: DNS records are deleted only as reviewed retirements, never replaced'

# 4. The declared mail records are the ones the company Email depends on.
grep -q 'content  = "mx01.mail.icloud.com"' "$root/dns.tf"
grep -q 'content  = "mx02.mail.icloud.com"' "$root/dns.tf"
if grep -q '"_externaldns.devantler.tech"' "$root/dns.tf"; then exit 1; fi
printf '%s\n' 'PASS: declared DNS keeps the Email records and never the typeless apex registry'
