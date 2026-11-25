#!/usr/bin/env sh
# Refuses every delete and replacement in a saved OpenTofu plan (JSON).
#
# The optional second argument is the reviewed retirement list
# (.github/dns-retirements.json). With it, a pure delete (actions exactly
# ["delete"]) of a managed DNS record is admitted when the list names its
# address, and its name, type and content before the change equal the listed
# entry. Every other delete, every replacement, and every delete of a resource
# that is not a DNS record stays refused. A malformed list refuses the plan.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <tofu-plan.json> [dns-retirements.json]" >&2
  exit 2
fi

plan_json=$1
if [ ! -f "$plan_json" ]; then
  echo "ERROR: plan JSON does not exist: $plan_json" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi
if ! jq -e '.resource_changes | type == "array"' "$plan_json" >/dev/null 2>&1; then
  echo "ERROR: input is not an OpenTofu plan JSON with resource_changes" >&2
  exit 2
fi

# The list shape and name normalisation match scripts/check-dns-plan.jq.
# shellcheck disable=SC2016 # jq variables, expanded by jq.
filters='
def fqdn: ascii_downcase | rtrimstr(".") |
  if .=="@" then "devantler.tech"
  elif .=="devantler.tech" or endswith(".devantler.tech") then .
  else .+".devantler.tech" end;
def valid: length==1 and (.[0] | type=="object" and keys==["retire"] and
  (.retire | type=="array" and length<=20 and
    all(.[]; type=="object" and keys==["address","content","name","type"] and
      (.address|type=="string" and test("\\Acloudflare_dns_record\\.[A-Za-z_][A-Za-z0-9_-]*\\z")) and
      (.name|type=="string" and test("\\A[A-Za-z0-9_.*@-]+\\z")) and
      (.type|IN("A","AAAA","CNAME","MX","TXT")) and
      (.content|type=="string" and length>0)) and
    (map(.address)|length)==(map(.address)|unique|length)));
def retired($retire):
  .change.before as $before | .address as $address |
  .change.actions==["delete"] and .mode=="managed" and .type=="cloudflare_dns_record" and
  ($before|type=="object") and ($before.name|type=="string") and
  ($before.type|type=="string") and ($before.content|type=="string") and
  any($retire[]; .address==$address and (.name|fqdn)==($before.name|fqdn) and
    .type==($before.type|ascii_upcase) and .content==$before.content);
'

if [ "$#" -eq 2 ]; then
  retirements=$2
  if [ ! -f "$retirements" ] ||
    ! jq -n -e --slurpfile list "$retirements" "$filters"'$list | valid' >/dev/null 2>&1; then
    echo "ERROR: the DNS retirement list is invalid: $retirements" >&2
    exit 2
  fi
  set -- --slurpfile list "$retirements"
else
  retirements=''
  set -- --argjson list '[{"retire":[]}]'
fi

tmp_file=${TMPDIR:-/tmp}/cloudflare-destructive-plan.$$
trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

jq -r "$@" "$filters"'
  .resource_changes[]
  | select(any(.change.actions[]; . == "delete"))
  | select(retired($list[0].retire) | not)
  | "\(.address): \(.change.actions | join(","))"
' "$plan_json" >"$tmp_file"

if [ -s "$tmp_file" ]; then
  echo "ERROR: destructive OpenTofu changes are forbidden:" >&2
  cat "$tmp_file" >&2
  exit 1
fi

if [ -z "$retirements" ]; then
  echo "OpenTofu plan contains 0 destructive resource changes"
  exit 0
fi
count=$(jq "$@" "$filters"'[.resource_changes[] | select(retired($list[0].retire))] | length' "$plan_json")
echo "OpenTofu plan contains 0 destructive resource changes besides $count reviewed DNS record retirement(s)"
