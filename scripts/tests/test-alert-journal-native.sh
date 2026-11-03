#!/usr/bin/env bash
# Invalid dispatches must stop before a provider request or test execution.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
printf '#!/usr/bin/env bash\nprintf touched > "%s/provider-contact"\nexit 99\n' "$scratch" > "$scratch/bin/curl"
chmod +x "$scratch/bin/curl"
[[ -f $root/scripts/prove-alert-journal-native.sh ]] || { echo 'FAIL: scoped native journal entrypoint is missing' >&2;exit 1; }
# Each supplied override must refuse before curl can record any contact.
run_refused() {
  local expected=$1;shift
  local rc=0
  env -i PATH="$scratch/bin:$PATH" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main \
    GITHUB_REPOSITORY=devantler-tech/cloudflare GITHUB_ACTOR=devantler GITHUB_RUN_ATTEMPT=1 \
    RUNNER_ENVIRONMENT=github-hosted GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    GITHUB_RUN_ID=1234567890 GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/alert-journal-native.yaml@refs/heads/main \
    CONFIRMATION=PROVE_ALERT_JOURNAL "$@" bash "$root/scripts/prove-alert-journal-native.sh" "$root" > "$scratch/out" 2>&1 || rc=$?
  [[ $rc == 2 && ! -e $scratch/provider-contact ]] || { echo 'FAIL: refused dispatch reached a provider or returned an unrelated error' >&2;exit 1; }
  grep -Fxq "R2_JOURNAL_NATIVE=UNVERIFIED stage=$expected" "$scratch/out" || { echo 'FAIL: wrong native journal refusal stage' >&2;exit 1; }
}
run_refused dispatch CONFIRMATION=unconfirmed
run_refused dispatch GITHUB_REF=refs/heads/codex/unreviewed
run_refused dispatch GITHUB_ACTOR=unapproved-actor
run_refused dispatch GITHUB_RUN_ATTEMPT=2
run_refused dispatch GITHUB_WORKFLOW_REF=devantler-tech/cloudflare/.github/workflows/other.yaml@refs/heads/main
run_refused credential
run_refused credential CLOUDFLARE_API_TOKEN=invalid
printf '%s\n' 'PASS: native journal dispatch and credential refusals precede provider access'
