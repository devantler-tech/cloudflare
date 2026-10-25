#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/bin" "$work_dir/parse"
probe="$repo_root/scripts/check-cloudflare-connection.sh"
fixture_token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

cat > "$work_dir/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'attempt\n' >> "$CF_FIXTURE_ATTEMPTS_FILE"
[[ $1 == --disable ]] || exit 90
url=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --disable|--silent|--show-error|--fail-with-body) shift ;;
    --config) [[ $2 == - ]] || exit 91; shift 2 ;;
    --request) [[ $2 == GET ]] || exit 92; shift 2 ;;
    --proto) [[ $2 == '=https' ]] || exit 93; shift 2 ;;
    --noproxy) [[ $2 == '*' ]] || exit 94; shift 2 ;;
    --max-redirs) [[ $2 == 0 ]] || exit 95; shift 2 ;;
    --connect-timeout|--max-time|--max-filesize) shift 2 ;;
    --url) url=$2; shift 2 ;;
    *) exit 96 ;;
  esac
done
IFS= read -r header
[[ $header == 'header = "Authorization: Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' ]] || exit 97
printf '%s\n' "$url" >> "$CF_FIXTURE_CALLS_FILE"
if [[ $CF_FIXTURE_CASE == http-error ]]; then
  printf '{"success":false,"errors":[{"code":10000,"message":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}]}'
  exit 22
fi
if [[ $CF_FIXTURE_CASE == invalid-json ]]; then
  printf 'not JSON'
  exit 0
fi
case $url in
  'https://api.cloudflare.com/client/v4/zones?name=devantler.tech&per_page=50')
    case $CF_FIXTURE_CASE in
      ambiguous) printf '{"success":true,"result":[{},{}],"result_info":{"total_count":2,"total_pages":1}}' ;;
      partial-page) printf '{"success":true,"result":[{"name":"devantler.tech","status":"active","account":{"id":"22222222222222222222222222222222"}}],"result_info":{"total_count":2,"total_pages":2}}' ;;
      wrong-zone) printf '{"success":true,"result":[{"name":"other.test","status":"active","account":{"id":"22222222222222222222222222222222"}}],"result_info":{"total_count":1,"total_pages":1}}' ;;
      invalid-account) printf '{"success":true,"result":[{"name":"devantler.tech","status":"active","account":{"id":"../other"}}],"result_info":{"total_count":1,"total_pages":1}}' ;;
      *) printf '{"success":true,"result":[{"name":"devantler.tech","status":"active","account":{"id":"22222222222222222222222222222222"}}],"result_info":{"total_count":1,"total_pages":1}}' ;;
    esac
    ;;
  'https://api.cloudflare.com/client/v4/accounts/22222222222222222222222222222222/tokens/verify')
    case $CF_FIXTURE_CASE in
      inactive) printf '{"success":true,"result":{"id":"33333333333333333333333333333333","status":"disabled"}}' ;;
      short-token-id) printf '{"success":true,"result":{"id":"3333","status":"active"}}' ;;
      *) printf '{"success":true,"result":{"id":"33333333333333333333333333333333","status":"active"}}' ;;
    esac
    ;;
  *) exit 98 ;;
esac
STUB
chmod +x "$work_dir/bin/curl"

run_probe() {
  local scenario=$1 expected_rc=$2 expected_calls=$3 token=$fixture_token
  local ref=refs/heads/main event=workflow_dispatch confirmation=VERIFY_READ_ONLY probe_rc=0
  local probe_path="$work_dir/bin:$PATH"
  case $scenario in
    absent-token) token='' ;;
    wrong-ref) ref=refs/heads/unreviewed ;;
    wrong-event) event=pull_request ;;
    wrong-confirmation) confirmation='VERIFY_READ_ONLY"; exit 0; #' ;;
    missing-tool) probe_path="$work_dir/bin" ;;
  esac
  : > "$work_dir/calls"
  : > "$work_dir/attempts"
  if [[ $scenario == inherited-trace ]]; then
    set -- /bin/bash -x "$probe"
  else
    set -- /bin/bash "$probe"
  fi
  env PATH="$probe_path" CF_FIXTURE_CASE="$scenario" CF_FIXTURE_CALLS_FILE="$work_dir/calls" CF_FIXTURE_ATTEMPTS_FILE="$work_dir/attempts" \
    CLOUDFLARE_API_TOKEN="$token" GITHUB_REF="$ref" GITHUB_EVENT_NAME="$event" \
    CONFIRMATION="$confirmation" "$@" > "$work_dir/$scenario.out" 2>&1 || probe_rc=$?
  [[ $probe_rc == "$expected_rc" ]] || { echo "FAIL $scenario: expected exit $expected_rc, got $probe_rc" >&2; exit 1; }
  [[ $(wc -l < "$work_dir/calls" | tr -d ' ') == "$expected_calls" ]] || { echo "FAIL $scenario: unexpected provider request count" >&2; exit 1; }
  [[ $(wc -l < "$work_dir/attempts" | tr -d ' ') == "$expected_calls" ]] || { echo "FAIL $scenario: an unsafe request was attempted" >&2; exit 1; }
  if grep -Eq 'AAAAAAAAAAAA|222222222222|333333333333|Authorization:' "$work_dir/$scenario.out"; then
    echo "FAIL $scenario: private request material reached output" >&2
    exit 1
  fi
}

