# Bootstrap, import, and recovery

This procedure keeps Cloudflare recovery independent of the Kubernetes
platform. It never reads credentials from a cluster-hosted secret and never
writes credentials or state into this repository.

## Prerequisites

The manual **Cloudflare connection (read-only)** workflow can check the existing
`CLOUDFLARE_API_TOKEN` CI binding before another credential handoff is requested.
Run it from `main` with confirmation `VERIFY_READ_ONLY`. Its guard runs before
checkout and credential use; it makes only fixed GET requests for the owned zone
and active account token, and prints capability verdicts without account data.
Missing or unverifiable access fails the check. Verified read access does not
establish state custody, import coverage or write permissions.
The workflow never imports, plans, applies or changes provider resources.

This follows GitHub's [manual workflow controls](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
and [environment-variable input handling](https://docs.github.com/en/actions/reference/security/secure-use#use-an-intermediate-environment-variable).

- OpenTofu 1.12.x, `jq`, and `age` (to decrypt and check the DNS snapshot).
- A short-lived Cloudflare bootstrap token with only the permissions needed to
  read and import the inventoried resources.
- Separate R2 S3 credentials scoped only to the state bucket and state object.
- Private operator working custody and approved ciphertext recovery custody
  reachable during a platform outage; see Repository recovery custody below.

Export secrets through the operator's secure session. Do not place values in a
command, `.tfvars`, backend file, CI log, issue, or pull request.

## Encrypted DNS inventory

The **DNS snapshot (encrypted, read-only)** workflow is disabled until a manual
dispatch by the maintainer on `main` with `EXPORT_ENCRYPTED_DNS`. Before its
first real dispatch, obtain explicit approval for the transport: this is a
public repository, so its short-lived Actions artifact is downloadable by
other signed-in GitHub users. Only authenticated age ciphertext is uploaded;
the matching infrastructure private identity stays in independent Keychain custody.
The public recipient is reviewed in `.github/dns-recovery-recipient.txt`.
Never dispatch unless that identity is recoverable and the destination is
approved. The workflow rejects reruns; a fresh snapshot needs a fresh dispatch.

This makes only fixed GET requests for the owned zone and its DNS records.
It verifies pagination counts, zone membership and record IDs, and preserves
all returned record fields. Missing access, partial pages, changing counts,
duplicates or invalid responses fail without an export. Pagination cannot
lock live DNS: retain a quiet change window and compare again before import.
This is a DNS snapshot, not a full account inventory or independent state.

Download the single `dns-snapshot.json.age` from the completed run into the
approved private recovery folder. Decrypt privately with the infrastructure
identity, check the source revision, owned-zone binding and complete records,
then confirm the encrypted recovery copy is readable before deleting the
Actions artifact. Retention is capped at one day; it is transport, never the
recovery store. Do not print plaintext, account details or identity material.
Temporary local custody requires a verified transfer to permanent independent
custody before cleanup; do not delete the only recoverable copy.

Existing import, state, no-destroy plan and first-apply approval requirements
below remain in effect. A completed snapshot does not enable an apply.

## Current bootstrap observations

The manual **Bootstrap inventory (encrypted, read-only)** workflow accepts only
`EXPORT_BOOTSTRAP_INVENTORY`, the approved operator, reviewed `main`, and a first
attempt. It uses the existing approved `CLOUDFLARE_API_TOKEN` Actions binding,
also used by the read-only connection check. No additional credential handoff
is required. The workflow never changes permissions or provider resources;
invalid dispatches stop before the credential-bearing step. A missing credential
stops before a provider call, and any insufficient read permission refuses the
entire export. There is no fallback to other DNS, tunnel or object-backup
credentials. Keep service credentials in OpenBao and the existing independent
runner copy in the approved repository secret store. This does not change the
token or its consumers. Never put credential values into an issue, plan,
command argument or chat.

The one-day artifact contains exactly two age-encrypted observations: the complete
owned-zone DNS result and the source-bound account metadata, visible token rows,
current token policy, and bucket metadata/lifecycle rules from the commercial
`default`, `eu`, and `us` jurisdictions. Each returned result set must have complete,
consistent pagination and unique identities. Bucket inventory is capped at 100
per jurisdiction, with at most 100 cursor pages, and token inventory at 1,000
visible rows. A denied or ambiguous read refuses the whole export. No object
contents or token secret values are read.

R2's response page-size hint may be absent or smaller than the requested limit.
Completeness requires stable total counts, cursor exhaustion and unique observed
bucket names; a page-size echo alone proves none of these. Explicit size hints
must remain consistent with the observed page and the bounded request. Optional
bucket hints stay exactly as returned: each encrypted entry retains its raw
`list_observation` separately from detail `metadata`, with the requested
jurisdiction recorded separately. Missing hints do not become desired
configuration or migration clearance, and a conflicting reported jurisdiction
or malformed hint is refused.

See the [R2 list response contract](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/methods/list/).

`ENCRYPTED_READS` proves only that these scoped reads and encryption succeeded.
Failed runs report a fixed `INVENTORY_STAGE` and `INVENTORY_FAILURE` category,
plus `INVENTORY_HTTP_STATUS` as three digits or `none`. These diagnostics contain
no provider response bodies, URLs, account identifiers, bucket names or token
values. A reported HTTP status does not establish complete inventory access;
read the failure category before deciding whether another observation is useful.
Cloudflare may limit a token list to tokens created by the caller; the package
therefore labels token coverage `credential-visible-only`. It proves neither
account-wide token coverage nor write permissions. Government jurisdictions are
outside this observation. Provider reads are not an atomic snapshot: rebind live
facts immediately before import and plan. Migration readiness remains
`UNVERIFIED` until ownership, selected imports, state custody and the actual plan
are reviewed. Do not retain this transient inventory as a second permanent
configuration backup.

Before selecting imports, compare the current platform declarations and live
writers. Leave ExternalDNS-managed records and their paired TXT registry under
ExternalDNS; preserve certificate challenge ownership and static challenge
delegations. Import every existing resource in the explicitly selected adoption
set before any apply; do not import every record or account token merely because
it appeared in a provider list. Bucket objects and application prefixes remain
owned by their existing consumers.

API contracts: [account token listing](https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/list/),
[bucket listing](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/methods/list/),
and [bucket lifecycle reads](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/subresources/lifecycle/methods/get/).

The lifecycle response may omit its optional `rules` member. The encrypted
observation preserves that omission; it is not an instruction to configure an
empty rule list. A present `rules` value must be an array of valid, uniquely
identified rules. Explicit nulls, malformed rules and missing required rule
fields refuse the export with a fixed lifecycle failure category.

Cloudflare's [pinned Wrangler lifecycle model](https://github.com/cloudflare/workers-sdk/blob/96c555434f99ce05954432d8edd511233f569ed4/packages/wrangler/src/r2/helpers/bucket.ts#L472-L490)
permits the rule's prefix to be omitted, although the generated API reference
describes it as required. The reader accepts and preserves an omitted prefix
within a valid conditions object. A present prefix must be a string; explicit
nulls and malformed or missing conditions objects remain refusals. Omission is
an observation, never a generated empty prefix or desired rule change.

## First migration

### First state-bucket proposal

Run **State bootstrap plan (encrypted, read-only)** from reviewed `main` with
`PLAN_STATE_BOOTSTRAP`. It uses the existing CI credential, reads the owned zone
and verifies that the proposed default-jurisdiction state bucket is absent.
Only Cloudflare's documented [NoSuchBucket response](https://developers.cloudflare.com/r2/api/error-codes/)
counts as absence; permission errors and an existing bucket stop the proposal.

The workflow initializes a private local backend and imports only the existing
zone. It then saves a real OpenTofu plan using the repository's pinned provider.
The permitted proposal is exactly one unchanged zone and one new protected state
bucket. All existing DNS records, buckets and tokens remain outside this first
adoption set. An unrelated change, zone update, deletion, replacement, deferred
evaluation or provider error stops export. No apply command exists in this path.

The one-day `encrypted-state-bootstrap-plan` artifact contains the imported
state and complete desired configuration in the registered state-recovery
format, plus encrypted binary and JSON plans. `plan-manifest.json` binds their
plaintext and ciphertext digests to that state generation, source revision and
run. Tool output and decrypted files stay in transient private scratch.

A failed proposal exports no successful plan package. After recipient validation,
it may retain a separate one-day `encrypted-state-bootstrap-diagnostics` artifact
containing an encrypted, bounded archive of the fixed provider observations and
tool logs. Decrypt only in private custody and inspect its source/run and failure
stage before reading the logs. This evidence is not an approved plan or a state
recovery generation. Early dispatch or credential refusals collect nothing.

Before approving an apply, download into private custody, verify the source/run
against Actions, run `check-state-recovery-package.sh` with the independent
identity, decrypt both plans privately, and check every manifest digest. Read
the complete JSON plan and compare its state/configuration binding. A successful
encrypted export proves a proposal, not custody publication, backend locking,
write permission or disaster recovery. The saved imported lineage must be
preserved when preparing its reviewed apply; do not initialize a second lineage
or silently regenerate the approved plan. Apply and state migration remain
separate gated work below.

### Migration and recovery gates

1. Inventory zones, records, buckets, lifecycle and lock settings, members, and
   tokens by identifier and purpose. Record no token values.
2. Fill a gitignored `production.auto.tfvars` from
   `production.tfvars.example`. Keep resource keys stable and descriptive. It is
   the production inventory every plan depends on: without it OpenTofu prompts
   for `account_id` and `zone_name`, and the empty resource maps plan removals.
   Keep its reviewed desired configuration encrypted with this repository's
   owner, alongside the state recovery copy, and refresh it in the same change.
   Never commit the plaintext file or replace a complete inventory with empty maps.
3. Copy `backend.hcl.example` to the gitignored `backend.hcl`, omitting backend
   credentials. Supply those through `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY`.
4. Before the R2 state bucket is available, select the local backend with a
   temporary, gitignored override and initialize. `tofu init -backend=false`
   does not work here: it skips backend initialization, so `tofu import` and
   `tofu plan` stop with "Backend initialization required" while `versions.tf`
   declares the S3 backend.

   ```sh
   printf 'terraform {\n  backend "local" {}\n}\n' >backend_override.tf
   tofu init
   ```

5. Import the zone, DNS records, R2 buckets, and account tokens using the import
   formats in the official Cloudflare provider documentation. R2 lifecycle
   resources cannot currently be imported; copy their live rules exactly into
   configuration and review the provider's read/plan result before applying.
6. Create a saved plan and enforce the migration invariant:

   ```sh
   tofu plan -out=migration.tfplan
   tofu show -json migration.tfplan >migration.tfplan.json
   scripts/assert-no-destructive-plan.sh migration.tfplan.json
   ```

7. Review every create and update. A delete or replacement is a failed
   migration, even when the resource appears obsolete. The only expected
   creates are the lifecycle rules from step 5, any new account tokens, and the
   protected state bucket when it was absent from the inventory.
8. Apply exactly that reviewed plan, still on local state, with a write-scoped
   bootstrap token:

   ```sh
   tofu apply migration.tfplan
   ```

9. Hand every new token value to approved custody without printing or writing
   it: pipe `tofu output -json account_token_values` straight into the custody
   system's stdin import, then confirm receipt by reading back each entry's name
   and version, never its value. A token that exists only in state is not
   delivered.
10. Before migrating state, capture `tofu state pull` into a private transient
    file and convert the complete `production.auto.tfvars` from HCL to JSON using
    the commands below. Pass both files to the state packaging helper, verify
    authenticated recovery, then transfer the encrypted package to this
    repository's approved recovery custody independently of R2. Remove the
    caller-created plaintext capture files only after that permanent copy is
    verified. The historical DNS observation is not a state backup.
    Refresh that copy after every apply, and do not enable apply automation
    until it refreshes the copy after each successful apply.
11. Once the state bucket exists and has recovery access, remove the override and
    migrate the local state into R2:

    ```sh
    rm backend_override.tf
    tofu init -migrate-state -backend-config=backend.hcl
    ```

12. From a fresh operator environment, initialize only from the repository,
    private custody, and R2 backend: restore `production.auto.tfvars` from its
    encrypted custody copy before planning. Confirm `tofu plan -detailed-exitcode`
    returns exit code 0 before enabling apply automation. While one plan holds
    the state lock, confirm a second `tofu plan -lock-timeout=0s` fails to
    acquire it; a second plan that proceeds means locking is not in effect.

## Recovery

Retrieve short-lived Cloudflare and R2 state credentials from the independent
custody path, clone this repository on a clean machine, recreate `backend.hcl`,
restore `production.auto.tfvars` from its encrypted custody copy, and run
`tofu init -reconfigure -backend-config=backend.hcl`. A successful
state pull and clean plan proves the recovery path without Kubernetes.

If the state bucket itself is unavailable, stop automated applies. Restore or
import the protected bucket using a temporary local state (the
`backend_override.tf` from step 4 of the first migration) and reconcile the
remote state object from the encrypted recovery copy that step 10 creates and
every apply refreshes.
Never create a second authoritative state lineage.


## Repository recovery custody

The maintainer approved retaining essential encrypted recovery data in its
owning repository on 29 October 2026. Ordinary service keys remain in OpenBao;
the infrastructure recovery key remains independently available in iCloud
Keychain. Neither the live state backend nor its sole recovery key may depend
on a functioning cluster or its OpenBao instance.

`recovery/dns-snapshot.json.age` retains the approved pre-migration export from
run 40282002745. `recovery/manifest.json` binds its original capture time and
source revision, the export run, current public recovery recipient and ciphertext
digest. It is historical DNS inventory, not a current plan or OpenTofu state.
It does not establish that this repository has imported or manages live resources.

The retained payload was authenticated with its original identity, re-encrypted
directly to the existing infrastructure recipient, then decrypted and compared
byte-for-byte. The old snapshot identity cannot decrypt this new copy. New
exports use the same public infrastructure recipient, so another wrapped private
key is unnecessary. Preserve the temporary source copies until the protected
merge and a fresh repository checkout's authenticated recovery are verified.

Run `bash scripts/check-recovery-package.sh .` before using the package. CI
checks the exact file inventory, metadata shape, recipient binding, age header
and ciphertext digest. Its `CHECKED` result does not claim decryption or provider
recovery. Actual recovery must use the independently held identity through an
approved secure identity input and verify authenticated decryption. Keep any
operator scratch private and temporary; never put key values into shell commands,
history, logs or this repository. This change does not implement automatic CLI
access to synchronized Keychain items.

Reviewed desired configuration belongs here. Cloudflare's API can provide a
current inventory for comparison and import, so there is no need for a second
manually maintained configuration catalogue. It cannot recover a record that
has already been deleted, and token metadata cannot recover a token's one-time
secret value. OpenTofu state also retains the binding between each remote object
and its stable configuration address. See the [Cloudflare import guidance](https://developers.cloudflare.com/terraform/advanced-topics/import-cloudflare-resources/),
[token documentation](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
and [OpenTofu state purpose](https://opentofu.org/docs/language/state/).

Active state still belongs in the independently accessible locked R2 backend.
Its minimum authenticated encrypted recovery copy belongs with this owner,
including source revision, lineage and serial bindings. That state format,
publication path, actual lock-contention test and clean-environment recovery
remain part of the first migration. No real state recovery package is currently
retained, and no apply automation is enabled by the packaging helpers.

### State recovery format

The optional `recovery/state/` generation contains exactly `manifest.json`,
`state.json.age` and `configuration.json.age`. It is separate from the historical
DNS observation. The repository checker validates this directory when present
and rejects additional plaintext files, symlinks and malformed packages.

From the reviewed, initialized OpenTofu working directory, capture state and
convert the current HCL variables in a private shell. These files may contain
credentials; retain them only in the new private capture directory and keep
command output there:

```bash
set -euo pipefail
umask 077
cloudflare_capture="$(mktemp -d)"
tofu state pull > "$cloudflare_capture/state.json" 2> "$cloudflare_capture/capture.err"
tofu console -var-file=production.auto.tfvars \
  > "$cloudflare_capture/variables.console.json" 2>> "$cloudflare_capture/capture.err" <<'TFVARS'
jsonencode({ account_id = var.account_id, zone_name = var.zone_name, dns_records = var.dns_records, r2_buckets = var.r2_buckets, r2_lifecycle_rules = var.r2_lifecycle_rules, account_tokens = var.account_tokens })
TFVARS
jq -er 'select(type == "string") | fromjson | select(type == "object")' \
  "$cloudflare_capture/variables.console.json" > "$cloudflare_capture/configuration.json"
bash scripts/prepare-state-recovery-package.sh "$PWD" \
  "$cloudflare_capture/state.json" "$cloudflare_capture/configuration.json" "$new_private_package" \
  "$reviewed_commit" "$capture_run_id" "$capture_time_utc"
```

The inputs are an OpenTofu version-4 state and the JSON form of the complete
`production.auto.tfvars` configuration. The canonical `cloudflare_zone.primary`
in state must bind the same account and zone as those variables. Packaging
freezes both input files, encrypts them to the existing infrastructure recipient
and reserves a new destination; it never overwrites an existing generation,
contacts a provider, imports, initializes a backend or applies anything. Private
scratch is removed on exit. Keep input files in approved private custody.

The public manifest binds capture time, reviewed source commit and capture run,
state lineage and serial, account/zone hashes, and both plaintext and ciphertext
digests. It contains no credential, account identifier, hostname or configuration
value. These labels do not authenticate a capture's provenance: independently
match its source and run against the actual reviewed pipeline before recovery.

Validate structure without a key, then authenticate the files privately:

```sh
bash scripts/check-state-recovery-package.sh "$PWD" "$new_private_package"
bash scripts/check-state-recovery-package.sh "$PWD" "$new_private_package" \
  --identity-file "$independent_identity_file"
```

The identity store must be an owned, regular, nonsymlink file with mode `0600`.
It may hold up to 32 native identities, including older SOPS identities. The
checker derives their public identities and streams only the unique matching
key through a private pipe; it ignores public-key comments and refuses unknown
identity formats. No private key is copied to another file, logged, put in a
shell/environment variable or supplied as a command argument. `CHECKED` verifies
only public structure and ciphertext digests. `VERIFIED scope=authenticated-files`
additionally proves authenticated decryption, plaintext digests, lineage/serial
and the paired account/zone configuration. An unrelated identity or inconsistent
pair refuses recovery. Nothing is restored to an active backend by either mode.

Publish a real encrypted generation only after its actual file-authentication
check, trusted capture/source verification and review. Preserve the previous
recoverable copy until a fresh checkout has passed the same check. After that
transfer and verification, remove only the caller-created plaintext capture:

```sh
rm -rf "$cloudflare_capture"
```

Retain the authoritative backend state and previous verified generation. A synthetic
test package is never an infrastructure recovery receipt. Recreating a clean
environment, restoring the sole state lineage, proving lock contention and
observing a clean provider plan are still separate required gates above. Never
enable apply automation before the after-apply capture/publication path exists.
