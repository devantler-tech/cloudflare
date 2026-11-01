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
per jurisdiction and token inventory at 1,000 visible rows. A denied or ambiguous
read refuses the whole export. No object contents or token secret values are read.

R2's response page-size hint may be absent or smaller than the requested limit.
Completeness requires stable total counts, cursor exhaustion and unique observed
bucket names; a page-size echo alone proves none of these. Explicit size hints
must remain consistent with the observed page and the bounded request. Optional
bucket hints stay exactly as returned, with the requested jurisdiction recorded
separately. Missing hints do not become desired configuration or migration
clearance, and a conflicting reported jurisdiction or malformed hint is refused.

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

## First migration

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
10. Take the first encrypted recovery copy of state before migrating it: pipe
    `tofu state pull` through encryption to the recovery key and store the
    authenticated ciphertext with this repository's owner, independently of R2.
    Its reviewed package format must bind source revision, lineage and serial;
    the current historical DNS package is not a state backup.
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
remain part of the first migration; the current package validator admits only
the historical DNS package. No apply automation is enabled by this custody change.