run_probe success 0 2
run_probe inherited-trace 0 2
run_probe short-token-id 0 2
grep -Fq 'CF_CONNECTION=READ_ACCESS_VERIFIED' "$work_dir/success.out"
grep -Fq 'DEPLOYMENT_READINESS=UNVERIFIED' "$work_dir/success.out"
run_probe absent-token 2 0
run_probe wrong-ref 2 0
run_probe wrong-event 2 0
run_probe wrong-confirmation 2 0
run_probe missing-tool 2 0
run_probe http-error 2 1
run_probe invalid-json 2 1
run_probe ambiguous 2 1
run_probe partial-page 2 1
run_probe wrong-zone 2 1
run_probe invalid-account 2 1
run_probe inactive 2 2

# Reuse the project's required OpenTofu runtime as a real YAML parser; this
# empty, disposable module has no provider, backend or production credential.
workflow="$repo_root/.github/workflows/cloudflare-connection.yaml"
expression=$(jq -nr --arg path "$workflow" '"jsonencode(yamldecode(file(" + ($path|tojson) + ")))"')
printf '%s\n' "$expression" | tofu -chdir="$work_dir/parse" console -no-color > "$work_dir/workflow-string.json"
jq -r . "$work_dir/workflow-string.json" > "$work_dir/workflow.json"

check_workflow() {
  jq -e '
    .permissions == {contents:"read"}
    and (.on|keys) == ["workflow_dispatch"]
    and .on.workflow_dispatch.inputs.confirmation.type == "string"
    and .on.workflow_dispatch.inputs.confirmation.required == true
    and (.jobs|keys) == ["check"]
    and .jobs.check["runs-on"] == "ubuntu-latest"
    and .jobs.check["timeout-minutes"] == 3
    and (.jobs.check.permissions // {}) == {}
    and (.jobs.check|has("continue-on-error")|not)
    and (.jobs.check|has("if")|not)
    and all(.jobs.check.steps[]; (has("continue-on-error")|not) and (has("if")|not))
    and (.env // {}) == {} and (.jobs.check.env // {}) == {}
    and (.defaults // {}) == {} and (.jobs.check.defaults // {}) == {}
    and (.jobs.check.steps|length) == 3
    and .jobs.check.steps[0].env == {CONFIRMATION:"${{ inputs.confirmation }}"}
    and (.jobs.check.steps[0].run|contains("${{")|not)
    and .jobs.check.steps[1].uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    and .jobs.check.steps[1].with == {"persist-credentials":false,ref:"${{ github.sha }}"}
    and (.jobs.check.steps[1].env // {}) == {}
    and .jobs.check.steps[2].env == {CONFIRMATION:"${{ inputs.confirmation }}",CLOUDFLARE_API_TOKEN:"${{ secrets.CLOUDFLARE_API_TOKEN }}"}
    and .jobs.check.steps[2].run == "bash scripts/check-cloudflare-connection.sh"
  ' "$1" >/dev/null
}
check_workflow "$work_dir/workflow.json"
jq -r '.jobs.check.steps[0].run' "$work_dir/workflow.json" > "$work_dir/guard.sh"
env GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=workflow_dispatch CONFIRMATION=VERIFY_READ_ONLY bash "$work_dir/guard.sh"
for scenario in wrong-ref wrong-event wrong-confirmation; do
  ref=refs/heads/main; event=workflow_dispatch; confirmation=VERIFY_READ_ONLY
  case $scenario in
    wrong-ref) ref=refs/heads/unreviewed ;;
    wrong-event) event=pull_request ;;
    wrong-confirmation) confirmation='VERIFY_READ_ONLY"; exit 0; #' ;;
  esac
  if env GITHUB_REF="$ref" GITHUB_EVENT_NAME="$event" CONFIRMATION="$confirmation" bash "$work_dir/guard.sh" > /dev/null 2>&1; then
    echo "FAIL inline guard accepted $scenario" >&2; exit 1
  fi
done
for mutation in '.permissions.contents="write"' '.on.push={}' '.jobs.check.steps|=.[1:]' '.jobs.check.steps[0].env.CLOUDFLARE_API_TOKEN="exposed-before-guard"' '.jobs.check.steps[1].with.token="provider-key"'; do
  jq "$mutation" "$work_dir/workflow.json" > "$work_dir/mutant.json"
  if check_workflow "$work_dir/mutant.json"; then
    echo 'FAIL unsafe workflow control accepted' >&2; exit 1
  fi
done
printf '%s\n' 'PASS: read-only Cloudflare connection and workflow failure controls'
