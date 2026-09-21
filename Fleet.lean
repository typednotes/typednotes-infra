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
  plus the IAM identity that database authenticates and the three secrets:
  the container's own master key, the identity's minted API key, and the
  database URL.

  **Serverless SQL Database has no master user.** There is no root password
  to set: authentication is IAM, the PostgreSQL user name is an IAM
  application's *id*, and the password is that application's API secret key.
  `masterUsername`/`masterPasswordSecret` below are required by the portable
  spec and discarded by this product, so they say so rather than naming a
  plausible `secretsadmin` that is never created — which is exactly what made
  an earlier version of this file look correct while provisioning no
  credentials at all.

  **Neither half of that key can be written here.** Scaleway returns an API
  key's secret once, at creation, and reports it as null for ever after, so
  it can be neither an environment variable (nobody has it yet) nor an
  observed value (observed state is cached in `.infra/` and printed in
  plans). `apiKeyFor` mints it at the moment the secret is created and writes
  the secret half straight in — the one operation here that is already
  write-only. The halves that are not secret, the access key and the
  application id, come back in `SecretsObserved` where `expr!` can reach
  them.

  **The database URL is composed at apply time, not by hand.** Its value
  needs the minted key *and* the endpoint Scaleway assigns when the database
  is created. `composed` holds the function instead; `infra` orders the key
  and the database before it and evaluates it once, at apply time, without
  the value ever entering this file, the plan output, or the `.infra/` cache.
  **One `push --apply` deploys the whole fleet, with no `scw` command and no
  credential pasted in between.**

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

/-- The **data plane** permission set: connecting to a Serverless SQL Database
    and running SQL in it.

    Not `ServerlessSQLDatabaseReadWrite`, which is the management plane —
    creating and configuring databases. They are different grants, and an
    identity holding only the second can create this database and then fail to
    connect to it. An organization-wide `AllProductsFullAccess` does not cover
    the data plane either, which is why an org-admin key is refused here with
    `password authentication failed`. -/
def dataPlane : String := "ServerlessSQLDatabaseDataReadWrite"

fleet typednotes in paris where
  provider scaleway where
    resource secrets "secrets-master-key" as masterKey
      { valueFrom := fromEnv "SECRETS_MASTER_KEY" }

    -- The identity the database authenticates. On Scaleway an `iam` resource
    -- is an IAM *application*, and `policies` is a list of permission-set
    -- names granted over the credentials' project.
    resource iam "secrets-db-app"
      { policies := [dataPlane] }

    -- Serverless, not classic: capacity bounds and no `instanceClass`, which
    -- is what routes this to the Serverless SQL backend. See the header for
    -- why the two `unused-` fields are spelled that way.
    resource postgres "secrets-db" as secretsDb
      { masterUsername       := "unused-serverless-sql-is-iam-only"
      , masterPasswordSecret := "unused-serverless-sql-is-iam-only"
      , minCapacity          := 1
      , maxCapacity          := 4 }

    -- Minted at apply, for the application above. The value is the key's
    -- secret half and is never read back.
    resource secrets "secrets-db-key" as dbKey
      { valueFrom := apiKeyFor "secrets-db-app" }

    -- **The user name is the application id, not the access key.** An access
    -- key (`SCW…`) looks far more like a username than a UUID does, and it is
    -- the wrong answer: it fails with `password authentication failed for
    -- user "SCW…"`, which points squarely at the password instead. This fleet
    -- lost a debugging session to exactly that. `principalOf` is the id;
    -- `accessKeyOf` is the access key and is not wanted here.
    --
    -- **The path is the database's own name** — `resource postgres
    -- "secrets-db"` creates a database called `secrets-db` and nothing else.
    -- Getting it wrong fails with `database "…" does not exist`, after apply
    -- has already reported success.
    --
    -- **`?sslmode=require` is mandatory** and `endpointOf` does not supply
    -- it: the backend strips the query string off the endpoint Scaleway
    -- reports, so `.endpoint` means `host:port` here as it does everywhere.
    --
    -- Both halves go through `urlEncode`. Scaleway's keys are UUID-shaped
    -- today, so nothing needs escaping — but a single `/` in a credential
    -- ends the URL's authority early and surfaces as `invalid port number`,
    -- naming the wrong field entirely, which this fleet also lost a session
    -- to. Encoding is free and removes the class.
    resource secrets "secrets-db-url" as dbUrl
      { valueFrom := composed
          expr!"postgres://\
{(principalOf dbKey).map Network.HTTP.Types.urlEncode}:\
{(secretValueOf dbKey).map Network.HTTP.Types.urlEncode}\
@{endpointOf secretsDb}/secrets-db?sslmode=require" }

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

/-- The ownership boundary, which the `fleet` command has no syntax for: it is
    an argument to `Infra.Cli.run`, in `Main.lean`.

    `namePrefix` is here because of the database. A Serverless SQL Database
    carries no tags and no description — there is nothing on one but the name
    it was created with — so the name is the only evidence of ownership
    available, and without a prefix to check it against this fleet could
    create the database and then never be allowed to adopt or destroy it.
    Everything else here is tagged normally and does not need it; only
    `postgres` falls to the name rung.

    `secrets-` is what the database is already called, so this claims it
    without a rename — and `infra` never renames anything, it only checks.
    The account also holds an unrelated Serverless SQL database called
    `typednotes`, created long before this fleet; it does not match, so it
    stays foreign and is left alone, which is the intended answer.

    `fleetName` makes the marker's *value* meaningful rather than just its
    presence, so a second fleet in this account could not claim these
    resources by name. It is opt-in on both sides and is not an identity —
    the realm check in `Main.lean`'s `accounts` is still the hard container. -/
def typednotesBoundary : Boundary :=
  { fleetName := some "typednotes", namePrefix := some "secrets-" }

-- No plaintext secret is written into this file. Decidable, so it is checked
-- at compile time rather than trusted — see `infra`'s `docs/diff-semantics.md`.
#guard typednotes.plan.secretsAreSound

-- Scaleway only: AWS credentials are neither needed nor read.
#guard typednotes.keys.providers = [.scaleway]

-- Paris means `fr-par` here. Independent of the image's registry host — the
-- container's own placement is the only thing this guard is about.
#guard (typednotes.regions.region .scaleway).map Region.code = some "fr-par"
#guard typednotes.regions.covers typednotes.keys

-- The name rung only decides `postgres`, but it decides it silently: a
-- database named outside the prefix would apply perfectly cleanly and then be
-- unmanageable for ever. Checked here rather than discovered later.
#guard (Finite.elems (α := typednotes.keys.Key .scaleway .postgres)).all fun key =>
  (typednotes.keys.name .scaleway .postgres key).startsWith "secrets-"

-- One identity, one minted key. If a second `apiKeyFor` ever appears without a
-- second `iam` resource to mint against, this is what says so.
#guard typednotes.keys.count .scaleway .iam = 1
