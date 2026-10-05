#!/usr/bin/env bash
# Exercise the released validator against the real consumer and disposable defects.
set -euo pipefail
validator="${1:?pass the released validator binary}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$validator" --root "$root" --config .github/retired-repo-links.json
mkdir -p "$work/fixture/.github"
cp "$root/README.md" "$root/AGENTS.md" "$work/fixture/"
cp "$root/.github/retired-repo-links.json" "$work/fixture/.github/retired-repo-links.json"
for file in README.md AGENTS.md; do
  printf '\n[Retired catalogue](https://github.com/devantler-tech/reusable-workflows)\n' >> "$work/fixture/$file"
  status=0
  "$validator" --root "$work/fixture" --config .github/retired-repo-links.json > "$work/retired.log" 2>&1 || status=$?
  cat "$work/retired.log"
  [[ "$status" == 1 ]] || { echo "FAIL: retired $file link did not fail as a link defect"; exit 1; }
  grep -E "^${file//./\\.}:[0-9]+: link targets retired repository devantler-tech/reusable-workflows$" "$work/retired.log"
  cp "$root/$file" "$work/fixture/$file"
done
status=0
"$validator" --root "$root" --config .github/missing-retired-repo-links.json > "$work/missing.log" 2>&1 || status=$?
cat "$work/missing.log"
[[ "$status" == 2 ]] || { echo 'FAIL: missing configuration did not fail closed'; exit 1; }
grep -F 'Invalid configuration: cannot inspect' "$work/missing.log"
echo 'PASS: clean consumer, retired README and instruction defects, and missing configuration'
