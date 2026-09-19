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

  ## Where it is

  `in paris` places the fleet at `fr-par`, Scaleway's Paris region. It used to
  come from `SCW_DEFAULT_REGION`, supplied to CI as a repo secret — invisible
  in the repo, unpinned, and free to disagree with the `rg.fr-par.scw.cloud`
  baked into the image URL below without anything noticing. The account guard
  in `Main.lean` checks the organization, not the region, so nothing did.
  Declaring it here removes the secret and the disagreement: `infra` builds
  every Scaleway endpoint from this rather than from the environment.

  Every resource here is Scaleway's, so the cloud is written once in a
  `provider` block rather than six times. That is grouping and nothing else —
  `infra`'s `Infra/Demo.lean` declares one fleet both ways and guards that the
  keys, names, plan and ordering come out identical.

  **For now, the image is pulled straight from GHCR** —
  `ghcr.io/typednotes/secrets-server:latest`, which is public — rather than
  mirrored into Scaleway Container Registry. Scaleway's docs say pulling a
  public external image works but discourage it for production
  ("uncontrolled rate limiting"), and the `secrets` repo's
  `docker-publish.yml` already has a `skopeo copy` step ready to mirror
  `latest` into `rg.fr-par.scw.cloud/typednotes/secrets-server:latest` on a
  tagged release. Switch `image` below to that once it's actually been run
  and the tag exists there.
-/

open Infra.Core
open Infra.Specs

fleet typednotes in paris where
  provider scaleway where
    resource secrets "secrets-master-key" as masterKey
      { valueFrom := fromEnv "SECRETS_MASTER_KEY" }

    resource secrets "secrets-db-password" as dbPassword
      { valueFrom := fromEnv "SECRETS_DB_PASSWORD" }

    -- Composed from a secret this fleet owns and an endpoint that does not exist
    -- until `secrets-db` is created. Both become ordering edges, so this is
    -- created after them; the value is never known here.
    --
    -- **The password is percent-encoded, and has to be.** Whatever
    -- `SECRETS_DB_PASSWORD` holds goes into the URL's *authority*, where `/`,
    -- `@`, `:`, `#` and `?` are punctuation rather than data. A single `/` in
    -- it ends the authority early, so the parser reads `secretsadmin` as the
    -- host and the fragment after the colon as the port, and `PgPool::connect`
    -- refuses the whole string with "invalid port number".
    --
    -- That is not hypothetical: the container crash-looped on exactly this,
    -- and the error named a port rather than a password because nothing may
    -- print the value — not this file, not the plan, not the `.infra/` cache.
    -- The password could not be inspected, so the message was the only
    -- evidence, and it pointed at the wrong field. `urlEncode` escapes
    -- everything outside RFC 3986 §2.3's unreserved set (`A-Za-z0-9-_.~`),
    -- which makes the composition correct for *any* password rather than for
    -- the ones that happen to avoid those five characters.
    resource secrets "secrets-db-url" as dbUrl
      { valueFrom := composed
          expr!"postgres://secretsadmin:\
{(secretValueOf dbPassword).map Network.HTTP.Types.urlEncode}\
@{endpointOf secretsDb}/secrets" }

    resource postgres "secrets-db" as secretsDb
      { masterUsername       := "secretsadmin"
      , masterPasswordSecret := "secrets-db-password"
      , minCapacity          := 1
      , maxCapacity          := 4 }

    -- The namespace the container is placed into. Declared here rather than
    -- assumed: Serverless Containers will not place a container into a namespace
    -- that does not exist, and `namespace'` is a reference, so this is created
    -- first and cannot be misspelled. Creating it also creates the Container
    -- Registry namespace the image below is pushed to.
    resource scalewayContainerNamespace "typednotes" as ns
      { description := "typednotes services" }

    resource scalewayContainer "secrets-server"
      { namespace' := ns
      , image      := "ghcr.io/typednotes/secrets-server:latest"
      , port       := 8200
      , secretEnv  := [ ("SECRETS_MASTER_KEY", masterKey)
                      , ("SECRETS_SERVER_STORAGE_DATABASE_URL", dbUrl) ] }

-- No plaintext secret is written into this file. Decidable, so it is checked
-- at compile time rather than trusted — see `infra`'s `docs/diff-semantics.md`.
#guard typednotes.plan.secretsAreSound

-- Scaleway only: AWS credentials are neither needed nor read.
#guard typednotes.keys.providers = [.scaleway]

-- Paris means `fr-par` here. Independent of the image's registry host — the
-- container's own placement is the only thing this guard is about.
#guard (typednotes.regions.region .scaleway).map Region.code = some "fr-par"
#guard typednotes.regions.covers typednotes.keys
