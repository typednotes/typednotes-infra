import Infra

/-
  The declared fleet: everything this project manages, across both clouds.

  Uses `Infra.Core.Ergonomics`'s `Keys.build`/`Keys.assignFromNamed` (see `infra`'s
  `docs/architecture.md`, "Declaring a fleet") rather than `Infra.Demo`'s hand-rolled
  `inductive`-per-resource-set style: this project's fleet grows by adding rows to
  `fleetKeyTable` and entries to `fleetPlan.assign`, not by writing a new `Finite` instance per
  resource-set.

  ## The `secrets-server` target

  A Scaleway Serverless Container (`secrets-server`) backed by a serverless Postgres database
  (`secrets-db`), plus three `.secrets` resources it needs: the container's own master key,
  the database's master password, and the composed database URL the container reads at
  startup.

  **The container image is mirrored into Scaleway Container Registry, not pulled from GHCR
  directly.** Scaleway's own docs confirm Serverless Containers *can* pull public images from an
  external registry like `ghcr.io`, but explicitly discourage it for anything real ("uncontrolled
  rate limiting, which can lead to failures when starting resources"), and private external
  registries are unsupported outright — the `secrets` repo's GHCR package is private. So `image`
  below points at `rg.fr-par.scw.cloud/typednotes/secrets-server`, which the `secrets` repo's
  `docker-publish.yml` pushes to (via `skopeo copy` from the `ghcr.io` image it already builds),
  alongside the `typednotes` Serverless Containers namespace this container declares below — which
  implicitly gives that namespace its own Container Registry namespace, per Scaleway's docs.

  **The DB-URL secret needs a two-phase apply**, because its value is a composite of the
  master password (known before creation) and the database's *observed* endpoint (only known
  after creation) — and the engine must never compute or hold that concatenation itself.
  Apply 1: `secrets-db`, `secrets-master-key`, `secrets-db-password` only — comment out
  `secrets-server` and `secrets-db-url` below for that apply. Between applies, read
  `secrets-db`'s observed endpoint (`pull`, or the console), compose
  `postgres://<user>:<password>@<endpoint>/<db>` by hand, and export it as the
  `SECRETS_DB_URL` env var. Apply 2: restore `secrets-db-url` and `secrets-server` and apply
  again.
-/

namespace TypednotesInfra

open Infra.Core
open Infra.Specs

def secretNames : List String :=
  ["secrets-master-key", "secrets-db-password", "secrets-db-url"]

def fleetKeyTable : ProviderId → Kind → KeySpec
  | .scaleway, .secrets           => .named secretNames
  | .scaleway, .postgres          => .named ["secrets-db"]
  | .scaleway, .scalewayContainer => .named ["secrets-server"]
  | _,         _                  => .unused

def fleetKeys : Keys := Keys.build fleetKeyTable

def secretsDbSpec : PostgresSpec fleetKeys.Key Partial (Expr fleetKeys.Key) :=
  PostgresSpec.serverless
    (.lit "secrets-db") (.lit "secretsadmin") (.lit "secrets-db-password")
    (.lit 1) (.lit 4)

def secretsServerSpec : ScalewayContainerSpec fleetKeys.Key Partial (Expr fleetKeys.Key) where
  name       := .lit "secrets-server"
  namespace' := .lit "typednotes"
  -- Mirrored from GHCR, not pulled from there directly — see this file's doc comment above.
  image      := .lit "rg.fr-par.scw.cloud/typednotes/secrets-server:latest"
  port       := .known (.lit 8200)
  minScale   := .unknown
  maxScale   := .unknown
  memoryMb   := .unknown
  cpuLimit   := .unknown
  timeoutSec := .unknown
  env        := .unknown
  secretEnv  := .known (.lit
    [ ("SECRETS_MASTER_KEY", NamedKey.of secretNames "secrets-master-key")
    , ("SECRETS_SERVER_STORAGE_DATABASE_URL", NamedKey.of secretNames "secrets-db-url") ])

/-- Bound separately from `fleetPlan.assign` below (rather than applied to `key` inline) so that
    `Keys.assignFromNamed`'s trailing `_h` autoParam is resolved by its own `by decide` default
    while this application is still exactly three explicit arguments — applying `key` in the same
    chain would instead bind it to `_h`'s position, since autoParams are ordinary explicit
    parameters positionally. -/
def secretsAssign :=
  Keys.assignFromNamed (κ := fleetKeys) .scaleway .secrets
    [ ("secrets-master-key",
        .present { name := .lit "secrets-master-key", valueFrom := .lit "SECRETS_MASTER_KEY" })
    , ("secrets-db-password",
        .present { name := .lit "secrets-db-password", valueFrom := .lit "SECRETS_DB_PASSWORD" })
    , ("secrets-db-url",
        .present { name := .lit "secrets-db-url", valueFrom := .lit "SECRETS_DB_URL" }) ]

def postgresAssign :=
  Keys.assignFromNamed (κ := fleetKeys) .scaleway .postgres [ ("secrets-db", .present secretsDbSpec) ]

def containerAssign :=
  Keys.assignFromNamed (κ := fleetKeys) .scaleway .scalewayContainer
    [ ("secrets-server", .present secretsServerSpec) ]

def fleetPlan : Plan fleetKeys where
  assign
    | .scaleway, .secrets,           key => secretsAssign key
    | .scaleway, .postgres,          key => postgresAssign key
    | .scaleway, .scalewayContainer, key => containerAssign key
    | _,         _,                  _   => .unmanaged
  outside := .unmanaged

end TypednotesInfra
