import Infra
import Fleet.Notebook

/-
  The declared fleet: everything this project manages.

  Declared with `infra`'s `fleet` command (see its `docs/architecture.md`,
  "Declaring a fleet"). Everything below is a resource. To manage something
  new, add a `resource` line.

  **Scoping.** A `(provider, kind)` pair not named below, or a name not listed
  under a pair that is, has no key for the plan to mention — so whatever
  exists there in the account is left alone, unconditionally. This fleet is
  Scaleway-only, so AWS is never authenticated and never called.

  ## What runs

  Seven Serverless Containers in one namespace, over two Serverless SQL
  databases — `docs/architecture.md` §2 of `typednotes/typednotes`, as far as
  it is built:

  | container        | image                              | database        |
  |------------------|------------------------------------|-----------------|
  | `typednotes-app` | the Dioxus fullstack app (`core`)  | `typednotes-db` |
  | `ledger`         | usage ledger: hold sweeper         | `typednotes-db` |
  | `liaison`        | the broker (egress chokepoint)     | `typednotes-db` |
  | `secrets-server` | the vault                          | `secrets-db`    |
  | `db-inspector`   | pgweb, read-only, password-gated   | `typednotes-db` |
  | `lode`           | bounded writer and Lean tooling    | repository/workspace |
  | `lun`            | compiled function/graph runner     | actor schemas in compute-db |

  `ledger` and `liaison` share the app's database by design (`ledger.md`:
  "deployed inside core"; `broker.md`: "shares a database with core") — their
  schemas reference `orgs`/`users` and each other's tables. The vault has a
  database of its own.

  ## Schemas are declared, not migrated at startup

  Four `postgresMigrations` histories, one per service. Each lists its
  migration *files*, read by `infra` from the service's own GitHub
  repository at the service's release tag when it plans (`github …`) — so
  the SQL under review is the service's own `.sql`, never a copy, and
  adopting a new migration is a one-line diff here:

      typednotes-core-history ◀── typednotes-ledger-history   (references orgs, users)
      typednotes-liaison-history
      secrets-history

  The order between the histories on `typednotes-db` is read from their SQL
  (infra ≥ 0.14.0): ledger's tables `references orgs(id)`, so ledger's
  history applies after the app's. Nothing is declared twice; a reference
  to a table no history creates is refused at plan time. Each container's
  `migrations` lists every history its rollout waits for — liaison's code
  writes ledger's tables, a dependency no SQL states, so its container
  waits for ledger's history as well as its own. New code never meets an
  old schema, and a failed migration stops the rollout. No service migrates
  itself: `secrets-server` runs with `SECRETS_SERVER_STORAGE_MIGRATE=false`,
  the others have no migrator in their serving path at all.

  Because the SQL is fetched at `plan`, the offline `check` cannot verify
  its content or the order it implies; `plan` does, before anything else.

  Each history's `schema` is only where `infra` keeps its bookkeeping table
  (`<schema>.infra_migrations`); the services' tables live in `public`, as
  their SQL says. Distinct schemas are what keep the three histories on one
  database from reading each other's rows.

  ## Three database identities, not one per service

  Serverless SQL Database has no master user: authentication is IAM, the
  PostgreSQL user name is an IAM application's *id*, and the password is that
  application's API secret key, minted at apply by `apiKeyFor` and never
  readable again. Permission sets scope to a **Project**, not to a database
  (Scaleway: "access management at resource level is not yet available"), so
  an identity per service would be ceremony — each would reach every
  database in the project anyway. What *does* separate is the permission set:

  | identity                  | permission set                       | used by                        |
  |---------------------------|--------------------------------------|--------------------------------|
  | `typednotes-db-migrator`  | `ServerlessSQLDatabaseReadWrite`     | `infra` apply (DDL)            |
  | `typednotes-db-observer`  | `ServerlessSQLDatabaseReadOnly`      | `infra` plan/refresh, pgweb    |
  | `typednotes-db-runtime`   | `ServerlessSQLDatabaseDataReadWrite` | every serving container        |

  So no serving container can change the app/vault table structure, and the DB
  inspector cannot change anything. Scaleway's "Known differences" page says
  `GRANT` cannot be performed — access is IAM's, per permission set — which
  is what lets the runtime and observer identities use tables the migrator
  created. **Verify on the first apply** (see the README): that is a provider
  fact no live run has exercised yet.

  Notebook compute uses a separate classic PostgreSQL instance: only the app
  receives its administrator URL for provisioning actor roles/schemas. Lun
  receives actor-bound credentials through its scoped vault identity.

  **Composed URLs are create-only — except under `--refresh-secrets`.** No
  cloud reports a secret's value, so a composed URL is built once, at
  creation, and a plain `plan` never diffs it. That is why the runtime URL for
  the vault is `secrets-db-runtime-url` and not the old `secrets-db-url`:
  before infra 0.18.0, reusing the name would have kept the old value,
  pointing at the retired `secrets-db-app` identity. `apply.yml` now passes
  `--refresh-secrets`, which compares each URL with its recipe settled now and
  rewrites it — and the containers holding it — if they differ; the same goes
  for every `fromEnv` secret against its repo secret. The three minted keys
  are not rotated by it (infra's `docs/coverage.md`).

  **Removing a line destroys the resource, from any machine** (infra ≥
  0.15.0): what this fleet manages is whatever carries its marker
  (`managed-by-infra=typednotes`, or the `secrets-`/`typednotes-` name prefix
  for databases), found by asking Scaleway on every run — the `.infra/`
  ledger is only a cache, and a CI runner has none. Before 0.15.0 it was the
  other way round, which is how the retired `secrets-db-app`,
  `secrets-db-key`, `secrets-db-url` and the empty-principal
  `typednotes-db-inspector-url` survived the first applies; the next apply
  deletes them.

  ## Where it is, and the images

  `in paris` places the fleet at `fr-par`. Images are pulled straight
  from public registries; all seven containers track **`latest` selectors**.
  Infra ≥ 0.22.0 resolves
  each selector to a manifest digest before the live diff and deploys that
  frozen content. A moved tag with new content updates; the same digest
  converges. Migration histories independently retain explicit release tags:
  adopting new SQL still requires updating its release and file list below.
-/

open Infra.Core
open Infra.Specs

/-- DDL rights, for applying migrations and nothing else. The set Scaleway
    describes as "read, write access *and edit table structure*"
    (SELECT/UPDATE/INSERT/DELETE, CREATE/ALTER/DROP TABLE and INDEX). Not
    `ServerlessSQLDatabaseDataReadWrite`, whose name suggests it and which
    cannot `CREATE`. -/
def ddlAccess : String := "ServerlessSQLDatabaseReadWrite"

/-- `SELECT` and nothing else: the observation path of `infra`'s migrations
    kind, and the DB inspector. -/
def readAccess : String := "ServerlessSQLDatabaseReadOnly"

/-- SELECT/UPDATE/INSERT/DELETE — what a serving container needs, and no
    structure-editing rights, because no service migrates itself. -/
def dataAccess : String := "ServerlessSQLDatabaseDataReadWrite"

/-- A Serverless SQL connection string for `key`'s identity on database
    `db` (whose name is `dbName`).

    Three traps, each of which cost this fleet a debugging session once:
    **the user name is the application id** (`principalOf`), not the access
    key, which fails as `password authentication failed for user "SCW…"`;
    **the path is the database's own name**, else `database "…" does not
    exist` after apply reports success; and **`?sslmode=require` is
    mandatory**, and `endpointOf` does not supply it. Both credential halves
    go through `urlEncode`: a single `/` in one would end the URL's authority
    early and surface as `invalid port number`. -/
def pgUrl {K : ProviderId → Kind → Type} (key : K .scaleway .secrets)
    (db : K .scaleway .postgres) (dbName : String) : Expr K String :=
  expr!"postgres://\
{(principalOf key).map Network.HTTP.Types.urlEncode}:\
{(secretValueOf key).map Network.HTTP.Types.urlEncode}\
@{endpointOf db}/{Expr.lit (K := K) dbName}?sslmode=require"

/-- A Serverless SQL database's id, from its endpoint: the first label of the
    host (`8766c6e0-….pg.sdb.fr-par.scw.cloud:5432` → `8766c6e0-…`) —
    checked against `scw sdb-sql database list` on 2026-09-23. -/
def databaseIdOf (endpoint : String) : String :=
  let host := (endpoint.splitOn ":").headD endpoint
  (host.splitOn ".").headD host

#guard databaseIdOf "8766c6e0-fc9d-4a6b-901b-b7cc6e3403d8.pg.sdb.fr-par.scw.cloud:5432"
  = "8766c6e0-fc9d-4a6b-901b-b7cc6e3403d8"

/-- `pgUrl`, for a client that does not send the host name during the TLS
    handshake (SNI). Serverless SQL routes each connection to its database
    by that name, and refuses one without it:

        pq: Database hostname wasn't sent to server. Either add
        "?options=databaseid%3D{databaseid}" at the end of your connection
        string, or use another client supporting TLS ServerNameIndication.

    That is what pgweb's Go driver (`lib/pq`) does, and it is how the first
    deploy of `db-inspector` failed to start — while libpq (infra, ledger,
    liaison) and sqlx (the app, the vault) send SNI and need none of this.
    So this appends the option Scaleway asks for, with the id taken from the
    endpoint. Verified against the live `typednotes-db` with pgweb 0.17.0
    before being declared here. -/
def pgUrlWithoutSni {K : ProviderId → Kind → Type} (key : K .scaleway .secrets)
    (db : K .scaleway .postgres) (dbName : String) : Expr K String :=
  expr!"{pgUrl key db dbName}&options=databaseid%3D{(endpointOf db).map databaseIdOf}"

/-- The reviewed schema release per service: prefixed with `v`, this names
    the git tag its migrations are read at. Images track `latest` separately;
    new migration files are adopted explicitly, never inferred from a tag. -/
def appRelease : String := "0.9.0"
def ledgerRelease : String := "0.3.6"
def liaisonRelease : String := "0.6.0"
def secretsRelease : String := "1.3.0"

/-- The app's public origin: `app.typednotes.com`, a custom domain attached
    to the `typednotes-app` container by hand (README, "Custom domain") —
    `infra` has no DNS or container-domain kind yet. The app puts it in every
    OAuth redirect URI (`PUBLIC_URL`), so sign-in only works once the domain
    is attached and these callbacks are registered with each OAuth provider. -/
def appPublicUrl : String := "https://app.typednotes.com"

/-- Live plan/apply resolves these selectors to verified manifest digests,
    compares content and writes immutable references (infra ≥ 0.22.0). -/
def appImage : String := "ghcr.io/typednotes/typednotes:latest"
def ledgerImage : String := "ghcr.io/typednotes/ledger:latest"
def liaisonImage : String := "ghcr.io/typednotes/liaison:latest"
def secretsImage : String := "ghcr.io/typednotes/secrets-server:latest"
def lodeImage : String := "ghcr.io/typednotes/lode:latest"
def lunImage : String := "ghcr.io/typednotes/lun:latest"

/-- The vault's service identities (`typednotes/typednotes`
    docs/connections.md §4), in the syntax `secrets-server` ≥ 1.3.0 reads
    from `SECRETS_SERVER_SERVICE_IDENTITIES`. The vault applies them on every
    start: each gets a policy named after it with exactly these rules, and a
    user holding only it, whose password is read from `password_env` — the
    service-password secrets, which the app, liaison and Lun log in with.
    So nothing has to be created by hand, and rotating a password is an
    apply: `--refresh-secrets` redeploys the vault and both services with it.

    | user | on `secret/data/thirdparty/` |
    |---|---|
    | `typednotes-app` | `create`, `delete` — stores credentials, never reads them back |
    | `liaison` | `read`, plus `create` to write back a refreshed OAuth token |

    App and liaison ≥ 0.6.0 also exchange trusted policy documents under
    `secret/data/connector-policy/` and `secret/data/connector-authority/`:
    the app creates, updates and deletes them; liaison can only read them. -/
def vaultServiceIdentities : String :=
  let identity (user passwordEnv rules : String) :=
    s!"\{username=\"{user}\", password_env=\"{passwordEnv}\", " ++
    s!"rules=[{rules}]}"
  let appRules := Typednotes.Notebook.rules Typednotes.Notebook.appOperations
  let liaisonRules := "{prefix=\"secret/data/thirdparty/\", capabilities=[\"read\",\"create\"]}," ++
    "{prefix=\"secret/data/connector-policy/\", capabilities=[\"read\"]}," ++
    "{prefix=\"secret/data/connector-authority/\", capabilities=[\"read\"]}"
  "[" ++ identity "typednotes-app" "APP_SECRETS_PASSWORD" appRules ++ ", " ++
    identity "liaison" "LIAISON_SECRETS_PASSWORD" liaisonRules ++ ", " ++
    identity "lun" "LUN_SECRETS_PASSWORD" (Typednotes.Notebook.rules Typednotes.Notebook.lunOperations) ++ "]"

/-- The administrator is confined to the dedicated compute instance; Lun gets
    only actor-bound credentials from the vault, never this URL. -/
def computeUrl {K : ProviderId → Kind → Type} (db : K .scaleway .postgres)
    (password : K .scaleway .secrets) : Expr K String :=
  expr!"postgres://typednotes_compute:{(secretValueOf password).map Network.HTTP.Types.urlEncode}@{endpointOf db}/rdb?sslmode=require"

/-- Each service's migration files, in its repository, at its release tag.
    A new migration is a new line here. -/
def appMigrations : List MigrationDecl :=
  github "typednotes/typednotes" s!"v{appRelease}"
    [ "migrations/0001_core.sql", "migrations/0002_sessions_connections.sql"
    , "migrations/0003_projects_channels.sql", "migrations/0004_computations.sql"
    , "migrations/0005_productivity_connections.sql", "migrations/0006_ai_providers.sql"
    , "migrations/0007_notebook_contracts.sql", "migrations/0008_connector_authority.sql"
    , "migrations/0009_connection_provider_guard.sql", "migrations/0010_user_workspaces.sql"
    , "migrations/0011_notebook_shares.sql" ]
def ledgerMigrations : List MigrationDecl :=
  github "typednotes/ledger" s!"v{ledgerRelease}"
    ["sql/0001_init.sql", "sql/0002_credit_ledger_idempotency.sql"]
def liaisonMigrations : List MigrationDecl :=
  github "typednotes/liaison" s!"v{liaisonRelease}" ["sql/0001_audit_log.sql"]
def secretsMigrations : List MigrationDecl :=
  github "typednotes/secrets" s!"v{secretsRelease}"
    ["crates/secrets-storage-postgres/src/migrations/0001_init.sql"]

/-- pgweb, tracking `latest` by digest. Configured entirely through environment
    variables, which is what a Serverless Container can set (there is no command/args field):
    `PGWEB_DATABASE_URL`, `PGWEB_AUTH_USER`/`PGWEB_AUTH_PASS` for HTTP basic
    auth, and `PGWEB_LOCK_SESSION` — all read by pgweb 0.17's
    `pkg/command/options.go` (checked 2026-09-23). Its image listens on 8081. -/
def inspectorImage : String := "docker.io/sosedoff/pgweb:latest"

fleet typednotes in paris where
  provider scaleway where
    -- ── Operator-supplied secrets ───────────────────────────────────────
    -- `fromEnv` names a variable, never a value: each is read once, when the
    -- secret is first created, and nothing secret is committed here.

    -- The vault's master key. Losing it loses what the vault encrypted.
    resource secrets "secrets-master-key" as masterKey
      { valueFrom := fromEnv "SECRETS_MASTER_KEY" }

    -- The password for the vault's initial `admin` user, for operators, read
    -- by `secrets-server` only when that user is absent (so changing it here
    -- does not rotate it). No service logs in as `admin`.
    resource secrets "secrets-bootstrap-password" as bootstrapPassword
      { valueFrom := fromEnv "SECRETS_BOOTSTRAP_PASSWORD" }

    -- The warrant root key `liaison` verifies HMAC tag chains against
    -- (`broker.md` §3). `core` will mint with the same key.
    resource secrets "liaison-root-key" as liaisonRootKey
      { valueFrom := fromEnv "LIAISON_ROOT_KEY" }

    -- The vault passwords of the two service identities
    -- (`vaultServiceIdentities`): each container logs in as its own userpass
    -- user and logs in again before the hour-long token expires. The vault
    -- gets the same values and creates or updates both users on every start.
    resource secrets "app-secrets-password" as appSecretsPassword
      { valueFrom := fromEnv "APP_SECRETS_PASSWORD" }
    resource secrets "liaison-secrets-password" as liaisonSecretsPassword
      { valueFrom := fromEnv "LIAISON_SECRETS_PASSWORD" }
    resource secrets "lun-secrets-password" as lunSecretsPassword
      { valueFrom := fromEnv "LUN_SECRETS_PASSWORD" }
    resource secrets "lode-token" as lodeToken
      { valueFrom := fromEnv "LODE_TOKEN" }
    resource secrets "lun-token" as lunToken
      { valueFrom := fromEnv "LUN_TOKEN" }
    resource secrets "lun-id-salt" as lunIdSalt
      { valueFrom := fromEnv "LUN_ID_SALT" }
    resource secrets "typednotes-compute-password" as computePassword
      { valueFrom := fromEnv "COMPUTE_DB_PASSWORD" }

    -- The OAuth clients behind sign-in and the `github` / `gdrive`
    -- connections. Callback URLs to register with each provider:
    -- `https://app.typednotes.com/auth/{github,google}/callback` (`appPublicUrl`).
    -- The client ids are not secret, but they are yours to supply and this
    -- keeps them out of the repo. The Google client is also liaison's, which
    -- refreshes Drive access tokens with it.
    resource secrets "github-client-id" as githubClientId
      { valueFrom := fromEnv "GITHUB_CLIENT_ID" }
    resource secrets "github-client-secret" as githubClientSecret
      { valueFrom := fromEnv "GITHUB_CLIENT_SECRET" }
    resource secrets "google-client-id" as googleClientId
      { valueFrom := fromEnv "GOOGLE_CLIENT_ID" }
    resource secrets "google-client-secret" as googleClientSecret
      { valueFrom := fromEnv "GOOGLE_CLIENT_SECRET" }

    -- The OAuth clients behind the `gitlab` and `dropbox` connections
    -- (callbacks `https://app.typednotes.com/auth/{gitlab,dropbox}/callback`).
    -- liaison refreshes both kinds of token with the same clients.
    resource secrets "gitlab-client-id" as gitlabClientId
      { valueFrom := fromEnv "GITLAB_CLIENT_ID" }
    resource secrets "gitlab-client-secret" as gitlabClientSecret
      { valueFrom := fromEnv "GITLAB_CLIENT_SECRET" }
    resource secrets "dropbox-client-id" as dropboxClientId
      { valueFrom := fromEnv "DROPBOX_CLIENT_ID" }
    resource secrets "dropbox-client-secret" as dropboxClientSecret
      { valueFrom := fromEnv "DROPBOX_CLIENT_SECRET" }

    -- The Slack app: its OAuth client installs it in a workspace (the
    -- `slack` connection, callback `…/auth/slack/callback`), and its signing
    -- secret authenticates the Events API deliveries to `…/hooks/slack`.
    resource secrets "slack-client-id" as slackClientId
      { valueFrom := fromEnv "SLACK_CLIENT_ID" }
    resource secrets "slack-client-secret" as slackClientSecret
      { valueFrom := fromEnv "SLACK_CLIENT_SECRET" }
    resource secrets "slack-signing-secret" as slackSigningSecret
      { valueFrom := fromEnv "SLACK_SIGNING_SECRET" }

    -- The Meta app behind WhatsApp interfaces: its app secret signs the
    -- webhook deliveries to `…/hooks/whatsapp`, and the verify token is what
    -- Meta echoes when that webhook is registered (operator-chosen).
    resource secrets "whatsapp-app-secret" as whatsappAppSecret
      { valueFrom := fromEnv "WHATSAPP_APP_SECRET" }
    resource secrets "whatsapp-verify-token" as whatsappVerifyToken
      { valueFrom := fromEnv "WHATSAPP_VERIFY_TOKEN" }

    -- HTTP basic auth for the DB inspector. Both halves are operator-chosen
    -- and kept in Secret Manager; the username is not sensitive, but it is
    -- yours to pick and this keeps it out of the repo.
    resource secrets "db-inspector-username" as inspectorUser
      { valueFrom := fromEnv "DB_INSPECTOR_USERNAME" }
    resource secrets "db-inspector-password" as inspectorPassword
      { valueFrom := fromEnv "DB_INSPECTOR_PASSWORD" }

    -- ── Database identities (see the header) ────────────────────────────
    resource iam "typednotes-db-migrator" { policies := [ddlAccess] }
    resource iam "typednotes-db-observer" { policies := [readAccess] }
    resource iam "typednotes-db-runtime"  { policies := [dataAccess] }

    resource secrets "typednotes-db-migrator-key" as migratorKey
      { valueFrom := apiKeyFor "typednotes-db-migrator" }
    resource secrets "typednotes-db-observer-key" as observerKey
      { valueFrom := apiKeyFor "typednotes-db-observer" }
    resource secrets "typednotes-db-runtime-key" as runtimeKey
      { valueFrom := apiKeyFor "typednotes-db-runtime" }

    -- ── Databases ───────────────────────────────────────────────────────
    -- Serverless, not classic: capacity bounds and no `instanceClass`. No
    -- master user exists, so `masterPasswordSecret` is `""` (infra ≥ 0.12.1).
    resource postgres "secrets-db" as secretsDb
      { masterUsername       := "unused-serverless-sql-is-iam-only"
      , masterPasswordSecret := ""
      , minCapacity          := 0
      , maxCapacity          := 4 }

    resource postgres "typednotes-db" as appDb
      { masterUsername       := "unused-serverless-sql-is-iam-only"
      , masterPasswordSecret := ""
      , minCapacity          := 0
       , maxCapacity          := 4 }

    -- Serverless SQL authenticates via IAM and cannot create actor roles.
    -- A separate classic instance supplies PostgreSQL CREATE ROLE/SCHEMA.
    -- Infra ≥ 0.22.2 creates SBS 5K storage; Scaleway rejects the old BSSD type.
    resource postgres "typednotes-compute-db" as computeDb
      { instanceClass        := "db-dev-s"
      , masterUsername       := "typednotes_compute"
      , masterPasswordSecret := "typednotes-compute-password"
      , version              := "16"
      , storageGb            := 10 }

    -- ── Connection strings, composed at apply ───────────────────────────
    resource secrets "secrets-db-migrator-url" { valueFrom := composed (pgUrl migratorKey secretsDb "secrets-db") }
    resource secrets "secrets-db-observer-url" { valueFrom := composed (pgUrl observerKey secretsDb "secrets-db") }
    resource secrets "secrets-db-runtime-url" as secretsDbUrl
      { valueFrom := composed (pgUrl runtimeKey secretsDb "secrets-db") }

    resource secrets "typednotes-db-migrator-url" { valueFrom := composed (pgUrl migratorKey appDb "typednotes-db") }
    resource secrets "typednotes-db-observer-url"
      { valueFrom := composed (pgUrl observerKey appDb "typednotes-db") }
    resource secrets "typednotes-db-runtime-url" as appDbUrl
      { valueFrom := composed (pgUrl runtimeKey appDb "typednotes-db") }
    resource secrets "typednotes-compute-url" as computeDbUrl
      { valueFrom := composed (computeUrl computeDb computePassword) }

    -- The observer's URL again, for pgweb, whose driver sends no SNI: see
    -- `pgUrlWithoutSni`. A separate secret rather than a changed
    -- `typednotes-db-observer-url` — composed secrets are create-only, and
    -- that one is also what infra observes migrations through.
    --
    -- Named `…-pgweb-url`, not `…-inspector-url`: the latter was composed by
    -- infra 0.14.0, whose secrets listing reported a pre-existing key's
    -- principal as "", so it holds a URL with an empty user name (pgweb:
    -- `authentication failed`). Composed secrets are create-only, so a new
    -- name is what gets a fresh one; infra 0.14.1 fixes the listing.
    resource secrets "typednotes-db-pgweb-url" as inspectorDbUrl
      { valueFrom := composed (pgUrlWithoutSni observerKey appDb "typednotes-db") }

    -- ── Migration histories ─────────────────────────────────────────────
    -- `users`, `identities`, `orgs`, `memberships` (`core.md` §4).
    resource postgresMigrations "typednotes-core-history" as coreHistory
      { database := "typednotes-db"
      , connectionSecret := "typednotes-db-migrator-url"
      , observerSecret := "typednotes-db-observer-url"
      , schema := "core"
      , migrations := appMigrations }

    -- `usage_events`, `credit_ledger`, `credit_holds`. Its SQL
    -- `references orgs(id)` and `users(id)`, so infra applies it after the
    -- core history — read from the SQL, not declared.
    resource postgresMigrations "typednotes-ledger-history" as ledgerHistory
      { database := "typednotes-db"
      , connectionSecret := "typednotes-db-migrator-url"
      , observerSecret := "typednotes-db-observer-url"
      , schema := "ledger"
      , migrations := ledgerMigrations }

    -- `audit_log`, which references nothing (it must record even malformed
    -- attempts), so no order against the others.
    resource postgresMigrations "typednotes-liaison-history" as liaisonHistory
      { database := "typednotes-db"
      , connectionSecret := "typednotes-db-migrator-url"
      , observerSecret := "typednotes-db-observer-url"
      , schema := "liaison"
      , migrations := liaisonMigrations }

    -- `kv_store`, from the directory `secrets-server`'s sqlx migrations live in.
    resource postgresMigrations "secrets-history" as secretsHistory
      { database := "secrets-db"
      , connectionSecret := "secrets-db-migrator-url"
      , observerSecret := "secrets-db-observer-url"
      , schema := "secrets"
      , migrations := secretsMigrations }

    -- ── Containers ──────────────────────────────────────────────────────
    -- Declared rather than assumed: Serverless Containers will not place a
    -- container into a namespace that does not exist. Creating it also
    -- creates the Container Registry namespace of the same name.
    resource scalewayContainerNamespace "typednotes" as ns
      { description := "typednotes services" }

    resource scalewayContainer "secrets-server" as secretsServer
      { namespace' := ns
      , image      := secretsImage
      , port       := 8200
      , migrations := [secretsHistory]
      -- A username is not a secret; its password partner is below, and
      -- `config.validate()` rejects one without the other. Migrations are
      -- infra's: the server only checks that `kv_store` exists.
      -- The service identities are plain config naming the env vars their
      -- passwords are in; those are the same secrets the app and liaison
      -- log in with, so the two sides cannot drift apart.
      , env        := [ ("SECRETS_SERVER_BOOTSTRAP_USERNAME", "admin")
                      , ("SECRETS_SERVER_STORAGE_MIGRATE", "false")
                      , ("SECRETS_SERVER_SERVICE_IDENTITIES", vaultServiceIdentities) ]
      , secretEnv  := [ ("SECRETS_MASTER_KEY", masterKey)
                      , ("SECRETS_SERVER_BOOTSTRAP_PASSWORD", bootstrapPassword)
                      , ("SECRETS_SERVER_STORAGE_DATABASE_URL", secretsDbUrl)
                       , ("APP_SECRETS_PASSWORD", appSecretsPassword)
                       , ("LIAISON_SECRETS_PASSWORD", liaisonSecretsPassword)
                       , ("LUN_SECRETS_PASSWORD", lunSecretsPassword) ] }

    -- These workers own process-local state. Keep exactly one instance warm;
    -- their disk is still ephemeral and a rollout invalidates unfinished runs.
    resource scalewayContainer "lun" as lunContainer
      { namespace' := ns
      , image := lunImage
      , port := 8080
      , minScale := Typednotes.Notebook.workerCapacity.minScale
      , maxScale := Typednotes.Notebook.workerCapacity.maxScale
      , memoryMb := 4096
      , cpuLimit := 2000
      , timeoutSec := 900
      , env := Expr.ap (Expr.map (fun vault broker =>
          [ ("LUN_PORT", "8080"), ("LUN_LIAISON_URL", s!"https://{broker.url}")
          , ("SECRETS_HOST", vault.url), ("SECRETS_USERNAME", "lun")
          , ("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt")
          , ("SSL_CERT_DIR", "/etc/ssl/certs") ]) (observedOf secretsServer))
          (observedOf liaisonContainer)
      , secretEnv := [("LUN_TOKEN", lunToken), ("LUN_ID_SALT", lunIdSalt),
          ("SECRETS_PASSWORD", lunSecretsPassword)] }

    resource scalewayContainer "lode" as lodeContainer
      { namespace' := ns
      , image := lodeImage
      , port := 8080
      , minScale := Typednotes.Notebook.workerCapacity.minScale
      , maxScale := Typednotes.Notebook.workerCapacity.maxScale
      , memoryMb := 4096
      , cpuLimit := 2000
      , timeoutSec := 900
      , env := Expr.ap (Expr.map (fun runner broker =>
          [ ("LODE_PORT", "8080"), ("LODE_LUN_URL", s!"https://{runner.url}")
          , ("LODE_LIAISON_URL", s!"https://{broker.url}")
          , ("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt")
          , ("SSL_CERT_DIR", "/etc/ssl/certs") ]) (observedOf lunContainer))
          (observedOf liaisonContainer)
      , secretEnv := [("LODE_TOKEN", lodeToken), ("LODE_LUN_TOKEN", lunToken)] }

    -- The Dioxus fullstack app: SSR, the wasm client, the server functions,
    -- the OAuth round trips and the Slack/WhatsApp webhooks, from one binary. `PORT` is set by Scaleway;
    -- `IP=0.0.0.0` is baked into the image. It writes connection
    -- credentials into the vault (and cannot read them back), mints warrants
    -- with liaison's root key, and grants each new org ledger's welcome
    -- credits — so it waits for ledger's history too, and is created after
    -- the two containers whose domains it reads. `PUBLIC_URL` pins the
    -- origin of the OAuth redirect URIs to the custom domain, whichever host
    -- the request arrived on — so a visit to the Scaleway domain still signs
    -- in through the registered callbacks. `env` is compared on apply, so
    -- changing it redeploys the app.
    resource scalewayContainer "typednotes-app"
      { namespace' := ns
      , image      := appImage
      , port       := 8080
      , migrations := [coreHistory, ledgerHistory]
      , minScale   := Typednotes.Notebook.workerCapacity.minScale
      , maxScale   := Typednotes.Notebook.workerCapacity.maxScale
      , timeoutSec := 120
      , env        := Expr.ap (Expr.ap (Expr.ap (Expr.map (fun vault broker writer runner =>
                        [ ("SECRETS_URL", s!"https://{vault.url}")
                        , ("SECRETS_USERNAME", "typednotes-app")
                        , ("LIAISON_URL", s!"https://{broker.url}")
                        , ("LODE_URL", s!"https://{writer.url}")
                        , ("LUN_URL", s!"https://{runner.url}")
                        , ("PUBLIC_URL", appPublicUrl) ])
                        (observedOf secretsServer)) (observedOf liaisonContainer))
                        (observedOf lodeContainer)) (observedOf lunContainer)
      , secretEnv  := [ ("DATABASE_URL", appDbUrl)
                       , ("COMPUTE_DB_URL", computeDbUrl)
                       , ("LODE_TOKEN", lodeToken)
                       , ("LUN_TOKEN", lunToken)
                      , ("SECRETS_PASSWORD", appSecretsPassword)
                      , ("LIAISON_ROOT_KEY", liaisonRootKey)
                      , ("GITHUB_CLIENT_ID", githubClientId)
                      , ("GITHUB_CLIENT_SECRET", githubClientSecret)
                      , ("GOOGLE_CLIENT_ID", googleClientId)
                      , ("GOOGLE_CLIENT_SECRET", googleClientSecret)
                      , ("GITLAB_CLIENT_ID", gitlabClientId)
                      , ("GITLAB_CLIENT_SECRET", gitlabClientSecret)
                      , ("DROPBOX_CLIENT_ID", dropboxClientId)
                      , ("DROPBOX_CLIENT_SECRET", dropboxClientSecret)
                      , ("SLACK_CLIENT_ID", slackClientId)
                      , ("SLACK_CLIENT_SECRET", slackClientSecret)
                      , ("SLACK_SIGNING_SECRET", slackSigningSecret)
                      , ("WHATSAPP_APP_SECRET", whatsappAppSecret)
                      , ("WHATSAPP_VERIFY_TOKEN", whatsappVerifyToken) ] }

    -- The hold sweeper. It serves only `/health`, and `minScale := 1`
    -- because scale-to-zero would stop the sweeper whenever nobody polled
    -- it — expired holds would never be released.
    resource scalewayContainer "ledger"
      { namespace' := ns
      , image      := ledgerImage
      , port       := 8080
      , minScale   := 1
      , migrations := [ledgerHistory]
      , secretEnv  := [ ("DATABASE_URL", appDbUrl) ] }

    -- The broker. It writes ledger's `credit_holds`/`credit_ledger` as well
    -- as its own `audit_log` — a dependency in its code, not its SQL — so its
    -- rollout waits for both histories. Core's connector-authority history
    -- is also a rollout prerequisite for the app/broker 0.6.0 contract.
    -- `SECRETS_HOST` is the vault
    -- container's own domain, read from what Scaleway reports once it
    -- exists — an ordering edge as well as a value, so `liaison` is always
    -- created after `secrets-server`.
    -- It logs in to the vault as `liaison` (read, plus create to write back
    -- a refreshed OAuth token), and refreshes Drive, GitLab and Dropbox
    -- tokens with the same OAuth clients as the app.
    resource scalewayContainer "liaison" as liaisonContainer
      { namespace' := ns
      , image      := liaisonImage
      , port       := 8080
      , migrations := [coreHistory, ledgerHistory, liaisonHistory]
      -- `SSL_CERT_*`: Lean's static OpenSSL has no trust store of its own
      -- (the same reason `apply.yml` sets them), so without these every
      -- HTTPS call liaison makes — the vault, every provider — fails to
      -- verify. liaison ≥ 0.4.1 bakes them into its image; kept here so the
      -- fleet does not depend on that.
      , env        := (observedOf secretsServer).map fun vault =>
                        [ ("SECRETS_HOST", vault.url), ("SECRETS_USERNAME", "liaison")
                        , ("LIAISON_PORT", "8080")
                        , ("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt")
                        , ("SSL_CERT_DIR", "/etc/ssl/certs") ]
      , secretEnv  := [ ("LIAISON_ROOT_KEY", liaisonRootKey)
                      , ("DATABASE_URL", appDbUrl)
                      , ("SECRETS_PASSWORD", liaisonSecretsPassword)
                      , ("GOOGLE_CLIENT_ID", googleClientId)
                      , ("GOOGLE_CLIENT_SECRET", googleClientSecret)
                      , ("GITLAB_CLIENT_ID", gitlabClientId)
                      , ("GITLAB_CLIENT_SECRET", gitlabClientSecret)
                      , ("DROPBOX_CLIENT_ID", dropboxClientId)
                      , ("DROPBOX_CLIENT_SECRET", dropboxClientSecret) ] }

    -- A web UI to inspect `typednotes-db` — Scaleway's console has none for
    -- Serverless SQL (only connection strings for `psql`). Three layers:
    -- HTTP basic auth with operator-supplied credentials; the *observer*
    -- identity, which can only `SELECT`, so nothing can be changed through
    -- it even past the password; and `PGWEB_LOCK_SESSION`, which disables
    -- pgweb's "connect to another server" form, so it cannot be turned into
    -- a proxy to arbitrary hosts. It waits for every history on the
    -- database, so it first comes up on the full schema. The vault's
    -- database is deliberately not exposed: it holds only ciphertext.
    resource scalewayContainer "db-inspector"
      { namespace' := ns
      , image      := inspectorImage
      , port       := 8081
      , migrations := [coreHistory, ledgerHistory, liaisonHistory]
      , env        := [ ("PGWEB_LOCK_SESSION", "1") ]
      , secretEnv  := [ ("PGWEB_DATABASE_URL", inspectorDbUrl)
                      , ("PGWEB_AUTH_USER", inspectorUser)
                      , ("PGWEB_AUTH_PASS", inspectorPassword) ] }

/-- The ownership boundary, which the `fleet` command has no syntax for: it is
    an argument to `Infra.Cli.run`, in `Main.lean`.

    The prefixes are here because of the databases. A Serverless SQL Database
    carries no tags and no description — nothing but the name it was created
    with — so the name is the only evidence of ownership, and a database
    under no prefix could be created by this fleet and then never adopted or
    destroyed. `secrets-` is what the vault's database was already called
    (infra never renames), and `typednotes-` names the app's; two prefixes
    need infra ≥ 0.14.0's `namePrefixes`. Everything else is tagged normally.

    The account also holds an unrelated Serverless SQL database called
    `typednotes`, created long before this fleet. It matches neither prefix —
    `typednotes-` needs the dash — so it stays foreign and is left alone.

    `fleetName` makes the marker's *value* meaningful rather than just its
    presence, so a second fleet in this account could not claim these
    resources by name. -/
def typednotesBoundary : Boundary :=
  { fleetName := some "typednotes"
    namePrefix := some "secrets-"
    namePrefixes := ["typednotes-"] }

-- ── Offline guarantees ────────────────────────────────────────────────────

-- No plaintext secret is written into this file.
#guard typednotes.plan.secretsAreSound

-- Every history is sound as far as can be checked offline: ids from the file
-- names, in order; every source an `https://` URL; quotable schemas. Their
-- content, and the order it implies, are checked by `plan` after fetching.
#guard typednotes.plan.migrationsAreSound

-- Scaleway only: AWS credentials are neither needed nor read.
#guard typednotes.keys.providers = [.scaleway]

-- Paris means `fr-par`.
#guard (typednotes.regions.region .scaleway).map Region.code = some "fr-par"
#guard typednotes.regions.covers typednotes.keys

-- Every database is claimable: the name rung decides `postgres`, silently —
-- a database named outside the boundary's prefixes would apply cleanly and
-- then be unmanageable for ever.
#guard (Finite.elems (α := typednotes.keys.Key .scaleway .postgres)).all fun key =>
  typednotesBoundary.prefixes.any fun p =>
    (typednotes.keys.name .scaleway .postgres key).startsWith p

-- Three identities, three minted keys. A fourth `apiKeyFor` without a fourth
-- `iam` resource to mint against fails here.
#guard typednotes.keys.count .scaleway .iam = 3

-- Four histories, seven containers and a dedicated classic compute database.
#guard typednotes.keys.count .scaleway .postgresMigrations = 4
#guard typednotes.keys.count .scaleway .scalewayContainer = 7
#guard typednotes.keys.count .scaleway .postgres = 3

/- The inspector's URL, composed against stand-in observed values (the same
   evaluation the apply performs, with real ones): the observer's
   credentials, the database's endpoint, and the `databaseid` option pgweb's
   driver needs in place of SNI. The key's two halves are redacted, exactly as
   a dry run renders them. -/
