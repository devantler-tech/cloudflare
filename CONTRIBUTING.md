# Contributing to the Cloudflare configuration

You can help by making an explanation clearer, correcting a step in the
documentation, or tightening a check. Discuss a substantial change in an
[issue](https://github.com/devantler-tech/cloudflare/issues) first: this
configuration describes live DNS, storage and access tokens that the
portfolio's platform depends on. Report a sensitive vulnerability through this
repository's private
[Report a vulnerability](https://github.com/devantler-tech/cloudflare/security/advisories/new)
form, not in a public issue or pull request.

Nothing in this guide needs a Cloudflare account, an API token, state-backend
credentials or access to the maintainers' infrastructure.

## Make a first documentation change

You need Git, [OpenTofu](https://opentofu.org/docs/intro/install/) on the 1.12
line, [ShellCheck](https://github.com/koalaman/shellcheck#installing), `jq`, age,
a POSIX shell, and network access to `registry.opentofu.org` and to GitHub's
release downloads. There are no submodules.

Fork `devantler-tech/cloudflare` on GitHub. Replace `YOUR-LOGIN` with your
login:

```sh
git clone https://github.com/YOUR-LOGIN/cloudflare.git
cd cloudflare
git switch -c docs/first-contribution
```

Make a small wording improvement in `README.md` that leaves the commands and
the ownership rules as they are. Then, from the repository root, run the local
checks:

```sh
scripts/test.sh
git diff --check
```

`scripts/test.sh` exits 0 and prints `PASS: destructive OpenTofu plans fail
closed` and `Success! The configuration is valid.`; `git diff --check` prints
nothing. The [README](README.md#check-the-configuration-locally) explains what
the script covers, what it leaves behind and what it does not prove.

[CI](.github/workflows/ci.yaml) runs the same script. It also scans
`README.md` and `AGENTS.md` for links to retired repositories and checks that
scan against failing fixtures. You do not need to run that part locally.
Repeating it needs Go and a build of the released validator; `AGENTS.md`
describes how.

## Changing the configuration

Read [AGENTS.md](AGENTS.md) before changing a `.tf` file or a script. In
short:

- Keep provider versions as exact pins and stay on the OpenTofu 1.12 line.
- Keep `prevent_destroy` on the zone and on every R2 bucket.
- Never commit credentials, tokens, state, plan files, `backend.hcl` or
  `production.auto.tfvars` in plaintext. The narrow authenticated-ciphertext
  recovery exception is defined by `AGENTS.md` and the recovery package checker.
  The two `*.example` files contain placeholder values only.

This guide adds one expectation of its own: a change to
`scripts/assert-no-destructive-plan.sh` comes with a fixture under
`scripts/tests/fixtures/` and a case in
`scripts/tests/test-no-destructive-plan.sh` that fails without the change.

A pull request can only be checked for form and schema here. What it would
change in the live account is decided by a plan that a maintainer runs and
reads, so say in the pull request which resources you expect it to create or
update.

## What is not part of contributing

Inventory, import, planning against the account, applying, state migration and
recovery are maintainer operations with their own credentials and review. They
are described in the
[bootstrap and recovery runbook](docs/runbooks/bootstrap-and-recovery.md). Do
not run them to validate a pull request, and do not export
`CLOUDFLARE_API_TOKEN` or backend credentials for the local checks.

## Submit your change

Review the diff,
[configure commit signing](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)
and stage only the paths you changed. Use a [Conventional Commits](https://www.conventionalcommits.org)
subject that describes the outcome. For the README-only change above:

```sh
git add README.md
git commit -S -m "docs: clarify the local configuration check"
git push -u origin docs/first-contribution
```

Open a **draft** pull request to `devantler-tech/cloudflare:main` using the
inherited
[pull request template](https://github.com/devantler-tech/.github/blob/main/.github/PULL_REQUEST_TEMPLATE.md).
Keep Why and What focused on the problem and the outcome for the reader, link
the issue for substantial work, and put detailed validation evidence in a
comment. Say so if you used AI assistance.

Before a pull request merges, the required CI checks must pass, every review
conversation must be resolved, and a substantive review must have succeeded on
the exact current head, so a new push needs a new review. Pull requests are
squash-merged. Follow the inherited
[code of conduct](https://github.com/devantler-tech/.github/blob/main/.github/CODE_OF_CONDUCT.md)
and preserve the [Apache-2.0 license](LICENSE).
