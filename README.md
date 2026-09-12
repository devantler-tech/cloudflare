# cloudflare

Declarative, cluster-independent ownership of devantler-tech Cloudflare
infrastructure.

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

## Safety state

The configuration is deliberately import-first. No apply automation is enabled
until the production inventory has been imported and a reviewed plan reports
zero deletes and zero replacements. CI validates formatting, provider schemas,
shell safety, and the destructive-plan guard without production credentials.

Start with [`docs/runbooks/bootstrap-and-recovery.md`](docs/runbooks/bootstrap-and-recovery.md).
The ownership decision and dependency boundary are recorded in
[`docs/adr/0001-cluster-independent-cloudflare-owner.md`](docs/adr/0001-cluster-independent-cloudflare-owner.md).

## Local validation

```sh
scripts/test.sh
```

`CLOUDFLARE_API_TOKEN` is read by the provider. Backend credentials use the
standard `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` variables. Keep all
three out of shell history and repository files.

