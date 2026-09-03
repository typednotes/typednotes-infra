# Typednotes Infra Declaration

Real infrastructure, declared as Lean 4 values using
[`infra`](https://github.com/typednotes/infra) — a Terraform/OpenTofu-style tool where target
and observed cloud state are Lean values rather than a bespoke DSL, and dependent types make
impossible states unrepresentable. This repo is the *consumer*: it declares one project's actual
fleet across AWS and Scaleway; `infra` is the reusable engine and provider backends.

**This performs real, billable cloud actions and can create, modify, or delete real resources.**
`check` never touches a network. `plan`/`push` (without `--apply`) pull live state and print what
would change, but never change anything. `push --apply` is the only command that mutates
anything, and only in fine, and only in the fields this repo's `Plan` actually declares — a
`(provider, kind)` pair or a resource name never listed here is left alone, unconditionally (see
`infra`'s `docs/architecture.md`, "Declaring a fleet").

## What's declared

`Fleet.lean` declares the whole fleet via `infra`'s ergonomic combinators
(`Infra.Core.Ergonomics.Keys.build`/`Keys.assignFromNamed`) rather than hand-rolled `inductive`
key types. It currently manages **nothing** — every `(provider, kind)` pair is `.unused` — which
is a real, valid target (leaves every existing resource in both accounts alone), not a
placeholder. The first real target, `secrets-server`, is being added; see below.

## Building and running

```
lake build                       # compile everything; no network, no credentials
lake exe typednotes-infra check  # offline self-checks (also: bare `lake exe typednotes-infra`)
lake exe typednotes-infra pull   # observe both clouds, cache to .infra/ — needs credentials
lake exe typednotes-infra plan   # what would change — needs credentials, changes nothing
lake exe typednotes-infra push   # same as plan — a dry run
lake exe typednotes-infra push --apply   # actually reconcile — the only mutating command
```

`lake script run check` / `lake script run plan` are equivalent one-word aliases. Bare
`lake build` cannot itself print a plan — see the comment above the scripts in `lakefile.lean`
for why that was deliberately not built as a custom build target.

Credentials come from `infra`'s three-source chain (CLI config files, OS keychain, then
environment variables — see `infra`'s `docs/authentication.md`); Scaleway additionally needs
`default_project_id`, `iam` needs `default_organization_id`.

## Dependency on `infra`

`lakefile.lean` currently `require`s `infra` from a local relative path (`../infra`) rather than
git, so this repo always builds against whatever is on disk in a sibling `infra` checkout —
including work not yet pushed to `infra`'s `main`. This is a **temporary, local-development-only**
setup: it will not resolve on a machine (or CI runner) that does not have that sibling checkout.
Before relying on a fresh clone or CI, this needs to switch to:

```
require infra from git "https://github.com/typednotes/infra" @ "main"
```

which needs `infra`'s own `main` branch to actually carry whatever this repo currently depends
on.

## CI

Deployment on push to `main` is planned (GitHub Actions, applying on merge) but not yet wired up
— tracked alongside the `secrets-server` deployment work.
