import Fleet

open Infra.Core Infra.Specs

/-- All six application services, assembled by `lite/docker-bake.hcl`. CI
    overrides this selector with the exact digest it just built and tested. -/
def liteImage : String := "ghcr.io/typednotes/typednotes-lite:latest"

namespace Lite

/- One public runtime and two Serverless SQL databases, matching full's storage
    layout. No classic compute database, private network or inspector.

    Names deliberately do NOT start with the full fleet's `typednotes-` or
    `secrets-` database prefixes: either fleet can be destroyed independently. -/
fleet typednotesLite in paris where
  provider scaleway where
    resource secrets "lite-typednotes-master-key" as masterKey
      { valueFrom := fromEnv "SECRETS_MASTER_KEY" }
    resource secrets "lite-typednotes-bootstrap-password" as bootstrapPassword
      { valueFrom := fromEnv "SECRETS_BOOTSTRAP_PASSWORD" }
    resource secrets "lite-typednotes-liaison-root-key" as liaisonRootKey
      { valueFrom := fromEnv "LIAISON_ROOT_KEY" }
    resource secrets "lite-typednotes-app-password" as appPassword
      { valueFrom := fromEnv "APP_SECRETS_PASSWORD" }
    resource secrets "lite-typednotes-liaison-password" as liaisonPassword
      { valueFrom := fromEnv "LIAISON_SECRETS_PASSWORD" }
    resource secrets "lite-typednotes-lun-password" as lunPassword
      { valueFrom := fromEnv "LUN_SECRETS_PASSWORD" }
    resource secrets "lite-typednotes-lode-token" as lodeToken
      { valueFrom := fromEnv "LODE_TOKEN" }
    resource secrets "lite-typednotes-lun-token" as lunToken
      { valueFrom := fromEnv "LUN_TOKEN" }
    resource secrets "lite-typednotes-lun-id-salt" as lunIdSalt
      { valueFrom := fromEnv "LUN_ID_SALT" }
    resource secrets "lite-typednotes-github-id" as githubId
      { valueFrom := fromEnv "GITHUB_CLIENT_ID" }
    resource secrets "lite-typednotes-github-secret" as githubSecret
      { valueFrom := fromEnv "GITHUB_CLIENT_SECRET" }
    resource secrets "lite-typednotes-google-id" as googleId
      { valueFrom := fromEnv "GOOGLE_CLIENT_ID" }
    resource secrets "lite-typednotes-google-secret" as googleSecret
      { valueFrom := fromEnv "GOOGLE_CLIENT_SECRET" }
    resource secrets "lite-typednotes-gitlab-id" as gitlabId
      { valueFrom := fromEnv "GITLAB_CLIENT_ID" }
    resource secrets "lite-typednotes-gitlab-secret" as gitlabSecret
      { valueFrom := fromEnv "GITLAB_CLIENT_SECRET" }
    resource secrets "lite-typednotes-dropbox-id" as dropboxId
      { valueFrom := fromEnv "DROPBOX_CLIENT_ID" }
    resource secrets "lite-typednotes-dropbox-secret" as dropboxSecret
      { valueFrom := fromEnv "DROPBOX_CLIENT_SECRET" }
    resource secrets "lite-typednotes-slack-id" as slackId
      { valueFrom := fromEnv "SLACK_CLIENT_ID" }
    resource secrets "lite-typednotes-slack-secret" as slackSecret
      { valueFrom := fromEnv "SLACK_CLIENT_SECRET" }
    resource secrets "lite-typednotes-slack-signing-secret" as slackSigningSecret
      { valueFrom := fromEnv "SLACK_SIGNING_SECRET" }
    resource secrets "lite-typednotes-whatsapp-secret" as whatsappSecret
      { valueFrom := fromEnv "WHATSAPP_APP_SECRET" }
    resource secrets "lite-typednotes-whatsapp-verify-token" as whatsappVerifyToken
      { valueFrom := fromEnv "WHATSAPP_VERIFY_TOKEN" }

    resource iam "lite-typednotes-migrator" { policies := [ddlAccess] }
    resource iam "lite-typednotes-observer" { policies := [readAccess] }
    resource iam "lite-typednotes-runtime" { policies := [dataAccess] }
    resource secrets "lite-typednotes-migrator-key" as migratorKey
      { valueFrom := apiKeyFor "lite-typednotes-migrator" }
    resource secrets "lite-typednotes-observer-key" as observerKey
      { valueFrom := apiKeyFor "lite-typednotes-observer" }
    resource secrets "lite-typednotes-runtime-key" as runtimeKey
      { valueFrom := apiKeyFor "lite-typednotes-runtime" }

    resource postgres "lite-typednotes-db" as db
      { masterUsername := "unused-serverless-sql-is-iam-only"
      , masterPasswordSecret := ""
      , minCapacity := 0
      , maxCapacity := 4 }
    resource secrets "lite-typednotes-migrator-url"
      { valueFrom := composed (pgUrl migratorKey db "lite-typednotes-db") }
    resource secrets "lite-typednotes-observer-url"
      { valueFrom := composed (pgUrl observerKey db "lite-typednotes-db") }
    resource secrets "lite-typednotes-runtime-url" as dbUrl
      { valueFrom := composed (pgUrl runtimeKey db "lite-typednotes-db") }
    resource postgres "lite-typednotes-secrets-db" as secretsDb
      { masterUsername := "unused-serverless-sql-is-iam-only"
      , masterPasswordSecret := ""
      , minCapacity := 0
      , maxCapacity := 4 }
    resource secrets "lite-typednotes-secrets-migrator-url"
      { valueFrom := composed (pgUrl migratorKey secretsDb "lite-typednotes-secrets-db") }
    resource secrets "lite-typednotes-secrets-observer-url"
      { valueFrom := composed (pgUrl observerKey secretsDb "lite-typednotes-secrets-db") }
    resource secrets "lite-typednotes-secrets-runtime-url" as secretsDbUrl
      { valueFrom := composed (pgUrl runtimeKey secretsDb "lite-typednotes-secrets-db") }

    resource postgresMigrations "lite-typednotes-core-history" as coreHistory
      { database := "lite-typednotes-db"
      , connectionSecret := "lite-typednotes-migrator-url"
      , observerSecret := "lite-typednotes-observer-url"
      , schema := "core", migrations := appMigrations }
    resource postgresMigrations "lite-typednotes-ledger-history" as ledgerHistory
      { database := "lite-typednotes-db"
      , connectionSecret := "lite-typednotes-migrator-url"
      , observerSecret := "lite-typednotes-observer-url"
      , schema := "ledger", migrations := ledgerMigrations }
    resource postgresMigrations "lite-typednotes-liaison-history" as liaisonHistory
      { database := "lite-typednotes-db"
      , connectionSecret := "lite-typednotes-migrator-url"
      , observerSecret := "lite-typednotes-observer-url"
      , schema := "liaison", migrations := liaisonMigrations }
    resource postgresMigrations "lite-typednotes-secrets-history" as secretsHistory
      { database := "lite-typednotes-secrets-db"
      , connectionSecret := "lite-typednotes-secrets-migrator-url"
      , observerSecret := "lite-typednotes-secrets-observer-url"
      , schema := "secrets", migrations := secretsMigrations }

    resource scalewayContainerNamespace "typednotes-lite" as ns
      { description := "Typednotes Lite: all application services" }
    resource scalewayContainer "typednotes-lite"
      { namespace' := ns
      , image := liteImage
      , port := 8080
      , access := some (ScalewayAccess.mk none true false)
      , privacy := some ScalewayContainerPrivacy.openAccess
      , httpsOnly := some true
      , minScale := Typednotes.Notebook.workerCapacity.minScale
      , maxScale := Typednotes.Notebook.workerCapacity.maxScale
      , memoryMb := 8192
      , cpuLimit := 4000
      , timeoutSec := 900
      , migrations := [coreHistory, ledgerHistory, liaisonHistory, secretsHistory]
      , env := [("PUBLIC_URL", appPublicUrl)
              , ("SECRETS_SERVER_SERVICE_IDENTITIES", vaultServiceIdentities)
              , ("LUN_WORKERS", "1")]
      , secretEnv := [("DATABASE_URL", dbUrl)
                    , ("SECRETS_SERVER_STORAGE_DATABASE_URL", secretsDbUrl)
                    , ("SECRETS_MASTER_KEY", masterKey)
                    , ("SECRETS_BOOTSTRAP_PASSWORD", bootstrapPassword)
                    , ("LIAISON_ROOT_KEY", liaisonRootKey)
                    , ("APP_SECRETS_PASSWORD", appPassword)
                    , ("LIAISON_SECRETS_PASSWORD", liaisonPassword)
                    , ("LUN_SECRETS_PASSWORD", lunPassword)
                    , ("LODE_TOKEN", lodeToken), ("LUN_TOKEN", lunToken)
                    , ("LUN_ID_SALT", lunIdSalt)
                    , ("GITHUB_CLIENT_ID", githubId), ("GITHUB_CLIENT_SECRET", githubSecret)
                    , ("GOOGLE_CLIENT_ID", googleId), ("GOOGLE_CLIENT_SECRET", googleSecret)
                    , ("GITLAB_CLIENT_ID", gitlabId), ("GITLAB_CLIENT_SECRET", gitlabSecret)
                    , ("DROPBOX_CLIENT_ID", dropboxId), ("DROPBOX_CLIENT_SECRET", dropboxSecret)
                    , ("SLACK_CLIENT_ID", slackId), ("SLACK_CLIENT_SECRET", slackSecret)
                    , ("SLACK_SIGNING_SECRET", slackSigningSecret)
                    , ("WHATSAPP_APP_SECRET", whatsappSecret)
                    , ("WHATSAPP_VERIFY_TOKEN", whatsappVerifyToken)] }

