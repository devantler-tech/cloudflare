# Input: the saved plan JSON. $imports[0]: the resolved import list.
# $snapshot[0]: the live zone. Names are compared in their full, lower-case
# form, so a relative or differently written name cannot slip by.
# Only DNS records may change. Nothing is deleted or replaced. Every import is
# known and leaves its record exactly as it is. A created or updated record
# has a known name and an upper-case type, and external-dns owns it neither
# before nor after the change. Its name uses only hostname characters. An
# external-dns ownership record must claim at least one live record. Every live
# record it claims must be one this plan stops managing, or one that nothing
# here manages and that the reviewed $handover[0] list (.github/dns-handover.json)
# names. Otherwise it could hand a mail record, or any other record, to
# external-dns, which would delete it. The typeless apex registry name is always refused,
# because it claims every apex record, the Email MX and TXT records included.
#
# Besides DNS records, only the zone settings declared in zone.tf may change:
# the bot management configuration and the zone settings listed below. They
# always exist, so they are imported, never created, and may be updated by the
# reviewed change that imports them.
def zone_settings: ["email_obfuscation"];
def setting: .type=="cloudflare_bot_management" or
  (.type=="cloudflare_zone_setting" and (((.change.after // .change.before // {}).setting_id // "")|IN(zone_settings[])));
def fqdn: ascii_downcase | rtrimstr(".") |
  if .=="@" then "devantler.tech"
  elif .=="devantler.tech" or endswith(".devantler.tech") then .
  else .+".devantler.tech" end;
def changed: (.change.before != .change.after) or any(.change.after_unknown|..; .==true);
def owned($records):
  (.name|fqdn) as $name | (.type|ascii_downcase) as $type |
  any($records[]; (.name|fqdn) as $marker |
    .type=="TXT" and ($marker=="_externaldns."+$name or $marker=="_externaldns."+$type+"-"+$name));
# Every (name, type) an ownership record could claim, read both typed and typeless.
def claims:
  (.name|fqdn|ltrimstr("_externaldns.")) as $rest |
  [{name:$rest, type:null}] +
  [$rest|capture("^(?<type>[a-z0-9]+)-(?<name>.+)$")|{name, type}];
def hits($claim): (.name|fqdn)==$claim.name and ($claim.type==null or (.type|ascii_downcase)==$claim.type);
def writes: .change.actions==["create"] or .change.actions==["update"];
. as $plan | $imports[0] as $wanted | $snapshot[0].records as $live |
($handover[0] | if type=="object" and keys==["externalDnsHandover"] and (.externalDnsHandover|type=="array" and length<=20) and
   all(.externalDnsHandover[]; type=="object" and keys==["name","type"] and (.type|IN("A","AAAA","CNAME")) and
     (.name|type=="string" and test("\\A[A-Za-z0-9.-]+\\z")))
 then [.externalDnsHandover[] | {name:(.name|fqdn), type:(.type|ascii_downcase)}]
 else error("dns-handover: invalid list") end) as $listed |
[.resource_changes[] | select(.type=="cloudflare_dns_record" and .change.actions!=["forget"]) |
  .change.after // .change.before | select(type=="object") |
  {name:(.name // "" | fqdn), type:(.type // "" | ascii_downcase)}] as $kept |
[.resource_changes[] | select(.type=="cloudflare_dns_record" and .change.actions==["forget"]) | .change.before.id // empty] as $forgotten |
.errored!=true and
((.deferred_changes // [])|length)==0 and
(.resource_changes|type=="array") and
($wanted|type=="array") and ($live|type=="array") and
(($wanted|map(.address)|length)==($wanted|map(.address)|unique|length)) and
all($wanted[];
  . as $import |
  [$plan.resource_changes[]|select(.address==$import.address)] as $matches |
  ($matches|length)==1 and $matches[0].change.importing.id==$import.id) and
all(.resource_changes[];
  . as $resource |
  .mode=="managed" and
  (.change.actions|IN(["no-op"],["create"],["update"],["forget"])) and
  (if .change.importing then
     any($wanted[]; .address==$resource.address) and
     (if setting then .change.actions|IN(["no-op"],["update"]) else .change.actions==["no-op"] and (changed|not) end)
   else true end) and
  (if setting then .change.actions|IN(["no-op"],["update"])
   elif .type!="cloudflare_dns_record" then .change.actions==["no-op"]
   elif writes then
     .change.after as $after |
     ($after.name|type=="string") and ($after.type|type=="string") and
     ($after.name|test("\\A[A-Za-z0-9_.*@-]+\\z")) and
     $after.type==($after.type|ascii_upcase) and
     ($after.name|fqdn) != "_externaldns.devantler.tech" and
     (if .change.actions==["update"] then (.change.before|owned($live)|not) else true end) and
     (if ($after.type=="TXT" and ($after.name|fqdn|startswith("_externaldns."))) then
        ($after|claims) as $claims |
        [$live[] | . as $r | select(any($claims[]; . as $c | $r|hits($c)))] as $claimed |
        ($claimed|length)>0 and
        all($claimed[]; (.id|IN($forgotten[])) or
          ({name:(.name|fqdn), type:(.type|ascii_downcase)} as $record |
            ($record|IN($listed[])) and ($after.name|fqdn)=="_externaldns."+$record.type+"-"+$record.name)) and
        all($claims[]; . as $claim |
          all($kept[]; .name!=$claim.name or ($claim.type!=null and .type!=$claim.type)))
      else ($after|owned($live)|not) end)
   else true end))
