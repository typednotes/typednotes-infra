# Typednotes Infra Declaration

Real infrastructure, declared as Lean 4 values using
[`infra`](https://github.com/typednotes/infra/tree/main) — a Terraform/OpenTofu-style tool where target
and observed cloud state are Lean values rather than a bespoke DSL, and dependent types make
impossible states unrepresentable. This repo is the *consumer*: it declares one project's actual
fleet. `infra` is the reusable engine, the provider backends, and the `plan`/`apply` machinery.

**This performs real, billable cloud actions and can create, modify, or delete real resources.**
`check` never touches a network. `plan` pulls live state and prints what
would change, but changes nothing. `apply` reconciles the selected fleet;
`destroy` tears it down. Ownership markers scope both operations, including
retiring resources removed from the declaration. Lite and `full-from-lite`
share durable resource identities. The original `full` fleet remains independent.

## Lite deployment (default)

**Release 0.10.1** fixes worker startup and promoted vault connectivity, shares
storage/bundle construction, and persists the workflow topology with downgrade
protection. See [the release notes](docs/release-0.10.1.md).

The local CLI defaults to **`lite`**. CI **Apply**, **Plan** and **Destroy** default
to **`current`**, using repository variable `TYPEDNOTES_DEPLOYMENT` (Lite when unset).
Push-triggered plans use that same persisted topology and, for promoted full,
the `TYPEDNOTES_LITE_IMAGE` repository pin.
Lite deploys the published combined image (built and published from the
services' stable release tags by the
[typednotes-lite repository](https://github.com/typednotes/typednotes-lite))
as **one warm Serverless Container and two
Serverless SQL databases**. App, ledger and audit histories share the application
database; the vault and its migration history use a separate database.
The container has 4 vCPU / 8 GiB and exactly one instance; Lean toolchain
installations are deduplicated and worker package caches stay service-specific.

Select **`full-from-lite`** to expand an existing Lite deployment, retaining its
databases, secrets and public endpoint. Supply its deployed Lite image digest;
each separate service uses that exact bundle and matching migrations. Select
**`full`** for the independent original fleet described below. Locally:

```sh
lake exe typednotes-infra check                         # Lite, offline
lake exe typednotes-infra plan                          # Lite, live read
TYPEDNOTES_DEPLOYMENT=full lake exe typednotes-infra plan # existing full fleet
```

Lite needs no private network, compute database password or DB-inspector
credentials. **Built-in PostgreSQL notebook connectors / `db` sinks are disabled**:
Serverless SQL cannot create their per-user roles. Generation, stateless graph
execution and vault-backed storage remain available. Worker disks are ephemeral.

Lite owns `lite-typednotes-db` and `lite-typednotes-secrets-db` under marker
`typednotes-lite`; `full-from-lite` reuses those resources and updates the same
`typednotes-lite` public container in place. Neither touches the original full
fleet's data. **Existing one-database Lite deployments need the one-time vault
split before upgrading.** [Upgrade, deployment and recovery instructions](docs/lite.md).

## Local: everything in one image

[Typednotes Local](local/README.md) adds PostgreSQL to the same service image.
Launch it against a dedicated directory; internal credentials and data are
initialized and persisted automatically:

```sh
local/run.sh ./typednotes-data
```

The launcher prefers **Podman**, with Docker available through `--engine docker`,
and publishes only `http://localhost:8080`. Local supports built-in compute DB
sinks using a separate logical database on the same bundled PostgreSQL server.
Human sign-in still needs an OAuth client configured for localhost.

Both image variants are built and published by the
[typednotes-lite repository](https://github.com/typednotes/typednotes-lite);
this repository deploys them. [Schema-alignment details](images/README.md).

## What's declared

[`Fleet/Lite.lean`](Fleet/Lite.lean) selects Lite, and
[`Fleet/Promotion.lean`](Fleet/Promotion.lean) selects full-from-lite.
[`Fleet/Shared.lean`](Fleet/Shared.lean) constructs both from the same storage
specs, explicit name layout and typed URL recipes. The bundle snapshot and
migration handling are shared in [`Fleet/Bundle.lean`](Fleet/Bundle.lean).
[`Fleet.lean`](https://github.com/typednotes/typednotes-infra/blob/main/Fleet.lean) declares the full fleet: the `typednotes` system of
[`typednotes/typednotes`](https://github.com/typednotes/typednotes/tree/main)'s [`docs/architecture.md`](https://github.com/typednotes/typednotes/blob/main/docs/architecture.md),
as far as it is built — 55 Scaleway resources in one **full-mode** apply.

| Container | What | Database | Image |
|---|---|---|---|
| `typednotes-app` | the Dioxus fullstack app (`core`: sign-in, users, orgs, projects, connections, messaging webhooks) | `typednotes-db` | `ghcr.io/typednotes/typednotes:latest` |
| `ledger` | usage ledger — expired-hold sweeper, `/health` | `typednotes-db` | `ghcr.io/typednotes/ledger:latest` |
| `liaison` | the broker — the egress chokepoint | `typednotes-db` | `ghcr.io/typednotes/liaison:latest` |
| `secrets-server` | the vault | `secrets-db` | `ghcr.io/typednotes/secrets-server:latest` |
| `db-inspector` | [pgweb](https://github.com/sosedoff/pgweb): browse and query `typednotes-db`, read-only, password-gated | `typednotes-db` | `docker.io/sosedoff/pgweb:latest` |
| `lode` | bounded notebook code writer and Lean tooling | repository/workspace | `ghcr.io/typednotes/lode:latest` |
| `lun` | compiled functions and reactive graph runtime | actor-bound schemas on compute-db | `ghcr.io/typednotes/lun:latest` |

Around them: one container namespace, two Serverless SQL databases, a separate
classic PostgreSQL compute instance, three IAM identities (migrator / observer /
runtime) with one minted API key each, eight composed connection strings,
twenty-five operator-supplied secrets, and **four migration histories**.

**Network access:** only the app is generally public. Supporting containers
use a dedicated Private Network with public endpoints disabled. The DB inspector
is reachable through an IP-restricted `operator-gateway`, and the compute database
has only a private endpoint. The two IAM-protected Serverless SQL endpoints remain
public by explicit choice. See [service access](docs/service-access.md) for the
allowlist, private-network prerequisites and deployment checks.

The preceding **0.7.0** declaration adopted app schema **0.11.0** through `0015`
for direct project notes, stateless execution, durable schedules and delivery
outboxes, targeting **Lun 0.4.1**, **Lode 0.5.0** and **Linen 1.12.0**.
Full mode retains these schema histories; the **0.8.0** Lite bundle used
**Lun 0.4.2**. Since **0.9.0**, Lite and Local bundle the newest stable service
tags with their matching migrations; those combined images are built in the
typednotes-lite repository. Upgrading from the
older session-based runtime still requires draining old work and
pausing old dispatch before the coordinated migration/rollout.
See [the 0.7.0 rollout](docs/release-0.7.0.md).

The earlier local **0.6.3** declaration reads app schema **0.10.0** through `0013`,
and ledger schema **0.3.7** through `0003`, for organization/account deletion,
owner/default cleanup, atomic bootstrap and durable generation requests. Publish those new source
tags/images, Lode **0.4.3** and the cached Lun **0.3.2** before Plan/Apply; publish
Linen **1.11.0** first (Lun's dependency lock is prepared). See [the rollout notes](docs/release-0.6.3.md).
The prior [0.6.1 rollout](docs/release-0.6.1.md) introduced connection-provider
guards, default workspaces and public shares with Liaison v0.6.3 / Lun v0.3.1.
The fleet deploys `lode` and `lun`, wires their service URLs and bearer tokens,
and provisions the separate compute database and bounded graph/compute vault
policies. App, Lode and Lun stay warm with exactly one instance each; their
container disks remain ephemeral. See [notebook deployment](https://github.com/typednotes/typednotes-infra/blob/main/docs/notebooks.md)
for rollout, recovery and the five new required secrets. Microsoft Calendar and Outlook
need `MICROSOFT_CLIENT_ID`/`MICROSOFT_CLIENT_SECRET` on both the app and liaison,
which this fleet does not yet supply. These optional integrations stay disabled
until their configuration is supplied.

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
- **Application/vault serving identities cannot edit their table structure**:
  DDL is the migrator's, used only by `apply`. The app's separate compute-only
  administrator provisions actor roles/schemas on the dedicated compute instance.
- **An applied migration can't be changed underneath you**: infra compares the SQL at the URL with
  what the database recorded when it applied it, and refuses a mismatch (e.g. a moved tag).

In independent **full** mode, all seven service images use **`latest` selectors**, including Lode, Lun and
the DB inspector. The admin gateway uses the official `nginx:alpine` image.
Infra **0.23.0** resolves
each image selector to a verified registry manifest digest before a live diff and
applies that frozen `registry/repository@sha256:…` reference. The next run
resolves the tag again: new content updates in place, unchanged content
converges. The cloud's configured image records the digest, with no local state.
Registry failures stop the run, and offline `check` never contacts a registry.
An existing tag-only deployment gets one update to establish its digest;
Scaleway's update API automatically redeploys the changed container. A published
image becomes active on the next Apply; pushing a tag alone does not update a
running Scaleway container. An offline guard checks every service image ends
in `:latest` and the gateway uses its declared Alpine selector.

Lite and `full-from-lite` instead run one verified bundle and its matching SQL,
as described in [the combined image guide](images/README.md#schema-alignment-during-lite-deployment).

Each full-mode service's **schema release value** (`ledgerRelease := "0.3.6"`, …) still
names the git tag its SQL is read at. Image tags do not automatically adopt SQL:
after publishing a release with migrations, update that release value and add
the new migration files here before deploying code that needs them. This keeps
the schema change explicit in the plan while images track current content.

Because the SQL is fetched at `plan`, the offline `check` verifies the declaration's shape (ids,
`https://` URLs) but not the SQL's content or the order it implies — it says so when it runs.

### The DB inspector

Scaleway's console has no query editor for Serverless SQL (only connection strings for `psql`), so
the fleet runs pgweb through the IP-restricted admin gateway (see
[service access](docs/service-access.md)). Four independent protections:

1. **HTTP basic auth** with a username and password *you* choose: `DB_INSPECTOR_USERNAME` /
   `DB_INSPECTOR_PASSWORD`, stored in Scaleway Secret Manager, never in this repo.
2. **A read-only database identity** (`ServerlessSQLDatabaseReadOnly`): even past the password,
   nothing can be changed — an `INSERT` fails with `permission denied`.
3. **`PGWEB_LOCK_SESSION`**: pgweb's "connect to another server" form is disabled, so it cannot be
   used as a proxy to other hosts.
4. **Operator IP allowlist** at the gateway; the inspector's direct public
   container endpoint is disabled.

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

These commands select Lite unless `TYPEDNOTES_DEPLOYMENT=full` is set. The
remaining private-network and fleet details in this README describe full mode.

Access, endpoint visibility and admin ingress are resource properties managed
by Infra 0.23.0. `Main.lean` delegates directly to its CLI, with no networking
script or additional apply hooks. The existing private network is a prerequisite
described in [service access](docs/service-access.md).

`lake build` only compiles. `plan` and `apply` are `infra`'s, called from here and from CI.
`lean-toolchain` pins Lean **4.34.1**; CI uses `actions/checkout` **7.0.1** and
`leanprover/lean-action` **1.6.0**.

[`Main.lean`](https://github.com/typednotes/typednotes-infra/blob/main/Main.lean) hands [`Fleet.lean`](https://github.com/typednotes/typednotes-infra/blob/main/Fleet.lean)'s `typednotes` — the whole declaration, keys,
plan, `in paris` placement and releases in a single value — to `Infra.Cli.run`, together with
this repo's offline check and the accounts it is for. That shape needs **infra ≥ 0.9.0**; before
it the front end took the plan, the placement and the releases as three separate arguments, and
nothing stopped a call from handing over one and forgetting another.

[`lakefile.lean`](https://github.com/typednotes/typednotes-infra/blob/main/lakefile.lean) therefore requires `infra` at a tag rather than at `main` — currently
`v0.23.0`, with an explicit root dependency on linen `v1.12.0`, overriding Infra's
older `v1.9.2` transitive pin (0.19.0 lists managed Kubernetes clusters on every run, so
the Scaleway key needs Kapsule read access — `AllProductsFullAccess` covers it; 0.14.0 read migrations from URLs and ordered them by their
SQL, with container `migrations` lists and `namePrefixes`; 0.13.0 added the
`postgresMigrations` kind and made `libpq` a link-time dependency, so `libpq`/`pkg-config` must be
installed wherever this builds). Moving to a later release is a deliberate edit — bump the tag, run `lake update
infra`, read that release's entry in `infra`'s [`CHANGELOG.md`](https://github.com/typednotes/infra/blob/main/CHANGELOG.md) — rather than something that
happens to this repo the next time CI runs.

Credentials come from `infra`'s three-source chain — the Scaleway CLI's own config file, the OS
keychain, then environment variables (see `infra`'s [`docs/authentication.md`](https://github.com/typednotes/infra/blob/main/docs/authentication.md)). Scaleway also
needs `default_project_id`.

## Secrets to set

Everything this fleet needs from you, in one place. Set each as a **GitHub repository secret**
(Settings → Secrets and variables → Actions) for CI, or export it under the **environment name**
for a local `plan`/`apply`. `apply.yml` checks that the selected deployment's
required values are non-empty before building or touching cloud resources,
and names any that are missing. Lite requires twenty-six values; full mode
also requires the compute DB password and the two inspector credentials.

**Scaleway credentials** — read by every workflow (`plan.yml`, `apply.yml`, `destroy.yml`):

| Repo secret | What |
|---|---|
| `SCW_ACCESS_KEY` | API key access key. Needs read access to every Scaleway product (see "Removing a resource destroys it"), plus write on what the fleet manages |
| `SCW_SECRET_KEY` | that API key's secret key |
| `SCW_DEFAULT_PROJECT_ID` | the project the fleet lives in |
| `SCW_DEFAULT_ORGANIZATION_ID` | the organization, which the account guard checks (`accounts` in `Main.lean`) |

**Fleet values** — read by `apply.yml` only, behind `Fleet.lean`'s `fromEnv` secrets. Since
`apply.yml` passes `--refresh-secrets` (infra ≥ 0.18.0), each is **compared with its Scaleway
secret on every apply** and written there if it differs — and every container holding a copy is
updated. So these repo secrets are the source of truth: changing one here changes it in the cloud
on the next apply, and a value set by hand in Scaleway is overwritten. The plan lists every such
rewrite as a `refresh-secrets:` line (never the value); read them before approving, above all for
`SECRETS_MASTER_KEY`. Nothing here is committed.

| Repo secret | Environment name | What · how to make it |
|---|---|---|
| `SECRETS_MASTER_KEY` | same | the vault's master key: `openssl rand -hex 32`. **Keep a durable copy** — losing it loses everything the vault holds |
| `SECRETS_BOOTSTRAP_PASSWORD` | same | the vault's initial `admin` password, for operators (used only while that user is absent) |
| `LIAISON_ROOT_KEY` | same | the warrant root key, shared by the app (mints) and liaison (verifies): `openssl rand -hex 32` |
| `APP_SECRETS_PASSWORD` | same | the app's vault password, user `typednotes-app`, ≥ 12 characters: `openssl rand -base64 32`. The vault creates the user with it on start |
| `LIAISON_SECRETS_PASSWORD` | same | liaison's vault password, user `liaison`, ≥ 12 characters: `openssl rand -base64 32` |
| `LUN_SECRETS_PASSWORD` | same | Lun's separate vault identity password, ≥ 32 random characters |
| `LODE_TOKEN` | same | writer API bearer token shared with the app: `openssl rand -hex 32` |
| `LUN_TOKEN` | same | runner API bearer token shared with the app and writer: `openssl rand -hex 32` |
| `LUN_ID_SALT` | same | stable build-ID salt: `openssl rand -hex 32` |
| `COMPUTE_DB_PASSWORD` | same | dedicated compute administrator password; 8–128 characters with upper/lowercase, a digit and a special character |
| `OAUTH_GITHUB_CLIENT_ID` | `GITHUB_CLIENT_ID` | a [GitHub OAuth App](https://github.com/settings/developers)'s client id: sign-in and the `github` connection. Callback URL `https://app.typednotes.com/auth/github/callback` |
| `OAUTH_GITHUB_CLIENT_SECRET` | `GITHUB_CLIENT_SECRET` | that OAuth App's client secret |
| `GOOGLE_CLIENT_ID` | same | a Google Cloud OAuth client (type *Web application*, Google Drive API enabled): sign-in and the `gdrive` connection. Authorized redirect URI `https://app.typednotes.com/auth/google/callback`. On the consent screen, declare the scopes `openid`, `email`, `profile` and `…/auth/drive.file` (not the restricted `…/auth/drive`, which Google refuses to unverified apps with `403 access_denied`) and publish it: in *Testing* only listed test users get in, and their refresh tokens expire after 7 days. liaison uses it to refresh Drive tokens |
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
by the apply itself, and the vault creates its service users itself from the values above (see
"Vault service identities").

**Safe to delete** if still set: `LIAISON_SECRETS_TOKEN` (replaced by
`LIAISON_SECRETS_PASSWORD`) and `SCW_DEFAULT_REGION` (the region comes from `in paris`).

## Deploying

**Before the first apply**, three things exist outside this repo:

1. **The release tags, pushed** — `infra` `v0.23.0` and linen `v1.12.0` (then
   `lake update infra linen` here and commit `lake-manifest.json`), and the services' tags
   `typednotes` `v0.7.1`, `ledger` `v0.3.6`, `liaison` `v0.6.0`, `secrets` `v1.3.0`,
   whose `.sql` files `plan` reads and whose `docker-publish.yml` workflows build
   **the images** and move their `latest` selectors. Until a schema release's tag is pushed, `plan`
   stops with `HTTP 404 — is the tag or commit pushed, and the path right?`.
2. **The twenty-nine secrets** of "Secrets to set" above — the four Scaleway credentials and the
   twenty-five values behind `Fleet.lean`'s `fromEnv` secrets, including the notebook
   service tokens, Lun identity password, stable ID salt and compute DB password.

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
```

Then attach the custom domain (next section) and register the callback URLs with GitHub,
Google, GitLab, Dropbox and Slack, and the webhook URLs with Slack and Meta. Until both are
done, everything works except sign-in, those connections and inbound messages.

### Custom domain

The app is served at **`https://app.typednotes.com`**. DNS and container-domain
bindings remain outside Infra's resource surface, so those are set with the
[`scw` CLI](https://www.scaleway.com/en/cli/) (checked with 2.62). HTTPS-only is
declared on the app resource as `httpsOnly := some true`. The
`typednotes.com` zone is in Scaleway Domains & DNS.

**[`scripts/check-domain.sh`](https://github.com/typednotes/typednotes-infra/blob/main/scripts/check-domain.sh)** checks the whole path — the container and its `PUBLIC_URL`, the
CNAME (asked of the zone's own name servers), the domain binding, the TLS certificate (verifies,
names the host, more than 14 days left), that plain HTTP is redirected, and that
`/api/health` answers through all of it — and exits non-zero on any problem. With **`--fix`** it
also repairs what can be repaired from here, in the order below, changing nothing that already
checks out:

```sh
scripts/check-domain.sh          # read-only
scripts/check-domain.sh --fix    # repoint the CNAME, recreate a stale or failed binding, HTTPS-only
```

Run it after the first apply, after any apply that may have recreated `typednotes-app`, and
whenever the browser says the site is not secure. It needs `scw`, `jq`, `dig`, `curl` and
`openssl`.

What it does, step by step, if you would rather do it by hand — the same commands serve for the
first attach and for **re-attaching** (after the container was recreated, or when the binding
shows `error`), and they are safe to re-run:

```sh
# 1. the app container's id and its Scaleway host (public_endpoint minus https://)
ID=$(scw container container list name=typednotes-app -o json \
       | jq -r '.[] | select(.name=="typednotes-app") | .id')
HOST=$(scw container container get "$ID" -o json | jq -r '.public_endpoint | sub("^https://"; "")')
echo "$ID $HOST"

# 2. point app.typednotes.com at it — a CNAME, hence a subdomain, not the bare typednotes.com.
#    `set` creates the record or replaces what it held (e.g. a previous container's host).
scw dns record set typednotes.com name=app type=CNAME values.0="$HOST." ttl=300

# 3. wait until DNS answers with that host. Do not skip: binding the domain before the CNAME
#    resolves makes certificate issuance fail, and the binding stays in "error".
dig +short app.typednotes.com CNAME      # must print "$HOST."

# 4. remove any existing binding for the hostname — a stale one from a previous container, or
#    one in "error". A failed binding is not retried: it has to be deleted and created again.
scw container domain list -o json \
  | jq -r '.[] | select(.hostname=="app.typednotes.com") | .id' \
  | xargs -r -n1 scw container domain delete
#    deletion is asynchronous ("deleting"); creating before it is gone fails with "already exists"
until [ -z "$(scw container domain list -o json | jq -r '.[] | select(.hostname=="app.typednotes.com") | .id')" ]; do sleep 5; done

# 5. tell Serverless Containers to answer for it; Scaleway issues the TLS certificate
scw container domain create container-id="$ID" hostname=app.typednotes.com
scw container domain list container-id="$ID"     # "creating" for a few minutes, then "ready"; on "error", redo 3–5
curl -sI https://app.typednotes.com | head -1

# 6. HTTPS only: redirect plain HTTP instead of serving the app over it
scw container container update "$ID" https-connection-only=true
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://app.typednotes.com/   # "301 https://app.typednotes.com/"
```

`scw container domain get <domain-id>` shows the `error_message` of a failed binding.

**Why step 6 matters.** Without it the container answers `http://app.typednotes.com` with the
app itself (`200`), unencrypted, and the browser marks the site "Not secure" — for anyone who
typed the address, followed an old link or a bookmark — even though the certificate is fine.
With it, Serverless Containers answers plain HTTP with `301` to the `https://` URL. The API
reads the setting back as `null` even when it is on, so check the behaviour (the `curl` above,
or the script), not the field.

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
- **Bindings stay external.** Infra does not manage DNS records or container
  domain bindings. HTTPS-only is now compared and reconciled as a resource
  property. `scripts/check-domain.sh` verifies the full DNS/certificate/app path.
- **Updates keep it.** Releases update the container in place and keep its id, so the binding
  survives image bumps.
- **A recreated container loses it.** If `typednotes-app` is ever destroyed and created again (a
  `destroy`, or a change `infra` can only apply by replacement), its id and Scaleway domain
  change. Run `scripts/check-domain.sh --fix` (or the commands above: step 2 repoints the record,
  step 4 drops the stale binding, step 6 turns HTTPS-only back on).

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

The app, liaison and Lun each log in to the vault as their own `userpass` user and log in again before
the hour-long token expires (`typednotes/typednotes` [`docs/connections.md`](https://github.com/typednotes/typednotes/blob/main/docs/connections.md) §4). That replaces the
static `liaison-secrets-token`, which expired an hour after it was minted; the next apply deletes
that secret.

The users live in the vault, and the vault creates them itself: `secrets-server` ≥ 1.3.0 reads
`SECRETS_SERVER_SERVICE_IDENTITIES` (`vaultServiceIdentities` in `Fleet.lean`) and, on **every**
start, writes a policy named after each user and the user holding only it, with the password from
the same `app-secrets-password`, `liaison-secrets-password` and `lun-secrets-password` secrets their callers use:

| user | policy on `secret/data/thirdparty/` |
|---|---|
| `typednotes-app` | `create`, `delete` — it stores credentials but can never read them back |
| `liaison` | `read`, plus `create` to write back a refreshed OAuth token |

Lun has no general third-party credential read. Its rules are limited to actor
compute credentials, graph data/metadata, connector policy/authority and the
reserved PostgreSQL/vault permission-document namespaces. The app also gets
create/delete on graph and compute data while retaining no read/list rights.
The proof-carrying declaration and real vault checks are described in
[notebook deployment](https://github.com/typednotes/typednotes-infra/blob/main/docs/notebooks.md).

App and liaison ≥ 0.6.0 also require trusted connector policy documents. Under
`secret/data/connector-policy/` and `secret/data/connector-authority/`, the app gets
`create`, `update`, `delete`, and liaison gets only `read`. These rules are declared
alongside the credential rules in `vaultServiceIdentities`, so the vault's next
rollout installs them before either caller updates. Liaison also waits for the
core migration history, including `0008_connector_authority.sql`.

So there is no step after `apply`, and a recreated vault (a new namespace, `destroy --keep-data`)
comes back with its users. **Rotating** a password is changing the repo secret and applying:
`--refresh-secrets` rewrites the Scaleway secret and redeploys the vault and affected callers with
it. Tokens issued before keep working until they expire (an hour). The vault refuses to start if
any identity password is missing or shorter than 12 characters, which shows as the container failing
rather than as connections failing to store.

`admin` is not managed this way: its password is read only while the user is absent, so changing
`SECRETS_BOOTSTRAP_PASSWORD` does not rotate it — change it in the vault
(`POST /v1/auth/userpass/users/admin`, logged in as `admin`) and then in the repo secret.

## CI

Apply, Plan and Destroy expose `current`, `lite`, `full-from-lite` and `full`,
defaulting to the persisted `current` configuration. Before promotion set
repository variables `TYPEDNOTES_DEPLOYMENT=full-from-lite` and
`TYPEDNOTES_LITE_IMAGE` to the deployed fixed bundle digest. Subsequent updates
replace that image pin with a newly tested bundle. The CLI independently refuses
unsupported Lite downgrades/teardown when cloud resources show a full topology,
including partial promotion and retained compute storage.
Lite Apply deploys the published combined image's immutable digest
with matching SQL. Full Apply uses the existing service images.
See [the Lite CI sequence](docs/lite.md#ci-deployment).

Cloud reconciliation/teardown stay manual. The combined Lite/Local images are
built and published by the
[typednotes-lite repository](https://github.com/typednotes/typednotes-lite);
this repository no longer builds them.

**`plan.yml`** runs `check` on pushes to `main` and pull requests targeting `main`, and additionally posts a live `plan`
to the run summary on pushes to `main` and manual dispatches on `main`. It never applies.

**`apply.yml`** is the manual apply. Its only trigger is `workflow_dispatch` — there is no push
trigger to mis-condition — and it asks you to type `typednotes` to confirm. It runs the offline
checks, prints the plan it is about to apply, applies via `lake script run apply --yes
--refresh-secrets`, then prints the state afterwards (a clean apply leaves `nothing to do`). All
three use `--refresh-secrets`, so a stale secret shows in the plan, is rewritten by the apply, and
is checked by the last step. The three minted database keys are not rotated by it: delete a key's
secret and apply to rotate one. Concurrent runs queue rather than race.

**`destroy.yml`** is the manual teardown — `apply` against an empty declaration, in `infra`'s own
terms. Also `workflow_dispatch`-only, and its confirmation phrase is `destroy typednotes` rather
than `typednotes`, so it cannot be triggered by muscle memory from running `apply`. **By default it
keeps the data** (`destroy --keep-data`): both databases, their migration histories and the buckets
stay, still marked as this fleet's, and the next `apply.yml` rebuilds everything else around them.
Deleting them too takes the `destroy_databases` box *and* the phrase `destroy typednotes and its
data`. It prints what is about to be deleted (`plan --destroy`, with a `KEEP` line for each kept
resource), destroys, then prints the teardown plan again (a clean teardown leaves `nothing to
do`). It shares `apply.yml`'s concurrency group, so the two can never
race the same resources, and does not need `SECRETS_MASTER_KEY` since destroying never creates
a secret. Deleting the minted API key needs no credential of its own: deleting the secret deletes
the key.

All three declare an `environment: production`; **add required reviewers to that environment in
Settings → Environments** if you want every apply or destroy to need a second pair of eyes. That
is the one gate the workflow files cannot enforce for themselves.

Repo secrets needed: the full list, with what each is and how to make it, is
["Secrets to set"](#secrets-to-set) — the four `SCW_*` credentials for all three workflows, and
the twenty-five fleet values for `apply.yml` only. The composed database URLs are never supplied
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

`apply.yml` checks the selected mode's required secrets **before** it builds or touches cloud resources,
and names the missing ones. That matters for `fromEnv` values in particular: they are not credentials, so
nothing else would notice they were absent until the backend tried to create that secret —
which is after the database already exists, leaving a half-applied fleet.

Both workflows also point OpenSSL at the runner's CA bundle (`SSL_CERT_FILE`/`SSL_CERT_DIR`).
Without it, any live call fails with `certificate verify failed`: Lean's toolchain bundles a
static OpenSSL whose compile-time trust-store path does not exist on a runner. See `infra`'s
[`docs/authentication.md`](https://github.com/typednotes/infra/blob/main/docs/authentication.md).

## Notes

[`lakefile.lean`](https://github.com/typednotes/typednotes-infra/blob/main/lakefile.lean) duplicates ~80 lines of platform-conditional link flags from `infra`'s own
[lakefile](https://github.com/typednotes/infra/blob/v0.23.0/lakefile.lean). That is not an oversight: Lake does not propagate a dependency's `moreLinkArgs` to a
dependent's executable, and a lakefile cannot import a dependency's modules, so the computation
has to be repeated. Keep the two copies in step.
