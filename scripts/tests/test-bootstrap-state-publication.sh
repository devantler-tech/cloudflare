#!/usr/bin/env bash
# Exercise native ciphertext packaging with a network-free GitHub boundary.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat > "$scratch/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
test -z "${CLOUDFLARE_API_TOKEN+x}"
printf '%s\n' "$*" >> "$MOCK_ROOT/calls"
if [[ ${MOCK_CASE:-} == api-error ]]; then exit 1; fi
input=${!#}
case "$*" in
  *graphql*)
    cp "$input" "$MOCK_ROOT/graphql.json"
    printf '%s\n' 2222222222222222222222222222222222222222 > "$MOCK_ROOT/head"
    printf '%s\n' '{"data":{"createCommitOnBranch":{"commit":{"oid":"2222222222222222222222222222222222222222"}}}}'
    ;;
  *'/git/commits/'*)
    jq -n --argjson verified "$(if [[ ${MOCK_CASE:-} == unsigned ]]; then echo false; else echo true; fi)" \
      '{sha:"2222222222222222222222222222222222222222",parents:[{sha:"1111111111111111111111111111111111111111"}],verification:{verified:$verified,reason:"valid"}}'
    ;;
  *'/git/ref/heads/'*)
    head=$(cat "$MOCK_ROOT/head")
    if [[ ${MOCK_CASE:-} == stale ]]; then head=3333333333333333333333333333333333333333; fi
    jq -n --arg sha "$head" '{object:{sha:$sha}}'
    ;;
  *'/git/ref/tags/'*) printf '%s\n' '{"object":{"sha":"2222222222222222222222222222222222222222"}}' ;;
  *'/actions/runs/'*)
    jq -n --arg conclusion "$(if [[ ${MOCK_CASE:-} == failed-canary ]]; then echo failure; else echo success; fi)" '{id:123456789,head_sha:"1111111111111111111111111111111111111111",head_branch:"main",event:"workflow_dispatch",path:".github/workflows/state-bootstrap-apply.yaml",actor:{login:"devantler"},run_attempt:1,status:"completed",conclusion:$conclusion}'
    ;;
  *'/contents/'*)
    path=${3#repos/devantler-tech/cloudflare/contents/}
    # --method GET precedes the endpoint in the production invocation.
    for argument in "$@"; do
      if [[ $argument == repos/devantler-tech/cloudflare/contents/* ]]; then path=${argument#repos/devantler-tech/cloudflare/contents/}; fi
    done
    jq --arg path "$path" '.variables.input.fileChanges.additions[]|select(.path==$path)|{encoding:"base64",type:"file",size:100,content:.contents}' "$MOCK_ROOT/graphql.json"
    ;;
  *'/git/refs'*)
    if [[ ${MOCK_CASE:-} == tag-error && $(jq -r .ref "$input") == refs/tags/*-result ]]; then exit 1; fi
    jq '{ref,object:{sha:.sha}}' "$input"
    ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" MOCK_ROOT="$scratch"
export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR=devantler GITHUB_RUN_ATTEMPT=1 RUNNER_ENVIRONMENT=github-hosted
export GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/state-bootstrap-apply.yaml@refs/heads/main
export GITHUB_RUN_ID=123456789 GITHUB_SHA=1111111111111111111111111111111111111111 GH_TOKEN=SYNTHETIC_TOKEN CLOUDFLARE_API_TOKEN=SYNTHETIC_PROVIDER_TOKEN
export BOOTSTRAP_MODE=check BOOTSTRAP_APPLY_EXIT=0 BOOTSTRAP_PLAN_EXIT=0
publish() { bash "$root/scripts/publish-bootstrap-state.sh" "$root" "$root/recovery/state" "$1"; }
publish checkpoint > "$scratch/stdout" 2> "$scratch/stderr"
printf '%s\n' "$GITHUB_SHA" > "$scratch/head"
publish result > "$scratch/stdout" 2> "$scratch/stderr"
jq -e '.variables.input.expectedHeadOid=="1111111111111111111111111111111111111111" and .variables.input.branch.repositoryNameWithOwner=="devantler-tech/cloudflare" and .variables.input.branch.branchName=="recovery/cloudflare-state-123456789" and (.variables.input.fileChanges.deletions // []|length)==0 and ([.variables.input.fileChanges.additions[].path]|sort)==[".github/recovery-receipts/state-bootstrap.json","recovery/state/configuration.json.age","recovery/state/manifest.json","recovery/state/state.json.age"]' "$scratch/graphql.json" >/dev/null
for file in manifest.json state.json.age configuration.json.age; do
  jq -r --arg path "recovery/state/$file" '.variables.input.fileChanges.additions[]|select(.path==$path)|.contents' "$scratch/graphql.json" | base64 --decode > "$scratch/returned"
  cmp "$scratch/returned" "$root/recovery/state/$file"
done
if grep -q SYNTHETIC_TOKEN "$scratch/stdout" "$scratch/stderr" "$scratch/calls" "$scratch/graphql.json"; then exit 1; fi
export CUSTODY_RUN=123456789 GITHUB_RUN_ID=987654321 BOOTSTRAP_MODE=apply
publish verify > "$scratch/stdout" 2> "$scratch/stderr"
export MOCK_CASE=failed-canary
if publish verify > "$scratch/stdout" 2> "$scratch/stderr"; then exit 1; fi
unset MOCK_CASE
export GITHUB_RUN_ID=123456789 BOOTSTRAP_MODE=check
for failure in unsigned stale api-error tag-error; do
  export MOCK_CASE=$failure
  printf '%s\n' "$GITHUB_SHA" > "$scratch/head"
  if publish result > "$scratch/stdout" 2> "$scratch/stderr"; then printf 'FAIL: accepted %s\n' "$failure" >&2; exit 1; fi
  if grep -q 'CLOUDFLARE_STATE_PUBLICATION=VERIFIED' "$scratch/stdout"; then exit 1; fi
done
unset MOCK_CASE
export GITHUB_REF=refs/heads/unreviewed
: > "$scratch/calls"
if publish checkpoint > "$scratch/stdout" 2> "$scratch/stderr"; then exit 1; fi
test ! -s "$scratch/calls"
export GITHUB_REF=refs/heads/main CONFIRMATION=CHECK_STATE_CUSTODY BOOTSTRAP_MODE=check OUTPUT_DIR="$scratch/driver-result"
printf '%s\n' "$GITHUB_SHA" > "$scratch/head"
bash "$root/scripts/apply-state-bootstrap.sh" "$root" > "$scratch/stdout" 2> "$scratch/stderr"
grep -q 'CLOUDFLARE_BOOTSTRAP_APPLY=VERIFIED mode=check provider_writes=0' "$scratch/stdout"
for file in manifest.json state.json.age configuration.json.age; do cmp "$OUTPUT_DIR/state/$file" "$root/recovery/state/$file"; done
export BOOTSTRAP_MODE=apply
: > "$scratch/calls"
if bash "$root/scripts/apply-state-bootstrap.sh" "$root" > "$scratch/stdout" 2> "$scratch/stderr"; then exit 1; fi
test ! -s "$scratch/calls"
printf '%s\n' 'PASS: ciphertext-only recovery publication refuses unsigned, moved and incomplete custody'
