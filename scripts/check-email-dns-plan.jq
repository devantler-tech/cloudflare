# A proposal may import existing objects locally; every provider action must be
# known and unchanged. Extra, missing, duplicate and deferred objects are HOLD.
def type_for($address):
 if $address=="cloudflare_zone.primary" then "cloudflare_zone"
 elif $address=="cloudflare_r2_bucket.buckets[\"cloudflare-bootstrap-state\"]" then "cloudflare_r2_bucket"
 elif ($address|test("^cloudflare_dns_record\\.records\\[\\\"email_[a-f0-9]{32}\\\"\\]$")) then "cloudflare_dns_record"
 else "refused" end;
def valid_import:
 type_for(.address) as $type |
 if $type=="cloudflare_zone" then (.id|test("^[a-f0-9]{32}$"))
 elif $type=="cloudflare_r2_bucket" then (.id|test("^[a-f0-9]{32}/cloudflare-bootstrap-state/default$"))
 elif $type=="cloudflare_dns_record" then (.id|test("^[a-f0-9]{32}/[a-f0-9]{32}$"))
 else false end;
. as $plan | $wanted[0] as $imports |
.errored!=true and
((.deferred_changes // [])|length)==0 and
((.resource_drift // [])|length)==0 and
($imports|type=="array" and length>=7 and length<=32) and
all($imports[];valid_import) and
(($imports|map(.address)|length)==($imports|map(.address)|unique|length)) and
(.resource_changes|type=="array") and
((.resource_changes|map(.address)|sort)==($imports|map(.address)|sort)) and
all(.resource_changes[];
 . as $resource |
 ([$imports[]|select(.address==$resource.address)]) as $expected |
 ($expected|length)==1 and
 .mode=="managed" and .type==type_for(.address) and
 .change.actions==["no-op"] and .change.before==.change.after and
 (any(.change.after_unknown|..; .==true)|not) and
 .change.after.id==(
  if .type=="cloudflare_zone" then $expected[0].id
  else ($expected[0].id|split("/")[1]) end
 ))