private def fakeEnv : Env typednotes.keys.Key :=
  Env.withRedactedSecrets
    { observed := fun p k key =>
        match p, k with
        | .scaleway, .postgres => some
            { handle := ⟨"8766c6e0-fc9d-4a6b-901b-b7cc6e3403d8"⟩
              endpoint := "8766c6e0-fc9d-4a6b-901b-b7cc6e3403d8.pg.sdb.fr-par.scw.cloud:5432" }
        | .scaleway, .secrets => some
             { handle := ⟨"s"⟩, version := "1", accessKey := "SCWXXXX", principal := "app-id" }
        | .scaleway, .scalewayContainer => some
            { handle := ⟨typednotes.keys.name .scaleway .scalewayContainer key⟩
              url := s!"{typednotes.keys.name .scaleway .scalewayContainer key}.example.invalid" }
        | _, _ => none }

#guard match typednotes.keys.keyOfName? .scaleway .secrets "typednotes-db-pgweb-url" with
  | none => false
  | some key =>
    match typednotes.plan.assign .scaleway .secrets key with
    | .present s => match Expr.eval? fakeEnv s.valueFrom with
      | some (.composed url) => url ==
          "postgres://app-id:%3Credacted%3E@8766c6e0-fc9d-4a6b-901b-b7cc6e3403d8.pg.sdb.fr-par.scw.cloud:5432/typednotes-db?sslmode=require&options=databaseid%3D8766c6e0-fc9d-4a6b-901b-b7cc6e3403d8"
      | _ => false
    | _ => false