end Lite

open Lite

def typednotesLiteBoundary : Boundary :=
  { fleetName := some "typednotes-lite", namePrefix := some "lite-typednotes-" }

/-- Prepare only the durable resources for the one-time legacy vault split.
    Existing runtimes and histories stay declared but unmanaged; neither new
    migrations nor a container rollout can precede the data copy. -/
def typednotesLiteStorage : Fleet where
  name := typednotesLite.name
  keys := typednotesLite.keys
  plan.assign
    | .scaleway, .scalewayContainer, _ => .unmanaged
    | .scaleway, .postgresMigrations, _ => .unmanaged
    | p, k, key => typednotesLite.plan.assign p k key
  regions := typednotesLite.regions
  forgets := typednotesLite.forgets

/-- Only the sole container's image is overridden; migrations and ownership
    are identical for the CI plan, apply and convergence check. -/
private def litePlanWithImage (image : String) : Plan typednotesLite.keys where
  assign
    | .scaleway, .scalewayContainer, key =>
      match typednotesLite.plan.assign .scaleway .scalewayContainer key with
      | .present spec => .present { spec with image := .lit image }
      | other => other
    | p, k, key => typednotesLite.plan.assign p k key

def typednotesLiteWithImage (image : String) : Fleet where
  name := typednotesLite.name
  keys := typednotesLite.keys
  plan := litePlanWithImage image
  regions := typednotesLite.regions
  forgets := typednotesLite.forgets

