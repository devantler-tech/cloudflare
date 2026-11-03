# Existing Email DNS import proposal

Run **Email DNS import proposal (encrypted, read-only)** from reviewed `main`
with the confirmation `PLAN_EMAIL_DNS`. It uses the existing repository
credential on a GitHub-hosted runner. It needs no new credential and performs
no provider apply or authoritative-state adoption.

The workflow reads the complete current DNS inventory, selects existing root
MX, SPF, DMARC, DKIM and Apple ownership records, and refuses ambiguous records
or competing controller ownership. Runtime-managed records and temporary
certificate challenges stay outside its ownership. Values, comments, tags and
provider settings are preserved. An absent comment stays absent; tags are
explicit when desired instead of being added by an import default.

The existing zone, independent state bucket and selected records are imported
only into a private local backend. The native provider plan must contain every
expected object with a known unchanged action. Creates, updates, deletes,
replacements, drift and deferred evaluation refuse the proposal. Existing
company Email routing is preserved throughout.

The one-day artifact contains an encrypted archive and a source/run binding
manifest. The archive includes the inventory, desired variables, import list,
saved native plan, JSON plan and bounded diagnostics. Authenticate its ciphertext
and plaintext checksums, then compare its internal source/run metadata against
the workflow before reviewing it with the independently held recovery identity.
Keep decrypted material in private temporary storage. A refused run publishes
only a separate encrypted diagnostic archive when capture is possible.

This package has a distinct proposal kind and cannot enter the state-bootstrap
apply path. A successful result proves a read-only import proposal. Authoritative
state adoption and Email routing changes remain separate reviewed steps, with
transport and recovery acceptance required before routing moves.