-- Every declared container tracks latest content, including notebook workers
-- and the inspector. Inspect the resource specs, not just the image constants.
#guard (Finite.elems (α := typednotes.keys.Key .scaleway .scalewayContainer)).all fun key =>
  match typednotes.plan.assign .scaleway .scalewayContainer key with
  | .present spec => spec.image.asLit.any (·.endsWith ":latest")
  | _ => false
-- No trailing slash: the app appends `/auth/…` to it.
#guard appPublicUrl = "https://app.typednotes.com"
-- Exactly what `secrets-server`'s own config test parses.
#guard vaultServiceIdentities =
  "[{username=\"typednotes-app\", password_env=\"APP_SECRETS_PASSWORD\", " ++
  "rules=[{prefix=\"secret/data/thirdparty/\", capabilities=[\"create\",\"delete\"]}," ++
  "{prefix=\"secret/data/connector-policy/\", capabilities=[\"create\",\"update\",\"delete\"]}," ++
  "{prefix=\"secret/data/connector-authority/\", capabilities=[\"create\",\"update\",\"delete\"]}," ++
  "{prefix=\"secret/data/compute/\", capabilities=[\"create\",\"delete\"]}," ++
  "{prefix=\"secret/data/graph/\", capabilities=[\"create\",\"delete\"]}]}, " ++
  "{username=\"liaison\", password_env=\"LIAISON_SECRETS_PASSWORD\", " ++
  "rules=[{prefix=\"secret/data/thirdparty/\", capabilities=[\"read\",\"create\"]}," ++
  "{prefix=\"secret/data/connector-policy/\", capabilities=[\"read\"]}," ++
  "{prefix=\"secret/data/connector-authority/\", capabilities=[\"read\"]}]}, " ++
  "{username=\"lun\", password_env=\"LUN_SECRETS_PASSWORD\", rules=[" ++
  "{prefix=\"secret/data/connector-policy/\", capabilities=[\"read\"]}," ++
  "{prefix=\"secret/data/connector-authority/\", capabilities=[\"read\"]}," ++
  "{prefix=\"secret/data/compute/\", capabilities=[\"read\"]}," ++
  "{prefix=\"secret/data/graph/\", capabilities=[\"read\",\"create\",\"update\"]}," ++
  "{prefix=\"secret/metadata/graph/\", capabilities=[\"read\",\"list\"]}," ++
  "{prefix=\"secret/data/thirdparty/postgres/\", capabilities=[\"read\"]}," ++
  "{prefix=\"secret/data/thirdparty/vault/\", capabilities=[\"read\"]}]}]"
