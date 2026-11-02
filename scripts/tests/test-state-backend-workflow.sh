#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/parse"
expression=$(jq -nr --arg path "$root/.github/workflows/state-backend-proof.yaml" '"jsonencode(yamldecode(file("+($path|tojson)+")))"')
printf '%s\n' "$expression" | tofu -chdir="$scratch/parse" console -no-color > "$scratch/encoded.json"
jq -r . "$scratch/encoded.json" > "$scratch/workflow.json"
jq -e '
  (.on|keys)==["workflow_dispatch"] and .permissions=={contents:"read"} and
  .concurrency=={group:"cloudflare-bootstrap-migration","cancel-in-progress":false} and
  .jobs.proof."runs-on"=="ubuntu-latest" and .jobs.proof."timeout-minutes"==12 and
  (.jobs.proof.steps[0].run|contains("refs/heads/main") and contains("workflow_dispatch") and contains("VERIFY_STATE_BACKEND") and contains("GITHUB_RUN_ATTEMPT") and contains("github-hosted")) and
  .jobs.proof.steps[1].with."persist-credentials"==false and
  ([.jobs.proof.steps[]|select(has("env"))|.env|select(has("CLOUDFLARE_API_TOKEN"))]|length)==1 and
  ([.jobs.proof.steps[]|select(has("uses"))|.uses|select(startswith("actions/upload-artifact@"))]|length)==1 and
  .jobs.proof.steps[-1].with.path=="${{ runner.temp }}/state-backend-proof/evidence.tar.gz.age"
' "$scratch/workflow.json" >/dev/null
# Refuse each unauthorized context before reading credentials or invoking tools.
for scenario in ref actor repository event attempt confirmation runner; do
  (
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main
    export GITHUB_ACTOR=devantler GITHUB_REPOSITORY=devantler-tech/cloudflare
    export GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_ID=123456789 GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    export CONFIRMATION=VERIFY_STATE_BACKEND RUNNER_ENVIRONMENT=github-hosted
    case "$scenario" in
      ref) GITHUB_REF=refs/heads/unreviewed ;;
      actor) GITHUB_ACTOR=unapproved ;;
      repository) GITHUB_REPOSITORY=other/cloudflare ;;
      event) GITHUB_EVENT_NAME=pull_request ;;
      attempt) GITHUB_RUN_ATTEMPT=2 ;;
      confirmation) CONFIRMATION=UNCONFIRMED ;;
      runner) RUNNER_ENVIRONMENT=self-hosted ;;
    esac
    rc=0
    bash "$root/scripts/verify-state-backend.sh" "$root" > "$scratch/refusal" 2>&1 || rc=$?
    [[ $rc == 2 ]]
    grep -qx 'CLOUDFLARE_STATE_BACKEND=UNVERIFIED stage=dispatch' "$scratch/refusal"
  )
done
printf '%s\n' 'PASS: main-only, first-attempt, confirmed synthetic backend workflow and encrypted-only export'
