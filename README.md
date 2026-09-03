# Typednotes Infra Declaration

Real infrastructure, declared as Lean 4 values using
[`infra`](https://github.com/typednotes/infra) — a Terraform/OpenTofu-style tool where target
and observed cloud state are Lean values rather than a bespoke DSL, and dependent types make
impossible states unrepresentable. This repo is the *consumer*: it declares one project's actual
fleet. `infra` is the reusable engine, the provider backends, and the `plan`/`push` machinery.

**This performs real, billable cloud actions and can create, modify, or delete real resources.**
`check` never touches a network. `plan`/`push` (without `--apply`) pull live state and print what
would change, but change nothing. `push --apply` is the only command that mutates anything — and
only the resources named in `Fleet.lean`: a `(provider, kind)` pair not listed there, or a name
not listed under a pair that is, has no key for the plan to mention and is left alone
unconditionally.

## What's declared

`Fleet.lean` is the whole declaration. It manages five Scaleway resources:

| | |
|---|---|
| `secrets-server` | a Serverless Container running [`secrets`](https://github.com/typednotes/secrets) |
| `secrets-db` | a serverless Postgres database backing it |
| `secrets-master-key` | the container's own master key |
| `secrets-db-password` | the database's master password |
| `secrets-db-url` | the connection string, composed at apply time |

Scaleway only, so AWS is never authenticated and never called — both facts are
`#guard`ed in `Fleet.lean` rather than assumed.

### One apply, not two

`secrets-db-url`'s value needs the master password *and* the endpoint Scaleway assigns when the
database is created. That used to mean two `push --apply` runs with an operator pasting a
connection string in between. `Fleet.lean` now declares the *function* instead, with `composed`
over `.secretValue` and `.observed`; `infra` orders the password and the database before it and
evaluates it once, at apply time. The value never enters this repo, the plan output, or the
`.infra/` cache.

So the whole fleet deploys in a single apply:

```
would CREATE scaleway/secrets/secrets-master-key
would CREATE scaleway/secrets/secrets-db-password
would CREATE scaleway/postgres/secrets-db
would CREATE scaleway/secrets/secrets-db-url
would CREATE scaleway/scaleway-container/secrets-server
```

A composed secret is **create-only**: no cloud reports a secret's value, so it can never be
diffed, and a second apply asks for nothing. Rotating one is an explicit act, not a
reconciliation.

## Building and running

```
lake build                       # compile only; no network, no credentials
lake exe typednotes-infra check  # offline checks (also: bare `lake exe typednotes-infra`)
lake exe typednotes-infra pull   # observe Scaleway and cache to .infra/ — needs credentials
lake exe typednotes-infra plan   # what would change — needs credentials, changes nothing
lake exe typednotes-infra push   # same as plan — a dry run
lake exe typednotes-infra push --apply   # actually reconcile — the only mutating command
```

`lake build` only compiles. `plan` and `push` are `infra`'s, called from here and from CI.

Credentials come from `infra`'s three-source chain — the Scaleway CLI's own config file, the OS
keychain, then environment variables (see `infra`'s `docs/authentication.md`). Scaleway also
needs `default_project_id`.

## Deploying

Before the first apply, two things exist outside this repo:

1. **The container image**, at `rg.fr-par.scw.cloud/typednotes/secrets-server:latest`. The
   `secrets` repo's `docker-publish.yml` mirrors it there from GHCR on a tagged release, which
   needs an `SCW_SECRET_KEY` secret on *that* repo. The image is mirrored rather than pulled
   from `ghcr.io` directly because Scaleway's docs discourage external registries for production
   and do not support private ones at all — neither half confirmed live; see `infra`'s
   `docs/providers.md`.
2. **The two env vars the secrets read**: `SECRETS_MASTER_KEY` and `SECRETS_DB_PASSWORD`. These
   name variables, never values — nothing secret is committed here. Generate them, export them,
   and keep the master key somewhere durable: losing it means losing what the server encrypted.

Then review the plan and apply:

```
export SECRETS_MASTER_KEY=...  SECRETS_DB_PASSWORD=...
lake exe typednotes-infra plan          # read this
lake exe typednotes-infra push --apply
```

## CI

`.github/workflows/plan.yml` runs `check` on every push and pull request, and additionally posts
a live `plan` to the run summary on pushes to `main`. It **never** applies: that stays a
deliberate, human-triggered step. The live plan step needs `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`,
`SCW_DEFAULT_REGION` and `SCW_DEFAULT_PROJECT_ID` as repo secrets.

## Notes

`lakefile.lean` duplicates ~80 lines of platform-conditional link flags from `infra`'s own
lakefile. That is not an oversight: Lake does not propagate a dependency's `moreLinkArgs` to a
dependent's executable, and a lakefile cannot import a dependency's modules, so the computation
has to be repeated. Keep the two copies in step.