#guard appMigrations.map (·.source) =
  [ .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0001_core.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0002_sessions_connections.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0003_projects_channels.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0004_computations.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0005_productivity_connections.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0006_ai_providers.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0007_notebook_contracts.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0008_connector_authority.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0009_connection_provider_guard.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0010_user_workspaces.sql"
  , .url "https://raw.githubusercontent.com/typednotes/typednotes/v0.9.0/migrations/0011_notebook_shares.sql" ]
#guard appMigrations.map (·.id) = ["0001", "0002", "0003", "0004", "0005", "0006", "0007", "0008", "0009", "0010", "0011"]
#guard ledgerMigrations.map (·.id) = ["0001", "0002"]
#guard secretsMigrations.map (·.source) =
  [.url "https://raw.githubusercontent.com/typednotes/secrets/v1.3.0/crates/secrets-storage-postgres/src/migrations/0001_init.sql"]

/- The order a first apply runs in, pinned offline. `runsBefore` reads the
   *scheduled* order, not the declaration order, and a missing slot answers
   false so a rename fails the guard instead of quietly satisfying it. -/
private def firstApplyOrder : List String :=
  match orderActions typednotes.plan (actions typednotes.plan (worldOf [])) with
  | .ok ordered => ordered.map Action.slot
  | .error _    => []

