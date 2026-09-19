# Typednotes Infra Declaration

Real infrastructure, declared as Lean 4 values using
[`infra`](https://github.com/typednotes/infra) — a Terraform/OpenTofu-style tool where target
and observed cloud state are Lean values rather than a bespoke DSL, and dependent types make
impossible states unrepresentable. This repo is the *consumer*: it declares one project's actual
fleet. `infra` is the reusable engine, the provider backends, and the `plan`/`apply` machinery.

**This performs real, billable cloud actions and can create, modify, or delete real resources.**
`check` never touches a network. `plan` pulls live state and prints what
would change, but change nothing. `apply` is the only command that mutates anything — and
only the resources named in `Fleet.lean`: a `(provider, kind)` pair not listed there, or a name
not listed under a pair that is, has no key for the plan to mention and is left alone
unconditionally.

## What's declared

`Fleet.lean` is the whole declaration. It manages six Scaleway resources:

| | |
|---|---|
| `secrets-server` | a Serverless Container running [`secrets`](https://github.com/typednotes/secrets) |
| `secrets-db` | a serverless Postgres database backing it |
| `secrets-master-key` | the container's own master key |
| `secrets-db-iam-access-key` | access key half of the IAM API key the database authenticates |
| `secrets-db-iam-secret-key` | secret key half of that API key |
| `secrets-db-url` | the connection string, composed at apply time |
| `typednotes` | the Serverless Containers namespace the container is placed into |

Scaleway only, so AWS is never authenticated and never called — both facts are
`#guard`ed in `Fleet.lean` rather than assumed.

### One apply, not two

`secrets-db-url`'s value needs the master password *and* the endpoint Scaleway assigns when the
database is created. That used to mean two `apply` runs with an operator pasting a
connection string in between. `Fleet.lean` now declares the *function* instead, with `composed`
over `.secretValue` and `.observed`; `infra` orders the password and the database before it and
evaluates it once, at apply time. The value never enters this repo, the plan output, or the
`.infra/` cache.

So the whole fleet deploys in a single apply:

```
would CREATE scaleway/secrets/secrets-master-key
would CREATE scaleway/secrets/secrets-db-iam-access-key
would CREATE scaleway/secrets/secrets-db-iam-secret-key
would CREATE scaleway/postgres/secrets-db
would CREATE scaleway/scaleway-container-namespace/typednotes
would CREATE scaleway/secrets/secrets-db-url
would CREATE scaleway/scaleway-container/secrets-server
```

The namespace is declared rather than assumed. Serverless Containers will not
place a container into a namespace that does not exist, and `namespace'` is a
*reference*, so it is created first and cannot be misspelled — that used to
fail at apply time with `no namespace named 'typednotes'`.

A composed secret is **create-only**: no cloud reports a secret's value, so it can never be
diffed, and a second apply asks for nothing. Rotating one is an explicit act, not a
reconciliation.

## Building and running

```
lake build                       # compile only; no network, no credentials
lake exe typednotes-infra check  # offline checks (also: bare `lake exe typednotes-infra`)
lake exe typednotes-infra refresh  # observe Scaleway and cache to .infra/ — needs credentials
lake exe typednotes-infra plan   # what would change — needs credentials, changes nothing
lake exe typednotes-infra apply  # actually reconcile — the only mutating command
```

`lake build` only compiles. `plan` and `apply` are `infra`'s, called from here and from CI.

`Main.lean` is one call: it hands `Fleet.lean`'s `typednotes` — the whole declaration, keys,
plan, `in paris` placement and releases in a single value — to `Infra.Cli.run`, together with
this repo's offline check and the accounts it is for. That shape needs **infra ≥ 0.9.0**; before
it the front end took the plan, the placement and the releases as three separate arguments, and
nothing stopped a call from handing over one and forgetting another.

`lakefile.lean` therefore requires `infra` at the tag `v0.9.0` rather than at `main`. Moving to a
later release is a deliberate edit — bump the tag, run `lake update infra`, read that release's
entry in `infra`'s `CHANGELOG.md` — rather than something that happens to this repo the next time
CI runs.

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
2. **The three env vars the secrets read**: `SECRETS_MASTER_KEY`, `SECRETS_DB_IAM_ACCESS_KEY`
   and `SECRETS_DB_IAM_SECRET_KEY`. These name variables, never values — nothing secret is
   committed here. Generate the master key and keep it somewhere durable: losing it means losing
   what the server encrypted.

   The two `..._IAM_...` values are **one Scaleway API key**, not a database password. Serverless
   SQL Database has no master user — it authenticates the connection through IAM — so the key's
   principal must hold the project-scoped `ServerlessSQLDatabaseDataReadWrite` permission set.
   `AllProductsFullAccess` is *not* enough: it covers managing databases, not connecting to one,
   which is why an org-admin key is refused with `password authentication failed`.

Then review the plan and apply:

```
export SECRETS_MASTER_KEY=...  SECRETS_DB_IAM_ACCESS_KEY=...  SECRETS_DB_IAM_SECRET_KEY=...
lake exe typednotes-infra plan          # read this
lake exe typednotes-infra apply
```

## CI

Three workflows, split so that nothing which changes a cloud can be reached from a commit.

**`plan.yml`** runs `check` on every push and pull request, and additionally posts a live `plan`
to the run summary on pushes to `main`. It never applies.

**`apply.yml`** is the manual apply. Its only trigger is `workflow_dispatch` — there is no push
trigger to mis-condition — and it asks you to type `typednotes` to confirm. It runs the offline
checks, prints the plan it is about to apply, applies via `lake script run apply --yes`, then
prints the state afterwards (a clean apply leaves `nothing to do`). Concurrent runs queue rather
than race.

**`destroy.yml`** is the manual teardown — `apply` against an empty declaration, in `infra`'s own
terms. Also `workflow_dispatch`-only, and its confirmation phrase is `destroy typednotes` rather
than `typednotes`, so it cannot be triggered by muscle memory from running `apply`. It prints what
is about to be deleted (`plan --destroy`), destroys, then prints the teardown plan again (a clean
teardown leaves `nothing to do`). It shares `apply.yml`'s concurrency group, so the two can never
race the same resources, and needs neither `SECRETS_MASTER_KEY` nor either `SECRETS_DB_IAM_*`
value since destroying never creates a secret.

All three declare an `environment: production`; **add required reviewers to that environment in
Settings → Environments** if you want every apply or destroy to need a second pair of eyes. That
is the one gate the workflow files cannot enforce for themselves.

Repo secrets needed: `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID` and
`SCW_DEFAULT_ORGANIZATION_ID` for all three workflows, plus `SECRETS_MASTER_KEY`,
`SECRETS_DB_IAM_ACCESS_KEY` and `SECRETS_DB_IAM_SECRET_KEY` for `apply.yml` only — the values
behind the three `fromEnv` secrets in `Fleet.lean`, needed only when those are first created. The composed database URL is never
supplied here; the engine builds it at apply time.

`SCW_DEFAULT_ORGANIZATION_ID` is what `checkAccounts` uses to establish which Scaleway
organization the credentials belong to (see `accounts` in `Main.lean`) — without it the API
key's own record is asked instead, but a CI runner's key may not have permission to read that,
in which case the account guard fails closed with "could not establish which scaleway account
these credentials belong to" rather than skip the check.

`SCW_DEFAULT_REGION` **is no longer one of them.** `Fleet.lean` declares `in paris`, so `infra`
builds every Scaleway endpoint from the declaration rather than the environment. It was the one
secret that was not a secret, and having it there meant CI could quietly run against a region
other than the `fr-par` in the container image's own URL — the account guard checks the
organization, not the place. The secret can be deleted; leaving it set does nothing.

`apply.yml` checks all five are non-empty **before** it touches anything, and names the missing
ones. That matters for the two `SECRETS_*` values in particular: they are not credentials, so
nothing else would notice they were absent until the backend tried to create that secret —
which is after the database already exists, leaving a half-applied fleet.

Both workflows also point OpenSSL at the runner's CA bundle (`SSL_CERT_FILE`/`SSL_CERT_DIR`).
Without it, any live call fails with `certificate verify failed`: Lean's toolchain bundles a
static OpenSSL whose compile-time trust-store path does not exist on a runner. See `infra`'s
`docs/authentication.md`.

## Notes

`lakefile.lean` duplicates ~80 lines of platform-conditional link flags from `infra`'s own
lakefile. That is not an oversight: Lake does not propagate a dependency's `moreLinkArgs` to a
dependent's executable, and a lakefile cannot import a dependency's modules, so the computation
has to be repeated. Keep the two copies in step.
