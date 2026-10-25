# cloudflare

Declarative, cluster-independent ownership of devantler-tech Cloudflare
infrastructure, written in [OpenTofu](https://opentofu.org).

This repository owns resources that must survive a full platform outage or
must exist before the platform can bootstrap:

- the Cloudflare zone;
- bootstrap and authoritative DNS records;
- R2 buckets and their lifecycle rules;
- least-privilege service tokens and their policy boundaries; and
- the independent R2 state backend configuration.

The [`platform`](https://github.com/devantler-tech/platform) repository owns
the in-cluster consumers and tenant boundaries. A tenant can publish and roll
forward within those boundaries without a platform revision update. Changes to
Cloudflare privileges, shared DNS, storage, or other platform boundaries are
reviewed here or in `platform`, according to where the resource runs.

It is configuration for one organization's account, not a reusable module. You
can read it, check it locally and propose changes without any Cloudflare
access. You cannot deploy anything with it: applying is a maintainer operation,
and no apply automation is enabled yet (see [Safety state](#safety-state)).

## Check the configuration locally

This is the first thing to run, and it needs no credentials, no Cloudflare
account and no state backend.

You need:

- [OpenTofu](https://opentofu.org/docs/intro/install/) on the 1.12 line
  (`versions.tf` requires `~> 1.12.0`; CI runs 1.12.6);
- [ShellCheck](https://github.com/koalaman/shellcheck#installing) and `jq`;
- a POSIX shell; and
- network access to `registry.opentofu.org` and to GitHub's release downloads,
  where OpenTofu fetches the pinned Cloudflare provider on the first run.

From the repository root:

```sh
scripts/test.sh
```

It lints the shell scripts, runs the destructive-plan guard against its
fixtures, checks formatting, downloads the provider with the backend switched
off (`tofu init -backend=false`) and validates the configuration against the
provider's schema. On success it exits 0, and the output includes these two
lines:

```text
PASS: destructive OpenTofu plans fail closed
Success! The configuration is valid.
```

The run creates a `.terraform/` directory in the repository, which Git ignores
and which you can delete, and a few `cloudflare-plan-*.out` files in `/tmp`.

This check never contacts the Cloudflare API and never reads state. It shows
that the configuration is well-formed and that the guard rejects deletes and
replacements. It does not show what a plan against the live account would
change. Do not set `CLOUDFLARE_API_TOKEN` or backend credentials to run it.

[CI](.github/workflows/ci.yaml) runs the same script on every pull request
and on every push to `main`, on a GitHub-hosted runner with no production credentials.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) walks through a first documentation change,
the local checks, and what a pull request needs before it can merge.

## Safety state

The configuration is deliberately import-first. No apply automation is enabled
until the production inventory has been imported and a reviewed plan reports
zero deletes and zero replacements.

The ownership decision and dependency boundary are recorded in
[`docs/adr/0001-cluster-independent-cloudflare-owner.md`](docs/adr/0001-cluster-independent-cloudflare-owner.md).

## Operating the live resources (maintainers)

Inventory, import, plan against the account, state handling, apply and
recovery are privileged procedures. They need short-lived Cloudflare and state
credentials from the maintainers' private custody and are not part of local
setup or of a first contribution. They are described in
[`docs/runbooks/bootstrap-and-recovery.md`](docs/runbooks/bootstrap-and-recovery.md).

In those procedures the provider reads `CLOUDFLARE_API_TOKEN`, and the state
backend reads the standard `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
variables. Keep all three out of shell history and repository files.

## Dependency updates

Dependabot proposes updates to the Cloudflare provider and to the GitHub
Actions this repository uses, as configured in `.github/dependabot.yml`. For
the provider it uses its OpenTofu support, which also refreshes the provider
checksums in `.terraform.lock.hcl`. Provider versions remain exact pins. A new
third-party release waits seven days before Dependabot proposes it as a version
update; the wait does not apply to Dependabot security updates, which GitHub
offers for the Actions but not for OpenTofu providers. Updates require the
existing CI and review gates and are never auto-merged.

The OpenTofu runtime stays on the reviewed 1.12.x line; no updater changes it.
Every provider proposal must pass `scripts/test.sh`, including the
destructive-plan guard. Dependency automation has no production credentials or
apply path.