private def runsBefore (a b : String) : Bool :=
  match firstApplyOrder.idxOf? a, firstApplyOrder.idxOf? b with
  | some i, some j => i < j
  | _,      _      => false

private def history (n : String) : String := s!"scaleway/postgres-migrations/{n}"
private def container (n : String) : String := s!"scaleway/scaleway-container/{n}"

-- (The order *between* histories comes from their SQL, which is fetched at
-- `plan`, so it cannot be pinned here; `plan` refuses what it cannot order.)

-- Each history waits for its database and its read-write URL.
#guard runsBefore "scaleway/postgres/typednotes-db" (history "typednotes-core-history")
#guard runsBefore "scaleway/secrets/typednotes-db-migrator-url" (history "typednotes-core-history")
#guard runsBefore "scaleway/postgres/secrets-db" (history "secrets-history")

-- Every rollout waits for its schema.
#guard runsBefore (history "secrets-history") (container "secrets-server")
#guard runsBefore (history "typednotes-core-history") (container "typednotes-app")
#guard runsBefore (history "typednotes-ledger-history") (container "ledger")
#guard runsBefore (history "typednotes-liaison-history") (container "liaison")
-- liaison writes ledger's tables, so it waits for that history too.
#guard runsBefore (history "typednotes-ledger-history") (container "liaison")
#guard runsBefore (history "typednotes-core-history") (container "liaison")
#guard runsBefore (history "typednotes-core-history") (container "db-inspector")
#guard runsBefore (history "typednotes-ledger-history") (container "db-inspector")
#guard runsBefore (history "typednotes-liaison-history") (container "db-inspector")

