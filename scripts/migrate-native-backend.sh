#!/usr/bin/env bash
# Automate only the pinned CLI's empty-destination confirmation. OpenTofu owns
# both native locks and rechecks state while locked; never force or overwrite.
set +x
set -euo pipefail
umask 077
stage=arguments writer='' reader='' child='' log='' workspace_probe=''
fail() { printf 'NATIVE_STATE_MIGRATION=UNVERIFIED stage=%s\n' "$stage" >&2; exit 2; }
# EOF aborts an unanswered native prompt. Drain output so its normal error path
# can release locks before waiting; an unresponsive child has its own deadline.
finish() {
  local rc=$?
  [[ -z "$writer" ]] || exec {writer}>&-
  if [[ -n "$reader" ]]; then
    timeout 10 cat <&"$reader" >> "$log" 2>/dev/null || true
    exec {reader}<&-
  fi
  [[ -z "$child" ]] || wait "$child" 2>/dev/null || true
  [[ -z "$workspace_probe" ]] || rm -rf "$workspace_probe"
  return "$rc"
}
trap finish EXIT
trap 'exit 2' INT TERM
[[ ${BASH_VERSINFO[0]} -ge 5 && $# == 3 && -d $1 && ! -L $1 &&
  -f $2 && ! -L $2 && -d $3 && ! -L $3 && ! -e $3/migration.log && ! -L $3/migration.log ]] || fail
module=$1 configuration=$2 log="$3/migration.log"
stage=environment
while IFS= read -r name; do
  case "$name" in
    TF_IN_AUTOMATION) [[ ${TF_IN_AUTOMATION:-} == 1 ]] || fail ;;
    TF_*|TOFU_*) fail ;;
  esac
