# Input: the saved plan JSON. $imports[0]: the resolved import list. Names are
# compared in their full, lower-case form, so a relative name cannot slip by.
# Only DNS records may change. Nothing is deleted or replaced. Every import is
# known and leaves its record exactly as it is. The typeless apex registry name
# is refused outright: external-dns would read it as owning the apex mail
# records and delete them.
def fqdn: ascii_downcase | rtrimstr(".") |
  if .=="@" then "devantler.tech"
  elif .=="devantler.tech" or endswith(".devantler.tech") then .
  else .+".devantler.tech" end;
def changed: (.change.before != .change.after) or any(.change.after_unknown|..; .==true);
. as $plan | $imports[0] as $wanted |
.errored!=true and
((.deferred_changes // [])|length)==0 and
(.resource_changes|type=="array") and
($wanted|type=="array") and
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
     any($wanted[]; .address==$resource.address) and .change.actions==["no-op"] and (changed|not)
   else true end) and
  (if .type=="cloudflare_dns_record" then
     (((.change.after // {}).name // "")|fqdn) != "_externaldns.devantler.tech"
   else .change.actions==["no-op"] end))