/-- The registry boundary supplies the SQL that was bundled with this exact
    image, after verifying manifest, source commit and content digests. -/
structure LiteSqlMigration where
  id : String
  sql : String
  deriving Lean.FromJson

structure LiteSqlHistory where
  schema : String
  migrations : List LiteSqlMigration
  deriving Lean.FromJson

structure LiteDeployment where
  image : String
  runtimeVersion : Nat := 1
  vaultIdentities : String
  histories : List LiteSqlHistory
  deriving Lean.FromJson

private def deployedPlan (deployment : LiteDeployment) : Plan typednotesLite.keys where
  assign
    | .scaleway, .postgresMigrations, key =>
      match typednotesLite.plan.assign .scaleway .postgresMigrations key with
      | .present spec =>
        let schema := spec.schema.asLit.getD ""
        let migrations := (deployment.histories.find? (·.schema == schema)).toList.flatMap fun history =>
          history.migrations.map fun migration =>
            ({ id := migration.id, source := .text migration.sql } : MigrationDecl)
        .present { spec with migrations := .lit migrations }
      | other => other
    | .scaleway, .scalewayContainer, key =>
      match (litePlanWithImage deployment.image).assign .scaleway .scalewayContainer key with
      | .present spec => .present { spec with env := .known (.lit
          [("PUBLIC_URL", appPublicUrl), ("SECRETS_SERVER_SERVICE_IDENTITIES", deployment.vaultIdentities),
           ("LUN_WORKERS", "1")]) }
      | other => other
    | p, k, key => typednotesLite.plan.assign p k key

