#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# The dangerous break is reaching credentials/backend writes from an unreviewed
# dispatch, rerun, actor or phase. Run the real entrypoint for each refusal.
for scenario in ref actor repository event attempt confirmation runner workflow phase; do
  (
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main
    export GITHUB_ACTOR=devantler GITHUB_REPOSITORY=devantler-tech/cloudflare
    export GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_ID=123456789 GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    export CONFIRMATION=MIGRATE_STATE_BACKEND RUNNER_ENVIRONMENT=github-hosted
    export GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/state-backend-migrate.yaml@refs/heads/main
    export MIGRATION_PHASE=migrate
    case "$scenario" in
      ref) GITHUB_REF=refs/heads/unreviewed ;;
      actor) GITHUB_ACTOR=unapproved ;;
      repository) GITHUB_REPOSITORY=other/cloudflare ;;
      event) GITHUB_EVENT_NAME=pull_request ;;
      attempt) GITHUB_RUN_ATTEMPT=2 ;;
      confirmation) CONFIRMATION=UNCONFIRMED ;;
      runner) RUNNER_ENVIRONMENT=self-hosted ;;
      workflow) GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/other.yaml@refs/heads/main ;;
      phase) MIGRATION_PHASE=apply ;;
    esac
    rc=0
    bash "$root/scripts/migrate-state-backend.sh" "$root" > "$scratch/refusal" 2>&1 || rc=$?
    [[ $rc == 2 ]]
    grep -qx 'CLOUDFLARE_STATE_MIGRATION=UNVERIFIED stage=dispatch' "$scratch/refusal"
  )
done
printf '%s\n' 'PASS: real-state migration refuses unauthorized dispatch before credentials or backend access'
