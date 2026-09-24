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
as far as it is built — 45 Scaleway resources in one apply.

| Container | What | Database | Image |
|---|---|---|---|
| `typednotes-app` | the Dioxus fullstack app (`core`: sign-in, users, orgs, projects, connections, messaging webhooks) | `typednotes-db` | `ghcr.io/typednotes/typednotes` |
| `ledger` | usage ledger — expired-hold sweeper, `/health` | `typednotes-db` | `ghcr.io/typednotes/ledger` |
| `liaison` | the broker — the egress chokepoint | `typednotes-db` | `ghcr.io/typednotes/liaison` |
| `secrets-server` | the vault | `secrets-db` | `ghcr.io/typednotes/secrets-server` |
| `db-inspector` | [pgweb](https://github.com/sosedoff/pgweb): browse and query `typednotes-db`, read-only, password-gated | `typednotes-db` | `docker.io/sosedoff/pgweb:0.17.0` |

Around them: one container namespace, two Serverless SQL databases, three IAM identities
(migrator / observer / runtime) with one minted API key each, seven composed connection strings,
twenty operator-supplied secrets, and **four migration histories**.

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
lake exe typednotes-infra plan   # what would change — needs credentials, changes nothing
lake exe typednotes-infra apply  # actually reconcile — the only mutating command
lake exe typednotes-infra dump   # what the fleet sees in the account, as JSON (no secret values)
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

## Secrets to set

Everything this fleet needs from you, in one place. Set each as a **GitHub repository secret**
(Settings → Secrets and variables → Actions) for CI, or export it under the **environment name**
for a local `plan`/`apply`. `apply.yml` checks that all twenty-four are non-empty before it touches
anything, and names any that are missing.

**Scaleway credentials** — read by every workflow (`plan.yml`, `apply.yml`, `destroy.yml`):

| Repo secret | What |
|---|---|
| `SCW_ACCESS_KEY` | API key access key. Needs read access to every Scaleway product (see "Removing a resource destroys it"), plus write on what the fleet manages |
| `SCW_SECRET_KEY` | that API key's secret key |
| `SCW_DEFAULT_PROJECT_ID` | the project the fleet lives in |
| `SCW_DEFAULT_ORGANIZATION_ID` | the organization, which the account guard checks (`accounts` in `Main.lean`) |

**Fleet values** — read by `apply.yml` only, behind `Fleet.lean`'s `fromEnv` secrets. Each is
read **only when its Scaleway secret is first created**; changing it later does nothing until
that secret is deleted and recreated. Nothing here is committed.

| Repo secret | Environment name | What · how to make it |
|---|---|---|
| `SECRETS_MASTER_KEY` | same | the vault's master key: `openssl rand -hex 32`. **Keep a durable copy** — losing it loses everything the vault holds |
| `SECRETS_BOOTSTRAP_PASSWORD` | same | the vault's initial `admin` password (used only while that user is absent). Also needed by `scripts/vault-bootstrap.sh` |
| `LIAISON_ROOT_KEY` | same | the warrant root key, shared by the app (mints) and liaison (verifies): `openssl rand -hex 32` |
| `APP_SECRETS_PASSWORD` | same | the app's vault password, user `typednotes-app`, ≥ 16 characters: `openssl rand -base64 32`. **Give the same value to `scripts/vault-bootstrap.sh`** |
| `LIAISON_SECRETS_PASSWORD` | same | liaison's vault password, user `liaison`, ≥ 16 characters. **Same value to `scripts/vault-bootstrap.sh`** |
| `OAUTH_GITHUB_CLIENT_ID` | `GITHUB_CLIENT_ID` | a [GitHub OAuth App](https://github.com/settings/developers)'s client id: sign-in and the `github` connection. Callback URL `https://app.typednotes.com/auth/github/callback` |
| `OAUTH_GITHUB_CLIENT_SECRET` | `GITHUB_CLIENT_SECRET` | that OAuth App's client secret |
| `GOOGLE_CLIENT_ID` | same | a Google Cloud OAuth client (type *Web application*, Google Drive API enabled): sign-in and the `gdrive` connection. Authorized redirect URI `https://app.typednotes.com/auth/google/callback`. liaison uses it to refresh Drive tokens |
| `GOOGLE_CLIENT_SECRET` | same | that OAuth client's secret |
| `GITLAB_CLIENT_ID` | same | a [gitlab.com application](https://gitlab.com/-/user_settings/applications) (confidential, scopes `read_user read_api read_repository write_repository`): the `gitlab` connection. Redirect URI `https://app.typednotes.com/auth/gitlab/callback`. liaison uses it to refresh GitLab tokens |
| `GITLAB_CLIENT_SECRET` | same | that application's secret |
| `DROPBOX_CLIENT_ID` | same | a [Dropbox app](https://www.dropbox.com/developers/apps)'s app key (scoped access; `account_info.read` plus the `files.*` scopes you want): the `dropbox` connection. Redirect URI `https://app.typednotes.com/auth/dropbox/callback`. liaison uses it to refresh Dropbox tokens |
| `DROPBOX_CLIENT_SECRET` | same | that app's app secret |
| `SLACK_CLIENT_ID` | same | a [Slack app](https://api.slack.com/apps)'s client id: installing it in a workspace is the `slack` connection. Redirect URL `https://app.typednotes.com/auth/slack/callback`; bot scopes `chat:write chat:write.public channels:read groups:read channels:history groups:history im:history`; **token rotation off** |
| `SLACK_CLIENT_SECRET` | same | that app's client secret |
| `SLACK_SIGNING_SECRET` | same | that app's signing secret. Event Subscriptions request URL `https://app.typednotes.com/hooks/slack`, bot events `message.channels`, `message.groups`, `message.im` |
| `WHATSAPP_APP_SECRET` | same | the app secret of the [Meta app](https://developers.facebook.com/apps) with the WhatsApp product: it signs webhook deliveries. Webhook callback URL `https://app.typednotes.com/hooks/whatsapp`, field `messages` |
| `WHATSAPP_VERIFY_TOKEN` | same | a token of your choice, entered as that webhook's verify token: `openssl rand -hex 16` |
| `DB_INSPECTOR_USERNAME` | same | the DB inspector's basic-auth username — your choice |
| `DB_INSPECTOR_PASSWORD` | same | the DB inspector's basic-auth password — make it long |

GitHub refuses repository secrets whose names start with `GITHUB_`, so the GitHub OAuth client
is stored as `OAUTH_GITHUB_CLIENT_*` and `apply.yml` exports it under the names `Fleet.lean`
reads. The callbacks use the app's custom domain (`appPublicUrl` in `Fleet.lean`), which you
attach after the first apply — see "Custom domain".

**Not secrets you set:** the database connection strings and API keys are minted and composed
by the apply itself, and the vault's service users are created by `scripts/vault-bootstrap.sh`
(see "Vault service identities") from the values above.

**Safe to delete** if still set: `LIAISON_SECRETS_TOKEN` (replaced by
`LIAISON_SECRETS_PASSWORD`) and `SCW_DEFAULT_REGION` (the region comes from `in paris`).

## Deploying

**Before the first apply**, three things exist outside this repo:

1. **The release tags, pushed** — `infra` `v0.14.0` (then `lake update infra` here and commit
   `lake-manifest.json`), and the services' tags `typednotes` `v0.3.0`, `ledger` `v0.3.0`,
   `liaison` `v0.4.0`, `secrets` `v1.2.0`, whose `.sql` files `plan` reads and whose
   `docker-publish.yml` workflows build **the images**. Until a service's tag is pushed, `plan`
   stops with `HTTP 404 — is the tag or commit pushed, and the path right?`.
2. **The twenty-four secrets** of "Secrets to set" above — the four Scaleway credentials and the
   twenty values behind `Fleet.lean`'s `fromEnv` secrets.

3. **An empty `secrets-db`.** The vault used to migrate itself with sqlx; the schema is now
   `secrets-history`'s, which will try to create `kv_store`. The existing database already has
   it, so **delete `secrets-db` in the Scaleway console first** (its contents were disposable —
   there were no users besides `admin`); the apply recreates it. (The old `secrets-db-app`,
   `secrets-db-key` and `secrets-db-url` are no longer declared, but that does **not** delete
   them from CI — see "Retiring a resource" below.)

Then:

```
export SECRETS_MASTER_KEY=... SECRETS_BOOTSTRAP_PASSWORD=... LIAISON_ROOT_KEY=... \
       APP_SECRETS_PASSWORD=... LIAISON_SECRETS_PASSWORD=... \
       GITHUB_CLIENT_ID=... GITHUB_CLIENT_SECRET=... GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... \
       GITLAB_CLIENT_ID=... GITLAB_CLIENT_SECRET=... DROPBOX_CLIENT_ID=... DROPBOX_CLIENT_SECRET=... \
       SLACK_CLIENT_ID=... SLACK_CLIENT_SECRET=... SLACK_SIGNING_SECRET=... \
       WHATSAPP_APP_SECRET=... WHATSAPP_VERIFY_TOKEN=... \
       DB_INSPECTOR_USERNAME=... DB_INSPECTOR_PASSWORD=...
lake exe typednotes-infra plan          # read this
lake exe typednotes-infra apply
SECRETS_URL=https://<secrets-server domain> scripts/vault-bootstrap.sh   # once; see below
```

Then attach the custom domain (next section) and register the callback URLs with GitHub,
Google, GitLab, Dropbox and Slack, and the webhook URLs with Slack and Meta. Until both are
done, everything works except sign-in, those connections and inbound messages.

### Custom domain

The app is served at **`https://app.typednotes.com`**. `infra` has no DNS or container-domain kind
yet (DNS is under "Not in this version" in its `docs/coverage.md`), so the domain is attached by
hand, once, with the [`scw` CLI](https://www.scaleway.com/en/cli/). The `typednotes.com` zone is in
Scaleway Domains & DNS:

```sh
# the app container's id and its Scaleway domain (after the first apply)
scw container container list name=typednotes-app -o json | jq -r '.[0] | .id, .domain_name'

# point app.typednotes.com at it — a CNAME, hence a subdomain, not the bare typednotes.com
scw dns record add typednotes.com name=app type=CNAME data=<domain_name>. ttl=300

# tell Serverless Containers to answer for it; Scaleway issues the TLS certificate
scw container domain create container-id=<id> hostname=app.typednotes.com
scw container domain list container-id=<id>     # wait for status "ready"
```

Then register the callbacks — `https://app.typednotes.com/auth/{github,google,gitlab,dropbox,slack}/callback`
in each provider's app — and the webhooks: `https://app.typednotes.com/hooks/slack` as the Slack
app's Event Subscriptions request URL (Slack sends a challenge the app answers), and
`https://app.typednotes.com/hooks/whatsapp` as the Meta app's WhatsApp webhook, with
`WHATSAPP_VERIFY_TOKEN` as its verify token. The exact settings for each are in "Secrets to set".

How this sits next to the fleet:

- **`PUBLIC_URL`.** `Fleet.lean` sets the app's `PUBLIC_URL` to `appPublicUrl`, and the app builds
  every OAuth redirect URI from it, whichever host the request came in on. A visitor on the
  Scaleway domain is therefore signed in through the registered `app.typednotes.com` callbacks and
  ends up there. Before the domain is attached those callbacks do not resolve, so sign-in fails and
  nothing else does. To serve somewhere else, change `appPublicUrl`: `env` is compared on apply,
  so that alone redeploys the app.
- **Infra leaves it alone.** It lists neither DNS records nor container domains, so no `plan` or
  `apply` touches or reports them.
- **Updates keep it.** Releases update the container in place and keep its id, so the binding
  survives image bumps.
- **A recreated container loses it.** If `typednotes-app` is ever destroyed and created again (a
  `destroy`, or a change `infra` can only apply by replacement), its id and Scaleway domain
  change. Delete the stale domain and record, then re-run the three commands.

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
by asking Scaleway on every `plan` and `apply`. Since 0.16.0 nothing is stored locally at all —
no ledger, no cache — so a CI runner and a laptop reach the same plan. Deleting a line from `Fleet.lean` destroys that resource on the next apply,
wherever it runs. And only resources carrying the marker are ever changed or destroyed: a declared
name held by something else is warned about and left alone.

The next apply therefore also deletes what earlier versions left behind when their lines were
removed: `secrets-db-app` (an IAM application with the DDL permission set), `secrets-db-key` (its
live API key — deleting the secret deletes the key), `secrets-db-url`, and
`typednotes-db-inspector-url` (composed with an empty user name by infra 0.14.0).

Because every kind the fleet's cloud offers is now listed on each run, the CI credentials need
**read access to every Scaleway product**, not only the ones declared here; a listing that fails
stops the run and names the product. That includes Queues: listing them needs infra's own SQS
credential, which infra mints once and keeps in the unmarked secret `infra-sqs-credential` (no
fleet claims it; deleting it costs one mint), so the key also needs Queues credential management
and Secret Manager read/write.

Since infra 0.17.0, `forget scaleway <kind> "<name>"` removes this fleet's marker on the next apply
(`RELEASE` in the plan) instead of having to stay in `Fleet.lean` forever; once released, the line
can be deleted and the resource is left alone. (Databases carry their marker in their name, so a
forgotten database's line has to stay.) AWS is named in `accounts` but declares nothing: runs with
AWS credentials scan it for anything this fleet left there; without them, a note says it was not
scanned. Drop it from `accounts` if the fleet has nothing left on AWS.

### Vault service identities

The app and liaison each log in to the vault as their own `userpass` user and log in again before
the hour-long token expires (`typednotes/typednotes` `docs/connections.md` §4). That replaces the
static `liaison-secrets-token`, which expired an hour after it was minted; the next apply deletes
that secret.

The users live in the vault, not in Scaleway, so they are created once — after the vault is up
(`secrets` ≥ 1.2.0, which adds the users endpoint) — by `scripts/vault-bootstrap.sh`, logged in as
`admin`:

| user | policy on `secret/data/thirdparty/` |
|---|---|
| `typednotes-app` | `create`, `delete` — it stores credentials but can never read them back |
| `liaison` | `read`, plus `create` to write back a refreshed Google token |

```
SECRETS_URL=https://<secrets-server domain> SECRETS_BOOTSTRAP_PASSWORD=... \
APP_SECRETS_PASSWORD=... LIAISON_SECRETS_PASSWORD=... scripts/vault-bootstrap.sh
```

The two passwords must equal the `app-secrets-password` / `liaison-secrets-password` values given to
`apply`. Re-running the script is safe, and is also how to rotate them — then delete and recreate
the two Scaleway secrets (secrets are create-only) and redeploy. Until the script has run, the app
shows connections as failing to store, and liaison answers `credential_unavailable`.

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

Repo secrets needed: the full list, with what each is and how to make it, is
["Secrets to set"](#secrets-to-set) — the four `SCW_*` credentials for all three workflows, and
the twenty fleet values for `apply.yml` only. The composed database URLs are never supplied
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

`apply.yml` checks all twenty-four are non-empty **before** it touches anything, and names the missing
ones. That matters for the twenty `fromEnv` values in particular: they are not credentials, so
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