def typednotesLiteDeployed (deployment : LiteDeployment) : Except String Fleet := do
  unless deployment.runtimeVersion == 2 do
    throw "This deployment needs a runtimeVersion 2 bundle (split vault and standalone services); rebuild/publish the combined images"
  unless deployment.histories.map (·.schema) == ["core", "ledger", "liaison", "secrets"] do
    throw "Lite image must supply exactly the four migration histories"
  let plan := deployedPlan deployment
  unless plan.migrationsAreSound do throw "Lite image supplies an invalid migration history"
  return { name := typednotesLite.name, keys := typednotesLite.keys, plan := plan
         , regions := typednotesLite.regions, forgets := typednotesLite.forgets }

#guard typednotesLite.keys.count .scaleway .scalewayContainer = 1
#guard typednotesLite.keys.count .scaleway .postgres = 2
#guard typednotesLite.keys.count .scaleway .postgresMigrations = 4
#guard typednotesLite.keys.count .scaleway .iam = 3
#guard typednotesLite.plan.secretsAreSound
#guard typednotesLite.plan.migrationsAreSound
#guard typednotesLite.plan.accessIsSound
#guard (Finite.elems (α := typednotesLite.keys.Key .scaleway .scalewayContainer)).all fun key =>
  match typednotesLiteStorage.plan.assign .scaleway .scalewayContainer key with
  | .unmanaged => true
  | _ => false
#guard (Finite.elems (α := typednotesLite.keys.Key .scaleway .postgresMigrations)).all fun key =>
  match typednotesLiteStorage.plan.assign .scaleway .postgresMigrations key with
  | .unmanaged => true
  | _ => false
#guard typednotesLite.keys.providers = [.scaleway]
#guard (typednotesLite.regions.region .scaleway).map Region.code = some "fr-par"

-- Neither mode may adopt or destroy the other mode's database by prefix.
#guard !typednotesBoundary.prefixes.any ("lite-typednotes-db".startsWith ·)
#guard !typednotesBoundary.prefixes.any ("lite-typednotes-secrets-db".startsWith ·)
#guard !typednotesLiteBoundary.prefixes.any ("typednotes-db".startsWith ·)
#guard !typednotesLiteBoundary.prefixes.any ("secrets-db".startsWith ·)
#guard typednotesBoundary.fleetName != typednotesLiteBoundary.fleetName

private def liteContainer :
    Option (ScalewayContainerSpec typednotesLite.keys.Key Partial (Expr typednotesLite.keys.Key)) :=
  match typednotesLite.keys.keyOfName? .scaleway .scalewayContainer "typednotes-lite" with
  | none => none
  | some key => match typednotesLite.plan.assign .scaleway .scalewayContainer key with
    | .present spec => some spec
    | _ => none

#guard liteContainer.any fun spec =>
  spec.minScale.asKnown.bind Expr.asLit == some 1 &&
  spec.maxScale.asKnown.bind Expr.asLit == some 1 &&
  (spec.migrations.asKnown.bind Expr.asLit).any (fun histories =>
    (Finite.elems (α := typednotesLite.keys.Key .scaleway .postgresMigrations)).all histories.contains) &&
  (spec.secretEnv.asKnown.bind Expr.asLit).any fun env =>
    (env.map (·.1)).contains "DATABASE_URL" &&
    (env.map (·.1)).contains "SECRETS_SERVER_STORAGE_DATABASE_URL" &&
    !(env.map (·.1)).contains "COMPUTE_DB_URL"

#guard (Finite.elems (α := typednotesLite.keys.Key .scaleway .postgresMigrations)).all fun key =>
  match typednotesLite.plan.assign .scaleway .postgresMigrations key with
  | .present spec => spec.database.asLit == some
      (if spec.schema.asLit == some "secrets" then "lite-typednotes-secrets-db" else "lite-typednotes-db")
  | _ => false

-- The immutable CI image override must actually reach the container plan.
#guard (Finite.elems (α := typednotesLite.keys.Key .scaleway .scalewayContainer)).all fun key =>
  match (litePlanWithImage "ghcr.io/typednotes/typednotes-lite@sha256:fixture").assign
      .scaleway .scalewayContainer key with
  | .present spec => spec.image.asLit == some "ghcr.io/typednotes/typednotes-lite@sha256:fixture"
  | _ => false
