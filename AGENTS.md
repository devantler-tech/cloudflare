# AGENTS.md — devantler-tech/cloudflare

This is the canonical repository guidance. The portfolio-wide engineering
contract in [`devantler-tech/monorepo`](https://github.com/devantler-tech/monorepo/blob/main/AGENTS.md)
also applies.

## What this repo is

The cluster-independent declarative owner for Cloudflare resources that must
exist before the Kubernetes platform, Flux, or Crossplane can start. It manages
the account boundary, the primary zone, bootstrap DNS, R2 buckets and lifecycle
rules, and scoped Cloudflare service tokens with OpenTofu.

Platform-specific consumers stay in `devantler-tech/platform`: ExternalSecrets,
external-dns, cert-manager issuers, backup destinations, egress, admission
policy, and the capabilities granted to tenants.

## Maintenance

- Use OpenTofu 1.12.x and the official Cloudflare provider version pinned in
  `versions.tf`.
- Pass credentials only through environment variables or the approved private
  CI secret store. Never commit backend credentials, API tokens, state, plan
  binaries, or generated values.
- Import every existing resource before any apply. During migration, convert
  the plan to JSON and run `scripts/assert-no-destructive-plan.sh`; any delete
  or replacement is a hard stop.
- Keep the state backend and execution path independent of Kubernetes, Flux,
  Crossplane, OpenBao, and cluster-hosted runners. GitHub-hosted runners are the
  automation boundary.
- Keep `prevent_destroy` on the zone and every R2 bucket. A reviewed change may
  replace a DNS record only after the import migration is complete; zone or
  bucket destruction requires a separate, explicit change to that lifecycle
  boundary.
- Run `scripts/test.sh` before every PR.

