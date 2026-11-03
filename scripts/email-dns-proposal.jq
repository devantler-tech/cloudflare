# Input is a bounded complete snapshot; the caller authenticates its revision
# and freshness. This filter preserves values and refuses competing ownership.
def identifier: type=="string" and test("^[a-f0-9]{32}$");
def integer: type=="number" and .==floor;
def text_value: type=="string" and length>0 and length<=8192 and (test("[[:cntrl:]]")|not);
def unquote: ltrimstr("\"") | rtrimstr("\"");
def spf: .type=="TXT" and (.content|type=="string") and (.content|unquote|ascii_downcase|startswith("v=spf1 "));
def apple: .type=="TXT" and (.content|type=="string") and (.content|unquote|startswith("apple-domain="));
def dkim($zone):
 (.type=="CNAME" or .type=="TXT") and
 (.name|endswith("._domainkey."+$zone)) and
 (.name|rtrimstr("._domainkey."+$zone)|test("^[a-z0-9_-]{1,63}$"));
def email($zone):
 (.name==$zone and (.type=="MX" or spf or apple)) or
 (.name=="_dmarc."+$zone and .type=="TXT") or dkim($zone);
def record_shape:
 (.id|identifier) and (.content|text_value) and
 (.ttl|integer and (.==1 or (.>=30 and .<=86400))) and
 .proxied==false and
 (.priority==null or (.priority|integer and .>=0 and .<=65535)) and
 (if .type=="MX" then .priority!=null else .priority==null end) and
 (.comment==null or (.comment|type=="string" and length<=1024)) and
 ((.tags // [])|type=="array" and length<=100 and
   all(.[];type=="string" and length<=200) and (length==(unique|length))) and
 ((.settings // {})|type=="object" and
   ((keys-["flatten_cname","ipv4_only","ipv6_only"])|length)==0 and
   all(.[];type=="boolean")) and
 (.private_routing==null or (.private_routing|type=="boolean")) and
 (.data==null or .data=={}) and
 ((.meta // {})|type=="object");
def free_of_controller:
 ((.tags // [])|all(.[];(test("external-dns";"i")|not))) and
 ((.comment // "")|test("external-dns";"i")|not) and
 ((.meta // {}) as $meta |
   all(["auto_added","managed_by_apps","managed_by_argo_tunnel"][];
     . as $key | ($meta[$key]==null or $meta[$key]==false)));
. as $snapshot |
if .schema!=1 or .source_revision!=$revision or
  ($revision|test("^[a-f0-9]{40}$")|not) or
  .zone.name!=$zone or .zone.status!="active" or
  (.zone.id|identifier|not) or (.zone.account.id|identifier|not) or
  (.records|type!="array" or length<1 or length>10000) or
  ((.records|length)!=(.records|map(.id)|unique|length)) or
  (all(.records[];(.id|identifier) and (.name|type=="string") and
    (.name==$zone or (.name|endswith("."+$zone))) and (.type|type=="string"))|not)
then error("email-dns-proposal-refused")
else
 [.records[]|select(email($zone))] as $selected |
 if ($selected|length)<5 or ($selected|length)>30 or
   (all($selected[];record_shape and free_of_controller)|not) or
   ([$selected[]|select(.type=="MX")]|length)<1 or
   ([$selected[]|select(spf)]|length)!=1 or
   ([$selected[]|select(apple)]|length)!=1 or
   ([$selected[]|select(.name=="_dmarc."+$zone)]|length)!=1 or
   ([$selected[]|select(dkim($zone))]|length)<1 or
   (([$selected[]|{name,type,content,priority}]|unique|length)!=($selected|length)) or
   (all($selected[];
     . as $candidate |
     any($snapshot.records[];
       .type=="TXT" and
       (.name=="_externaldns."+$candidate.name or
        .name=="_externaldns."+($candidate.type|ascii_downcase)+"-"+$candidate.name))|not)|not)
 then error("email-dns-proposal-refused")
 else
  {
   dns_records:(reduce $selected[] as $r ({}; .["email_"+$r.id]={
    name:$r.name,type:$r.type,content:$r.content,ttl:$r.ttl,
    proxied:$r.proxied,priority:$r.priority,comment:$r.comment,
    tags:($r.tags // []),settings:($r.settings // {}),private_routing:$r.private_routing
   })),
   imports:([$selected[]|{address:("cloudflare_dns_record.records["+("email_"+.id|tojson)+"]"),id:($snapshot.zone.id+"/"+.id)}]|sort_by(.address))
  }
 end
end
