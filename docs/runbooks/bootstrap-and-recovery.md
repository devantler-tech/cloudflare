# Bootstrap, import, and recovery

This procedure keeps Cloudflare recovery independent of the Kubernetes
platform. It never reads credentials from a cluster-hosted secret and never
writes credentials or state into this repository.

## Prerequisites

- OpenTofu 1.12.x and `jq`.
- A short-lived Cloudflare bootstrap token with only the permissions needed to
  read and import the inventoried resources.
- Separate R2 S3 credentials scoped only to the state bucket and state object.
- An approved private custody destination reachable during a platform outage.

Export secrets through the operator's secure session. Do not place values in a
command, `.tfvars`, backend file, CI log, issue, or pull request.

## First migration

1. Inventory zones, records, buckets, lifecycle and lock settings, members, and
   tokens by identifier and purpose. Record no token values.
2. Fill a gitignored `production.auto.tfvars` from
   `production.tfvars.example`. Keep resource keys stable and descriptive.
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
   migration, even when the resource appears obsolete.
8. Once the state bucket exists and has recovery access, remove the override and
   migrate the local state into R2:

   ```sh
   rm backend_override.tf
   tofu init -migrate-state -backend-config=backend.hcl
   ```

9. From a fresh operator environment, initialize only from the repository,
   private custody, and R2 backend. Confirm `tofu plan -detailed-exitcode`
   returns exit code 0 before enabling apply automation. While one plan holds
   the state lock, confirm a second `tofu plan -lock-timeout=0s` fails to
   acquire it; a second plan that proceeds means locking is not in effect.

## Recovery

Retrieve short-lived Cloudflare and R2 state credentials from the independent
custody path, clone this repository on a clean machine, recreate `backend.hcl`,
and run `tofu init -reconfigure -backend-config=backend.hcl`. A successful
state pull and clean plan proves the recovery path without Kubernetes.

If the state bucket itself is unavailable, stop automated applies. Restore or
import the protected bucket using a temporary local state (the
`backend_override.tf` from step 4 of the first migration) and reconcile the
remote state object from the independently retained encrypted recovery copy.
Never create a second authoritative state lineage.

