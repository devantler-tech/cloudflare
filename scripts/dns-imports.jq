# Input: a plan JSON made before imports. $snapshot[0]: the complete live zone.
# A declared record the plan would create is imported when exactly one live
# record has the same name, type and content. It stays a create only when no
# live record has that name and type. Anything else is refused, so a typo or
# drift can never add a second mail record or take over an external-dns record.
def registry: .type=="TXT" and (.name|startswith("_externaldns."));
def owned($records):
  . as $r | any($records[];
    .type=="TXT" and
    (.name=="_externaldns."+$r.name or .name=="_externaldns."+($r.type|ascii_downcase)+"-"+$r.name));
$snapshot[0] as $live |
[.resource_changes[] |
  select(.mode=="managed" and .type=="cloudflare_dns_record" and .change.actions==["create"]) |
  .change.after as $after |
  [$live.records[] | select(.name==$after.name and .type==$after.type)] as $same |
  [$same[] | select(.content==$after.content)] as $exact |
  if ($exact|length)==1 then
    if ($exact[0]|registry) or ($exact[0]|owned($live.records)) then {address, refused:"external-dns-owned"}
    else {address, id:($live.zone.id+"/"+$exact[0].id)} end
  elif ($exact|length)>1 then {address, refused:"ambiguous"}
  elif ($same|length)>0 then {address, refused:"content-differs"}
  else empty end
] as $resolved |
([$resolved[]|select(has("id"))|.id]) as $ids |
{
  imports:[$resolved[]|select(has("id"))]|sort_by(.address),
  refused:([$resolved[]|select(has("refused"))] +
    (if ($ids|length)==($ids|unique|length) then [] else [{address:"*",refused:"duplicate-target"}] end))
}