done < <(compgen -e)
command -v timeout >/dev/null 2>&1 || fail
stage=version
version=$(tofu version -json 2>/dev/null) || fail
printf '%s' "$version" | jq -e '.terraform_version=="1.12.6"' >/dev/null 2>&1 || fail
stage=destination-workspaces
# Inspect a separate, state-free copy of the destination declaration. Running
# init beside the local source file can itself propose migration, even with
# reconfigure. Only absolute local fixture paths or the fixed S3 profile qualify.
# Keep probe/cache/raw responses outside retained evidence even if this child
# cannot finish its cleanup. The caller owns the enclosing private scratch.
workspace_probe=$(mktemp -d "$(dirname -- "$3")/workspace-probe.XXXXXXXX")
shopt -s nullglob
declarations=("$module/"*.tf "$module/"*.tf.json)
[[ ${#declarations[@]} -gt 0 && ${#declarations[@]} -le 32 ]] || fail
for file in "${declarations[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || fail
  cp "$file" "$workspace_probe/${file##*/}"
done
if [[ -e "$module/.terraform.lock.hcl" || -L "$module/.terraform.lock.hcl" ]]; then
  [[ -f "$module/.terraform.lock.hcl" && ! -L "$module/.terraform.lock.hcl" ]] || fail
  cp "$module/.terraform.lock.hcl" "$workspace_probe/.terraform.lock.hcl"
fi
cp "$configuration" "$workspace_probe/backend.hcl"
configuration="$workspace_probe/backend.hcl"
stage=destination-initialize
timeout --kill-after=10s 90 tofu -chdir="$workspace_probe" init -input=false -no-color -backend-config="$configuration" > "$3/destination-init.log" 2>&1 || fail
stage=destination-profile
jq -e '.backend.type=="s3" or (.backend.type=="local" and
  (.backend.config.path|type=="string" and startswith("/")) and
  (.backend.config.workspace_dir|type=="string" and startswith("/")))' "$workspace_probe/.terraform/terraform.tfstate" >/dev/null 2>&1 || fail
# Native structured output binds the selected destination to default only.
# Re-read immediately before confirmation while the migration lock is held.
logs=$3
backend_type=$(jq -er .backend.type "$workspace_probe/.terraform/terraform.tfstate") || fail
if [[ $backend_type == s3 ]]; then
  endpoint=$(jq -er .backend.config.endpoints.s3 "$workspace_probe/.terraform/terraform.tfstate") || fail
  bucket=$(jq -er .backend.config.bucket "$workspace_probe/.terraform/terraform.tfstate") || fail
  workspace_prefix=$(jq -er .backend.config.workspace_key_prefix "$workspace_probe/.terraform/terraform.tfstate") || fail
  [[ -n ${AWS_SESSION_TOKEN:-} ]] || fail
  [[ $endpoint =~ ^https://[a-f0-9]{32}\.r2\.cloudflarestorage\.com$ ||
    $endpoint =~ ^http://127\.0\.0\.1:[1-9][0-9]{0,4}$ ]] || fail
  [[ $bucket =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ &&
    $workspace_prefix =~ ^[A-Za-z0-9/_-]{1,200}$ &&
    ${AWS_ACCESS_KEY_ID:-} =~ ^[a-f0-9]{32}$ &&
    ${AWS_SECRET_ACCESS_KEY:-} =~ ^[a-f0-9]{64}$ &&
    ${#AWS_SESSION_TOKEN} -ge 16 && ${#AWS_SESSION_TOKEN} -le 6144 &&
    $AWS_SESSION_TOKEN =~ ^[A-Za-z0-9._~+/=-]+$ ]] || fail
  script_directory=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  stage=list-validator-build
  GOWORK=off GOFLAGS='' GOTOOLCHAIN=local go build -trimpath -o "$workspace_probe/check-workspace-list" "$script_directory/check-native-workspace-list.go" > "$logs/list-validator-build.log" 2>&1 || fail
fi
destination_workspaces() {
  stage=destination-workspaces
  if [[ $backend_type == s3 ]]; then
    # The native backend hides ListObjects AccessDenied for compatibility.
    # Require a successful listing before trusting its workspace census. Use
    # curl's native signer; credentials stay in an inherited input pipe.
    local list_status list_rc=0 sensitive_rc=0
    stage=destination-listing
    list_status=$(printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN" |
      curl --disable --config - --aws-sigv4 aws:amz:auto:s3 --get \
        --proto '=http,https' --noproxy '*' --max-redirs 0 --connect-timeout 10 --max-time 30 \
        --max-filesize 1048576 --silent --fail-with-body --output "$workspace_probe/list-response.xml" \
        --write-out '%{http_code}' --data-urlencode list-type=2 --data-urlencode "prefix=$workspace_prefix/" \
        --url "$endpoint/$bucket" 2> "$logs/destination-list-error.log") || list_rc=$?
    [[ $list_status =~ ^[0-9]{3}$ ]] || return 1
    printf 'status=%s curl_exit=%s\n' "$list_status" "$list_rc" > "$logs/destination-list-status.log"
    [[ $list_rc == 0 && $list_status == 200 ]] || return 1
    # A provider error can echo authentication data. Keep every raw response
    # outside retained evidence until success, content and confidentiality pass.
    stage=listing-confidentiality
    grep -Fq -f <(printf '%s\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN") "$workspace_probe/list-response.xml" || sensitive_rc=$?
    [[ $sensitive_rc == 1 ]] || return 1
    stage=listing-validation
    "$workspace_probe/check-workspace-list" "$bucket" "$workspace_prefix/" < "$workspace_probe/list-response.xml" > "$logs/destination-list-validation.log" 2>&1 || return 1
    cp "$workspace_probe/list-response.xml" "$logs/destination-list.xml" || return 1
  fi
  stage=destination-workspaces
  timeout --kill-after=10s 30 tofu -chdir="$workspace_probe" workspace list -json > "$logs/destination-workspaces.json" 2> "$logs/destination-workspaces-error.log" || return 1
  jq -se 'length==2 and .[0].type=="version" and .[1].type=="workspace_list" and
    .[1].current_workspace=="default" and .[1].workspaces==["default"]' "$logs/destination-workspaces.json" >/dev/null 2>&1
}
destination_workspaces || fail
# The pinned remote state manager resets imported metadata when its first
# persist sees no snapshot. Initialize an absent destination with a native,
# provider-free empty plan first. Existing non-empty state is always refused;
# the saved plan and native lock protect the check/apply handoff from races.
if [[ $backend_type == s3 ]]; then
  stage=destination-state
  destination_rc=0
  timeout --kill-after=10s 30 tofu -chdir="$workspace_probe" state pull > "$logs/destination-state.json" 2> "$logs/destination-state-error.log" || destination_rc=$?
  empty_snapshot() {
    jq -e '.version==4 and
      (.serial|type=="number" and .>=0 and .==floor) and
      (.resources|type=="array" and length==0) and (.outputs|type=="object" and length==0) and
      ((.check_results // null)==null)' "$1" >/dev/null 2>&1
  }
  [[ $destination_rc == 0 && ! -s "$logs/destination-state-error.log" ]] || fail
  empty_snapshot "$logs/destination-state.json" || fail
  # state pull serializes an absent remote snapshot as empty lineage/serial0.
  # Treat neither an error nor malformed/occupied state as absence.
  if jq -e '.lineage=="" and .serial==0' "$logs/destination-state.json" >/dev/null 2>&1; then
    stage=empty-initialize
    seed="$workspace_probe/empty-seed"
    mkdir "$seed"
    printf 'terraform {\n  required_version = "= 1.12.6"\n  backend "s3" {}\n}\n' > "$seed/main.tf"
    timeout --kill-after=10s 60 tofu -chdir="$seed" init -input=false -no-color -backend-config="$configuration" > "$logs/seed-init.log" 2>&1 || fail
    timeout --kill-after=10s 60 tofu -chdir="$seed" plan -input=false -lock-timeout=0s -detailed-exitcode -no-color -out=empty.tfplan > "$logs/seed-plan.log" 2>&1 || fail
    timeout 30 tofu -chdir="$seed" show -json empty.tfplan > "$logs/seed-plan.json" 2> "$logs/seed-show-error.log" || fail
    jq -e '.errored!=true and ((.deferred_changes // [])|length==0) and
      ((.resource_changes // [])|length==0) and ((.output_changes // {})|length==0) and
      ((.configuration.provider_config // {})|length==0) and
      ((.planned_values.outputs // {})|length==0) and
      ((.planned_values.root_module.resources // [])|length==0) and
      ((.planned_values.root_module.child_modules // [])|length==0) and
      ((.prior_state.values.outputs // {})|length==0) and
      ((.prior_state.values.root_module.resources // [])|length==0) and
      ((.prior_state.values.root_module.child_modules // [])|length==0)
    ' "$logs/seed-plan.json" >/dev/null 2>&1 || fail
    timeout --kill-after=10s 60 tofu -chdir="$seed" apply -input=false -lock-timeout=0s -no-color empty.tfplan > "$logs/seed-apply.log" 2>&1 || fail
    timeout 30 tofu -chdir="$seed" state pull > "$logs/seed-state.json" 2> "$logs/seed-pull-error.log" || fail
    empty_snapshot "$logs/seed-state.json" || fail
    jq -e '.lineage|type=="string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")' "$logs/seed-state.json" >/dev/null 2>&1 || fail
    destination_workspaces || fail
  else
    jq -e '.lineage|type=="string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")' "$logs/destination-state.json" >/dev/null 2>&1 || fail
  fi
fi
stage=copy
coproc MIGRATION { timeout --kill-after=10s 180 tofu -chdir="$module" init -migrate-state -no-color -backend-config="$configuration" 2>&1; }
# shellcheck disable=SC2153 # Bash creates this for the named coprocess above.
child=$MIGRATION_PID
exec {writer}>&"${MIGRATION[1]}"
exec {reader}<&"${MIGRATION[0]}"
# Closing only the duplicates would leave the original coprocess write end
# open, preventing EOF from reaching a refused prompt.
original_writer=${MIGRATION[1]} original_reader=${MIGRATION[0]}
exec {original_writer}>&-
exec {original_reader}<&-
buffer='' answers=0 refused=false total=0
while true; do
  read_rc=0
  IFS= read -r -N 1 -t 30 -u "$reader" character || read_rc=$?
  if [[ $read_rc != 0 ]]; then
    if [[ $read_rc != 1 ]]; then stage=stream; refused=true; fi
    break
  fi
  printf '%s' "$character" >> "$log"
  buffer+=$character
  total=$((total + 1))
  if [[ $total -gt 1048576 ]]; then stage=output; refused=true; break; fi
  if [[ "$buffer" == *'Enter a value:' ]]; then
    if [[ $answers == 0 && "$buffer" == *'Do you want to copy existing state to the new backend?'* &&
      "$buffer" == *'No existing state was found'* && "${buffer,,}" != *'overwrite'* &&
      "${buffer,,}" != *'non-empty'* && "${buffer,,}" != *'all workspaces'* ]]; then
      stage=destination-workspaces
      if ! destination_workspaces; then
        refused=true
        [[ -z "$writer" ]] || exec {writer}>&-
        writer=''
        continue
      fi
      stage=copy
      printf 'yes\n' >&"$writer" || fail
      answers=1
      buffer=''
    else
      stage=destination
      refused=true
      [[ -z "$writer" ]] || exec {writer}>&-
      writer=''
    fi
  fi
done
[[ -z "$writer" ]] || exec {writer}>&-
writer=''
rc=0
wait "$child" || rc=$?
child=''
exec {reader}<&-
reader=''
[[ "$refused" == false ]] || fail
stage=native-command
[[ $rc == 0 ]] || fail
stage=no-copy
[[ $answers == 1 ]] || fail
printf '%s\n' 'NATIVE_STATE_MIGRATION=VERIFIED confirmation=empty-destination'
