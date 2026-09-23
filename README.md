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

`Fleet.lean` is the whole declaration: the `typednotes` system of
[`typednotes/typednotes`](https://github.com/typednotes/typednotes)'s `docs/architecture.md`,
as far as it is built — 31 Scaleway resources in one apply.

| Container | What | Database | Image |
|---|---|---|---|
| `typednotes-app` | the Dioxus fullstack app (`core`: users, orgs) | `typednotes-db` | `ghcr.io/typednotes/typednotes` |
| `ledger` | usage ledger — expired-hold sweeper, `/health` | `typednotes-db` | `ghcr.io/typednotes/ledger` |
| `liaison` | the broker — the egress chokepoint | `typednotes-db` | `ghcr.io/typednotes/liaison` |
| `secrets-server` | the vault | `secrets-db` | `ghcr.io/typednotes/secrets-server` |
| `db-inspector` | [pgweb](https://github.com/sosedoff/pgweb): browse and query `typednotes-db`, read-only, password-gated | `typednotes-db` | `docker.io/sosedoff/pgweb:0.17.0` |

Around them: one container namespace, two Serverless SQL databases, three IAM identities
(migrator / observer / runtime) with one minted API key each, seven composed connection strings,
six operator-supplied secrets, and **four migration histories**.

### Schemas are declared resources

No service migrates itself. Each service keeps its migrations as plain `.sql` files in its own
repository; `Fleet.lean` lists those files per service and `infra` reads them from GitHub at the
service's release tag when it plans (`github "typednotes/ledger" "v0.2.0" ["sql/0001_init.sql"]`),
declaring each as a `postgresMigrations` history. Nothing is copied here, and no service carries
anything but SQL for this.

```
typednotes-core-history ◀── typednotes-ledger-history     (its SQL references orgs, users)
typednotes-liaison-history
secrets-history
```

- **The plan names the work**: a pending migration is an `UPDATE` of its history.
- **Order comes from the SQL**, not a declaration (infra ≥ 0.14.0): ledger's tables
  `references orgs(id)`, so ledger's history applies after the app's. A reference to a table no
  history creates, or a table two histories create, is refused at `plan`.
- **Every rollout waits for the schemas it needs**: each container's `migrations` lists them. liaison
  writes ledger's tables — a dependency in its code, not its SQL — so its container waits for
  ledger's history as well as its own. A failed migration stops the rollout.
- **No serving identity can edit table structure**: DDL is the migrator's, used only by `apply`.
- **An applied migration can't be changed underneath you**: infra compares the SQL at the URL with
  what the database recorded when it applied it, and refuses a mismatch (e.g. a moved tag).

Each service has **one release value** in `Fleet.lean` (`ledgerRelease := "0.2.0"`, …) naming both
its image tag and the git tag its SQL is read at, so code and schema can't drift apart.
**Releasing a service** = publish its tag and image, bump its release value here, and add any new
migration file to its list — a diff that shows exactly which SQL will run.

Because the SQL is fetched at `plan`, the offline `check` verifies the declaration's shape (ids,
`https://` URLs) but not the SQL's content or the order it implies — it says so when it runs.

### The DB inspector

Scaleway's console has no query editor for Serverless SQL (only connection strings for `psql`), so
the fleet runs pgweb at the `db-inspector` container's URL. Three independent protections:

1. **HTTP basic auth** with a username and password *you* choose: `DB_INSPECTOR_USERNAME` /
   `DB_INSPECTOR_PASSWORD`, stored in Scaleway Secret Manager, never in this repo.
2. **A read-only database identity** (`ServerlessSQLDatabaseReadOnly`): even past the password,
   nothing can be changed — an `INSERT` fails with `permission denied`.
3. **`PGWEB_LOCK_SESSION`**: pgweb's "connect to another server" form is disabled, so it cannot be
   used as a proxy to other hosts.

It shows `typednotes-db` (app, ledger, liaison). The vault's database is deliberately not exposed —
it holds only ciphertext. pgweb's driver sends no TLS SNI, which Serverless SQL needs, so its
connection string carries `options=databaseid%3D<id>` instead (see below). All three protections were checked against the real `pgweb:0.17.0` image
and a local Postgres before this was committed.

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

`lakefile.lean` therefore requires `infra` at a tag rather than at `main` — currently
`v0.14.0` (migrations read from URLs and ordered by their SQL, container `migrations` lists, and
`namePrefixes`; 0.13.0 added the
`postgresMigrations` kind and made `libpq` a link-time dependency, so `libpq`/`pkg-config` must be
installed wherever this builds). Moving to a later release is a deliberate edit — bump the tag, run `lake update
infra`, read that release's entry in `infra`'s `CHANGELOG.md` — rather than something that
happens to this repo the next time CI runs.

Credentials come from `infra`'s three-source chain — the Scaleway CLI's own config file, the OS
keychain, then environment variables (see `infra`'s `docs/authentication.md`). Scaleway also
needs `default_project_id`.

## Deploying

**Before the first apply**, three things exist outside this repo:

1. **The release tags, pushed** — `infra` `v0.14.0` (then `lake update infra` here and commit
   `lake-manifest.json`), and the services' tags `typednotes` `v0.1.0`, `ledger` `v0.2.0`,
   `liaison` `v0.2.0`, `secrets` `v1.1.0`, whose `.sql` files `plan` reads and whose
   `docker-publish.yml` workflows build **the images**. Until a service's tag is pushed, `plan`
   stops with `HTTP 404 — is the tag or commit pushed, and the path right?`.
2. **The six values** behind `Fleet.lean`'s `fromEnv` secrets, read only when each secret is
   first created. These name variables, never values; nothing secret is committed.

   | Variable | What |
   |---|---|
   | `SECRETS_MASTER_KEY` | the vault's master key (`openssl rand -hex 32`). **Keep it durably** — losing it loses the vault's contents |
   | `SECRETS_BOOTSTRAP_PASSWORD` | the vault's initial `admin` password (read only while that user is absent) |
   | `LIAISON_ROOT_KEY` | the warrant root key (`openssl rand -hex 32`) |
   | `LIAISON_SECRETS_TOKEN` | liaison's token for the vault — a placeholder on the first deploy; see below |
   | `DB_INSPECTOR_USERNAME` | the DB inspector's basic-auth username — your choice |
   | `DB_INSPECTOR_PASSWORD` | the DB inspector's basic-auth password — make it long |

3. **An empty `secrets-db`.** The vault used to migrate itself with sqlx; the schema is now
   `secrets-history`'s, which will try to create `kv_store`. The existing database already has
   it, so **delete `secrets-db` in the Scaleway console first** (its contents were disposable —
   there were no users besides `admin`); the apply recreates it. (The old `secrets-db-app`,
   `secrets-db-key` and `secrets-db-url` are no longer declared, but that does **not** delete
   them from CI — see "Retiring a resource" below.)

Then:

```
export SECRETS_MASTER_KEY=... SECRETS_BOOTSTRAP_PASSWORD=... LIAISON_ROOT_KEY=... \
       LIAISON_SECRETS_TOKEN=placeholder DB_INSPECTOR_USERNAME=... DB_INSPECTOR_PASSWORD=...
lake exe typednotes-infra plan          # read this
lake exe typednotes-infra apply
```

### What the first live apply confirmed (2026-09-23)

The Scaleway facts this fleet depended on without a live run behind them:

- **`CREATE SCHEMA` works under `ServerlessSQLDatabaseReadWrite`**, although Scaleway's permission
  page lists only `CREATE TABLE`/`INDEX` for that set: all four histories created their
  `<schema>.infra_migrations` and recorded `0001`. So does `CREATE EXTENSION citext`.
- **Cross-identity access works.** Tables the migrator created are readable by the observer
  (`SELECT` on `orgs` and on every history table, while an `INSERT` is refused with `permission
  denied`) and usable by the runtime identity (the app answers `/api/orgs`; ledger's `/health` is
  `200` and its sweeper, which `UPDATE`s `credit_holds` every minute, has logged no failure).
  Writes by the runtime identity have not been exercised directly yet — creating an org in the app
  is the one-click check.

And one that nobody had predicted: **Serverless SQL routes connections by TLS SNI.** A client that
does not send the host name during the handshake is refused with `Database hostname wasn't sent to
server`. libpq (infra, ledger, liaison) and sqlx (app, vault) send it; pgweb's Go driver does not,
which is how `db-inspector` failed its first start. It now gets its own URL with the
`options=databaseid%3D<id>` parameter Scaleway asks for (`pgUrlWithoutSni` in `Fleet.lean`),
verified against the live database with pgweb before being declared.

### Removing a resource destroys it — from CI too

Since infra 0.15.0, what this fleet manages is whatever carries its marker in the account
(`managed-by-infra=typednotes`, or the `secrets-`/`typednotes-` name prefix for databases), found
by asking Scaleway on every `plan` and `apply`. The `.infra/` ledger is only a cache, and a CI
runner has none. So deleting a line from `Fleet.lean` destroys that resource on the next apply,
wherever it runs. And only resources carrying the marker are ever changed or destroyed: a declared
name held by something else is warned about and left alone.

The next apply therefore also deletes what earlier versions left behind when their lines were
removed: `secrets-db-app` (an IAM application with the DDL permission set), `secrets-db-key` (its
live API key — deleting the secret deletes the key), `secrets-db-url`, and
`typednotes-db-inspector-url` (composed with an empty user name by infra 0.14.0).

Because every kind the fleet's cloud offers is now listed on each run, the CI credentials need
**read access to every Scaleway product**, not only the ones declared here; a listing that fails
stops the run and names the product. (Scaleway queues are the exception: they are not listed
unless declared, because listing them mints a credential.)

### Known gap: liaison's vault token expires

`liaison` (v0) reads a static `SECRETS_TOKEN`. The vault issues tokens only by login, with a
one-hour TTL (`secrets-auth-userpass`), and liaison neither logs in nor renews — so any egress call
that needs a third-party credential fails closed an hour after the token was minted. Everything
else about liaison (warrant verification, holds, the audit log) is unaffected. Until liaison learns
to log in itself, deploy with a placeholder and treat credentialed egress as not yet available;
a real token can be minted with
`curl -X POST https://<secrets-server-url>/v1/auth/userpass/login -H 'content-type: application/json' -d '{"username":"admin","password":"…"}'`.

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
race the same resources, and does not need `SECRETS_MASTER_KEY` since destroying never creates
a secret. Deleting the minted API key needs no credential of its own: deleting the secret deletes
the key.

All three declare an `environment: production`; **add required reviewers to that environment in
Settings → Environments** if you want every apply or destroy to need a second pair of eyes. That
is the one gate the workflow files cannot enforce for themselves.

Repo secrets needed: `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID` and
`SCW_DEFAULT_ORGANIZATION_ID` for all three workflows, plus the six values behind `Fleet.lean`'s
`fromEnv` secrets for `apply.yml` only (`SECRETS_MASTER_KEY`, `SECRETS_BOOTSTRAP_PASSWORD`,
`LIAISON_ROOT_KEY`, `LIAISON_SECRETS_TOKEN`, `DB_INSPECTOR_USERNAME`, `DB_INSPECTOR_PASSWORD`),
needed only when those secrets are first created. The composed database URLs are never supplied
here; the engine builds them at apply time.

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

`apply.yml` checks all ten are non-empty **before** it touches anything, and names the missing
ones. That matters for the six `fromEnv` values in particular: they are not credentials, so
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
