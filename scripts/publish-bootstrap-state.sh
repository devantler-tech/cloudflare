#!/usr/bin/env bash
# Publish fixed ciphertext files; GitHub signs the API-created data commit.
set -euo pipefail
set +x
umask 077
unset CLOUDFLARE_API_TOKEN CLOUDFLARE_BOOTSTRAP_APPROVED_DATA GH_HOST GH_ENTERPRISE_HOST GH_ENTERPRISE_TOKEN GH_DEBUG GH_FORCE_TTY
# Keep API response bodies and publication payloads out of the public receipt.
fail() { printf 'CLOUDFLARE_STATE_PUBLICATION=UNVERIFIED stage=%s\n' "$1" >&2; exit 2; }
[[ $# == 3 ]] || fail arguments
root=$1 package=$2 phase=$3
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/main && ${GITHUB_REPOSITORY:-} == devantler-tech/cloudflare && ${GITHUB_ACTOR:-} == devantler && ${GITHUB_RUN_ATTEMPT:-} == 1 && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${GITHUB_WORKFLOW_REF:-} == devantler-tech/cloudflare/.github/workflows/state-bootstrap-apply.yaml@refs/heads/main ]] || fail dispatch
[[ ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{6,19}$ && -n ${GH_TOKEN:-} ]] || fail identity
[[ $phase == checkpoint || $phase == result || $phase == verify ]] || fail phase
[[ ${BOOTSTRAP_MODE:-} == check || ${BOOTSTRAP_MODE:-} == apply ]] || fail mode
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/state-recovery-common.sh
source "$script_dir/state-recovery-common.sh"
bash "$script_dir/check-state-recovery-package.sh" "$root" "$package" >/dev/null 2>&1 || fail recovery-package
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GH_CONFIG_DIR="$scratch/gh" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER=cat
mkdir -m 700 "$GH_CONFIG_DIR"
branch="recovery/cloudflare-state-$GITHUB_RUN_ID"
tag="refs/tags/cloudflare-state-$GITHUB_RUN_ID"
# Read a fixed recovery path at an immutable commit into the caller's private file.
# Arguments are repository path, local destination and full commit identity.
readback_file() {
  gh api --method GET "repos/devantler-tech/cloudflare/contents/$1" -f "ref=$3" > "$scratch/readback.json" 2> "$scratch/api.err" || fail readback
  jq -e '.encoding=="base64" and .type=="file" and (.size|type=="number" and .>=0 and .<=262144)' "$scratch/readback.json" >/dev/null 2>&1 || fail readback-format
  jq -r .content "$scratch/readback.json" | base64 --decode > "$2" 2>/dev/null || fail readback-encoding
}
# Require a verified GitHub signature and exactly the reviewed source as parent.
verify_commit() {
  gh api "repos/devantler-tech/cloudflare/git/commits/$1" > "$scratch/commit.json" 2> "$scratch/api.err" || fail signature-read
  jq -e --arg commit "$1" --arg parent "$GITHUB_SHA" '.sha==$commit and .verification.verified==true and .verification.reason=="valid" and ([.parents[].sha]==[$parent])' "$scratch/commit.json" >/dev/null 2>&1 || fail signed-commit
}
if [[ $phase == verify ]]; then
  [[ $BOOTSTRAP_MODE == apply && ${CUSTODY_RUN:-} =~ ^[1-9][0-9]{6,19}$ && $CUSTODY_RUN != "$GITHUB_RUN_ID" ]] || fail custody-run
  gh api "repos/devantler-tech/cloudflare/actions/runs/$CUSTODY_RUN" > "$scratch/run.json" 2> "$scratch/api.err" || fail custody-run-read
  jq -e --arg run "$CUSTODY_RUN" --arg source "$GITHUB_SHA" '(.id|tostring)==$run and .head_sha==$source and .head_branch=="main" and .event=="workflow_dispatch" and .path==".github/workflows/state-bootstrap-apply.yaml" and .actor.login=="devantler" and .run_attempt==1 and .status=="completed" and .conclusion=="success"' "$scratch/run.json" >/dev/null 2>&1 || fail custody-run-binding
  gh api "repos/devantler-tech/cloudflare/git/ref/tags/cloudflare-state-$CUSTODY_RUN-result" > "$scratch/tag.json" 2> "$scratch/api.err" || fail custody-tag
  commit=$(jq -er '.object.sha|select(type=="string" and test("^[a-f0-9]{40}$"))' "$scratch/tag.json" 2>/dev/null) || fail custody-commit
  verify_commit "$commit"
  readback_file .github/recovery-receipts/state-bootstrap.json "$scratch/receipt.json" "$commit"
  state_unique_json "$scratch/receipt.json" || fail custody-receipt
  jq -e --arg source "$GITHUB_SHA" --arg run "$CUSTODY_RUN" '.schemaVersion==1 and .kind=="cloudflare-state-bootstrap-custody" and .sourceCommit==$source and .sourceRun==$run and .mode=="check" and .applyExitCode==0 and .convergenceExitCode==0' "$scratch/receipt.json" >/dev/null 2>&1 || fail custody-receipt
  for file in manifest.json state.json.age configuration.json.age; do
    readback_file "recovery/state/$file" "$scratch/readback" "$commit"
    cmp -s "$package/$file" "$scratch/readback" || fail custody-generation
  done
  printf 'CLOUDFLARE_STATE_PUBLICATION=CUSTODY_VERIFIED source_run=%s\n' "$CUSTODY_RUN"
  exit 0