-- `liaison` reads the vault's domain, so it is created after it.
#guard runsBefore (container "secrets-server") (container "liaison")
-- The app reads both domains, and grants ledger's credits.
#guard runsBefore (container "secrets-server") (container "typednotes-app")
#guard runsBefore (container "liaison") (container "typednotes-app")
#guard runsBefore (history "typednotes-ledger-history") (container "typednotes-app")

-- Real resource references order every writer/runtime dependency before the app.
#guard runsBefore (container "secrets-server") (container "lun")
#guard runsBefore (container "liaison") (container "lun")
#guard runsBefore (container "lun") (container "lode")
#guard runsBefore (container "liaison") (container "lode")
#guard runsBefore (container "lode") (container "typednotes-app")
#guard runsBefore (container "lun") (container "typednotes-app")
#guard runsBefore "scaleway/postgres/typednotes-compute-db" "scaleway/secrets/typednotes-compute-url"
#guard runsBefore "scaleway/secrets/typednotes-compute-url" (container "typednotes-app")

private def notebookContainer? (name : String) :
    Option (ScalewayContainerSpec typednotes.keys.Key Partial (Expr typednotes.keys.Key)) :=
  match typednotes.keys.keyOfName? .scaleway .scalewayContainer name with
  | none => none
  | some key => match typednotes.plan.assign .scaleway .scalewayContainer key with
    | .present spec => some spec
    | _ => none

-- These checks inspect the authored fleet, including resolved dependency URLs.
#guard ["typednotes-app", "lode", "lun"].all fun name =>
  match notebookContainer? name with
  | some spec => Expr.eval? fakeEnv (spec.minScale.getD (.lit 0)) == some 1 &&
      Expr.eval? fakeEnv (spec.maxScale.getD (.lit 0)) == some 1
  | none => false

#guard match notebookContainer? "typednotes-app" with
  | some spec => match Expr.eval? fakeEnv (spec.env.getD (.lit [])) with
    | some env => env.lookup "LODE_URL" == some "https://lode.example.invalid" &&
        env.lookup "LUN_URL" == some "https://lun.example.invalid"
    | none => false
  | none => false

#guard match notebookContainer? "lun" with
  | some spec => match Expr.eval? fakeEnv (spec.secretEnv.getD (.lit [])) with
    | some env => !(env.map (·.1)).contains "COMPUTE_DB_URL" &&
        !(env.map (·.1)).contains "LIAISON_ROOT_KEY"
    | none => false
  | none => false
