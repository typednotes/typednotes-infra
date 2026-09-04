import Infra

/-
  The declared fleet: everything this project manages.

  Declared with `infra`'s `fleet` command (see its `docs/architecture.md`,
  "Declaring a fleet"). Everything below is a resource; there is no `Keys`
  table, no `assign` match, and no `.lit`/`.known` wrappers — those are
  generated or coerced. To manage something new, add a `resource` line.

  **Scoping.** A `(provider, kind)` pair not named below, or a name not listed
  under a pair that is, has no key for the plan to mention — so whatever
  exists there in the account is left alone, unconditionally. This fleet is
  Scaleway-only, so AWS is never authenticated and never called.

  ## The `secrets-server` target

  A Scaleway Serverless Container backed by a serverless Postgres database,
  plus the three secrets it needs: its own master key, the database's master
  password, and the database URL.

  **The database URL is composed at apply time, not by hand.** Its value needs
  the master password *and* the endpoint Scaleway assigns when the database is
  created, so it used to take two applies with an operator pasting a
  connection string in between. `composed` holds the function instead; `infra`
  orders the password and the database before it and evaluates it once, at
  apply time, without the value ever entering this file, the plan output, or
  the `.infra/` cache. **One `push --apply` deploys the whole fleet.**

  **The image is mirrored into Scaleway Container Registry rather than pulled
  from GHCR.** Scaleway's docs say public external registries work but
  discourage them for production ("uncontrolled rate limiting"), and do not
  support private ones at all — and this GHCR package is private. The
  `secrets` repo's `docker-publish.yml` pushes there via `skopeo copy`.
  Neither half of that has been confirmed against a live account; see
  `infra`'s `docs/providers.md`.
-/

open Infra.Core
open Infra.Specs

fleet typednotes where
  resource scaleway secrets "secrets-master-key" as masterKey
    { valueFrom := fromEnv "SECRETS_MASTER_KEY" }

  resource scaleway secrets "secrets-db-password" as dbPassword
    { valueFrom := fromEnv "SECRETS_DB_PASSWORD" }

  -- Composed from a secret this fleet owns and an endpoint that does not exist
  -- until `secrets-db` is created. Both become ordering edges, so this is
  -- created after them; the value is never known here.
  resource scaleway secrets "secrets-db-url" as dbUrl
    { valueFrom := composed
        expr!"postgres://secretsadmin:{secretValueOf dbPassword}@{endpointOf secretsDb}/secrets" }

  resource scaleway postgres "secrets-db" as secretsDb
    { masterUsername       := "secretsadmin"
    , masterPasswordSecret := "secrets-db-password"
    , minCapacity          := 1
    , maxCapacity          := 4 }

  -- The namespace the container is placed into. Declared here rather than
  -- assumed: Serverless Containers will not place a container into a namespace
  -- that does not exist, and `namespace'` is a reference, so this is created
  -- first and cannot be misspelled. Creating it also creates the Container
  -- Registry namespace the image below is pushed to.
  resource scaleway scalewayContainerNamespace "typednotes" as ns
    { description := "typednotes services" }

  resource scaleway scalewayContainer "secrets-server"
    { namespace' := ns
    , image      := "rg.fr-par.scw.cloud/typednotes/secrets-server:latest"
    , port       := 8200
    , secretEnv  := [ ("SECRETS_MASTER_KEY", masterKey)
                    , ("SECRETS_SERVER_STORAGE_DATABASE_URL", dbUrl) ] }

-- No plaintext secret is written into this file. Decidable, so it is checked
-- at compile time rather than trusted — see `infra`'s `docs/diff-semantics.md`.
#guard typednotes.plan.secretsAreSound

-- Scaleway only: AWS credentials are neither needed nor read.
#guard typednotes.keys.providers = [.scaleway]