fi
# Reserve a new ref at the exact commit; never update or adopt an existing ref.
create_ref() {
  jq -n --arg ref "$1" --arg sha "$2" '{ref:$ref,sha:$sha}' > "$scratch/ref-input.json"
  gh api --method POST repos/devantler-tech/cloudflare/git/refs --input "$scratch/ref-input.json" > "$scratch/ref-response.json" 2> "$scratch/api.err" || fail create-ref
  jq -e --arg ref "$1" --arg sha "$2" '.ref==$ref and .object.sha==$sha' "$scratch/ref-response.json" >/dev/null 2>&1 || fail ref-binding
}
if [[ $phase == checkpoint ]]; then
  # Neither existing refs nor a retried invocation may be adopted or overwritten.
  create_ref "refs/heads/$branch" "$GITHUB_SHA"
  create_ref "$tag-before" "$GITHUB_SHA"
  printf '%s\n' 'CLOUDFLARE_STATE_PUBLICATION=CHECKPOINTED provider_writes=0'
  exit 0
fi
[[ ${BOOTSTRAP_APPLY_EXIT:-} =~ ^[0-9]{1,3}$ && ${BOOTSTRAP_PLAN_EXIT:-} =~ ^[0-9]{1,3}$ ]] || fail result
gh api "repos/devantler-tech/cloudflare/git/ref/heads/$branch" > "$scratch/head.json" 2> "$scratch/api.err" || fail branch-read
jq -e --arg sha "$GITHUB_SHA" '.object.sha==$sha' "$scratch/head.json" >/dev/null 2>&1 || fail moved-branch
jq -n --arg source "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg mode "$BOOTSTRAP_MODE" --argjson apply "$BOOTSTRAP_APPLY_EXIT" --argjson plan "$BOOTSTRAP_PLAN_EXIT" \
  '{schemaVersion:1,kind:"cloudflare-state-bootstrap-custody",sourceCommit:$source,sourceRun:$run,mode:$mode,applyExitCode:$apply,convergenceExitCode:$plan}' > "$scratch/receipt.json"
printf '[]\n' > "$scratch/additions.json"
for file in manifest.json state.json.age configuration.json.age receipt.json; do
  local_file="$package/$file" destination="recovery/state/$file"
  if [[ $file == receipt.json ]]; then local_file="$scratch/receipt.json"; destination=.github/recovery-receipts/state-bootstrap.json; fi
  [[ -f "$local_file" && ! -L "$local_file" && $(wc -c < "$local_file") -le 262144 ]] || fail file
  base64 < "$local_file" > "$scratch/content.base64"
  jq --arg path "$destination" --rawfile contents "$scratch/content.base64" '.+[{path:$path,contents:($contents|gsub("\n";""))}]' "$scratch/additions.json" > "$scratch/next.json"
  mv "$scratch/next.json" "$scratch/additions.json"
done
jq -n --arg branch "$branch" --arg sha "$GITHUB_SHA" --slurpfile additions "$scratch/additions.json" \
  '{query:"mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}",variables:{input:{branch:{repositoryNameWithOwner:"devantler-tech/cloudflare",branchName:$branch},expectedHeadOid:$sha,message:{headline:"chore(recovery): retain the bootstrap state generation",body:"> 🤖 Generated by the Agentic Engineer"},fileChanges:{additions:$additions[0]}}}}' > "$scratch/commit-input.json"
gh api graphql --input "$scratch/commit-input.json" > "$scratch/commit-response.json" 2> "$scratch/api.err" || fail commit
jq -e '((.errors // [])|length)==0 and (.data.createCommitOnBranch.commit.oid|type=="string" and test("^[a-f0-9]{40}$"))' "$scratch/commit-response.json" >/dev/null 2>&1 || fail commit-response
commit=$(jq -r .data.createCommitOnBranch.commit.oid "$scratch/commit-response.json")
verify_commit "$commit"
gh api "repos/devantler-tech/cloudflare/git/ref/heads/$branch" > "$scratch/head.json" 2> "$scratch/api.err" || fail branch-read
jq -e --arg sha "$commit" '.object.sha==$sha' "$scratch/head.json" >/dev/null 2>&1 || fail moved-branch
for file in manifest.json state.json.age configuration.json.age receipt.json; do
  local_file="$package/$file" destination="recovery/state/$file"
  if [[ $file == receipt.json ]]; then local_file="$scratch/receipt.json"; destination=.github/recovery-receipts/state-bootstrap.json; fi
  readback_file "$destination" "$scratch/readback" "$commit"
  cmp -s "$local_file" "$scratch/readback" || fail readback-bytes
done
# The immutable result tag keeps the generation reachable after branch cleanup.
create_ref "$tag-result" "$commit"
printf 'CLOUDFLARE_STATE_PUBLICATION=VERIFIED commit=%s\n' "$commit"
