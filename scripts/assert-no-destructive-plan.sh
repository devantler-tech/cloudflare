#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <tofu-plan.json>" >&2
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

tmp_file=${TMPDIR:-/tmp}/cloudflare-destructive-plan.$$
trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

jq -r '
  .resource_changes[]
  | select(any(.change.actions[]; . == "delete"))
  | "\(.address): \(.change.actions | join(","))"
' "$plan_json" >"$tmp_file"

if [ -s "$tmp_file" ]; then
  echo "ERROR: destructive OpenTofu changes are forbidden:" >&2
  cat "$tmp_file" >&2
  exit 1
fi

echo "OpenTofu plan contains 0 destructive resource changes"
