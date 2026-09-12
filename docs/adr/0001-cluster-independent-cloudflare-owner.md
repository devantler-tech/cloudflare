# ADR 0001: Own Cloudflare bootstrap infrastructure outside Kubernetes

- Status: Accepted
- Date: 2026-09-12

## Context

The platform consumes Cloudflare DNS, certificate, and R2 capabilities, but the
Cloudflare account resources must already exist before Flux, Crossplane, and
their secret consumers can start. Managing those resources through Crossplane
would make recovery depend on the system being recovered.

The portfolio also requires tenant workloads to move quickly within
platform-owned boundaries. Release revisions are tenant state; shared DNS,
storage, credentials, and privilege scopes are platform boundaries.

## Decision

`devantler-tech/cloudflare` is the OpenTofu owner for pre-platform Cloudflare
resources. It uses GitHub-hosted execution and an R2 S3-compatible state backend,
both independent of the Kubernetes cluster. Existing resources are imported
before apply authority is enabled, and the migration plan must contain no
deletes or replacements.

The platform repository continues to own in-cluster Cloudflare consumers and
tenant capability policy. Tenants may roll their signed releases forward under
the approved publication identity and repository boundary without platform
revision pins.

## Consequences

Disaster recovery can rebuild Cloudflare state without a working cluster. The
state bucket is a bootstrap exception: it is created or imported using local
state, protected from destruction, and then becomes its own remote backend.
Token values remain sensitive state and must be transferred directly into an
approved custody system that is also reachable during a full platform outage.

