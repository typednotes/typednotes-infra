import Fleet.Lite

open Infra.Core Infra.Specs

namespace Promotion

/-- Full's topology over Lite's existing resource identities. The public app
    replaces the combined runtime in place, preserving its domain binding.
    Legacy full deployments retain their independent `typednotes` boundary. -/
def resourceName (kind : Kind) (name : String) : String :=
  match kind with
  | .scalewayContainerNamespace => "typednotes-lite"
  | .scalewayContainer =>
    if name == "typednotes-app" then "typednotes-lite" else "lite-typednotes-" ++ name
  | .postgres =>
    if name == "typednotes-db" then "lite-typednotes-db"
    else if name == "secrets-db" then "lite-typednotes-secrets-db"
    else "lite-" ++ name
  | .iam => "lite-typednotes-" ++ (name.drop "typednotes-db-".length).toString
  | .postgresMigrations =>
    if name == "secrets-history" then "lite-typednotes-secrets-history" else "lite-" ++ name
  | .secrets =>
    -- Match operator-supplied values by their input variable, so credentials
    -- are reused even where the two historical declarations used different names.
    let matching := (Finite.elems (α := typednotes.keys.Key .scaleway .secrets)).find?
      (fun key => typednotes.keys.name .scaleway .secrets key == name)
    let source := matching.bind fun key =>
      match typednotes.plan.assign .scaleway .secrets key with
      | .present spec => spec.valueFrom.asLit
      | _ => none
    let liteKey := (Finite.elems (α := Lite.typednotesLite.keys.Key .scaleway .secrets)).find? fun key =>
      match source, Lite.typednotesLite.plan.assign .scaleway .secrets key with
      | some (.fromEnv varName), .present spec => spec.valueFrom.asLit == some (.fromEnv varName)
      | _, _ => false
    match liteKey with
    | some key => Lite.typednotesLite.keys.name .scaleway .secrets key
    | none =>
      if name.startsWith "typednotes-db-" then
        "lite-typednotes-" ++ (name.drop "typednotes-db-".length).toString
      else if name.startsWith "secrets-db-" then
        "lite-typednotes-secrets-" ++ (name.drop "secrets-db-".length).toString
      else if name.startsWith "typednotes-" then "lite-" ++ name
      else "lite-typednotes-" ++ name
  | _ => name

/-- Same finite key types: all typed references remain intact. Only physical
    names change, consistently in Keys and in each resource's authored name. -/
def keys : Keys :=
  { typednotes.keys with name := fun p k key => resourceName k (typednotes.keys.name p k key) }

private def serviceName (name : String) : Option String :=
  match name with
  | "typednotes-app" => some "app"
  | "secrets-server" => some "vault"
  | "ledger" | "liaison" | "lode" | "lun" => some name
  | _ => none

private def renamed (kind : Kind) (value : Expr keys.Key String) : Expr keys.Key String :=
  match value.asLit with
  | some "" => .lit ""
  | some name => .lit (resourceName kind name)
  | none => value.map (resourceName kind)

private def secretSource (spec : SecretsSpec keys.Key Partial (Expr keys.Key)) : Expr keys.Key SecretSource :=
  match spec.valueFrom.asLit with
  | some (.apiKeyFor identity) => apiKeyFor (resourceName .iam identity)
  | some (.fromEnv _) => spec.valueFrom
  | _ => spec.valueFrom.map fun source => match source with
    | .composed value => .composed (value.replace "/typednotes-db?" "/lite-typednotes-db?"
        |>.replace "/secrets-db?" "/lite-typednotes-secrets-db?")
    | other => other

def plan (image : String) (deployment : Option LiteDeployment := none) : Plan keys where
  assign
    | .scaleway, .iam, key =>
      match typednotes.plan.assign .scaleway .iam key with
      | .present spec => .present { spec with name := .lit (keys.name .scaleway .iam key) }
      | other => other
    | .scaleway, .secrets, key =>
      match typednotes.plan.assign .scaleway .secrets key with
      | .present spec => .present { spec with
          name := .lit (keys.name .scaleway .secrets key)
          valueFrom := secretSource spec }
      | other => other
    | .scaleway, .postgres, key =>
      match typednotes.plan.assign .scaleway .postgres key with
      | .present spec => .present { spec with
          name := .lit (keys.name .scaleway .postgres key)
          masterPasswordSecret := renamed .secrets spec.masterPasswordSecret }
      | other => other
    | .scaleway, .postgresMigrations, key =>
      match typednotes.plan.assign .scaleway .postgresMigrations key with
      | .present spec =>
        let migrations := match deployment with
          | none => spec.migrations
          | some bundle => .lit (((bundle.histories.find? (fun h => some h.schema == spec.schema.asLit)).toList.flatMap
              fun h => h.migrations.map fun m => ({ id := m.id, source := .text m.sql } : MigrationDecl)))
        .present { spec with
          name := .lit (keys.name .scaleway .postgresMigrations key)
          database := renamed .postgres spec.database
          connectionSecret := renamed .secrets spec.connectionSecret
          observerSecret := renamed .secrets spec.observerSecret
          migrations := migrations }
      | other => other
    | .scaleway, .scalewayContainerNamespace, key =>
      match typednotes.plan.assign .scaleway .scalewayContainerNamespace key with
      | .present spec => .present { spec with name := .lit (keys.name .scaleway .scalewayContainerNamespace key) }
      | other => other
    | .scaleway, .scalewayContainer, key =>
      match typednotes.plan.assign .scaleway .scalewayContainer key with
      | .present spec =>
        let name := typednotes.keys.name .scaleway .scalewayContainer key
        let spec := { spec with name := .lit (keys.name .scaleway .scalewayContainer key) }
        match serviceName name with
        | none => .present spec
        | some service =>
          let env := spec.env.getD (.lit []) |>.map fun env =>
            let env := if service == "vault" then
              env.filter (fun pair => pair.1 != "SECRETS_SERVER_SERVICE_IDENTITIES") ++
                [("SECRETS_SERVER_SERVICE_IDENTITIES", deployment.map (·.vaultIdentities) |>.getD vaultServiceIdentities)]
              else env
            env ++ [("TYPEDNOTES_SERVICE", service)]
          .present { spec with
            image := .lit image
            env := .known env
            -- All six containers run their own service from the SAME frozen
            -- bundle as Lite, never independently moving `latest` images.
            command := .known (.lit (some ["/usr/bin/tini", "--", "python3", "/usr/local/lib/typednotes-lite/runtime.py"]))
            args := .known (.lit (some [])) }
      | other => other
    | p, k, key => typednotes.plan.assign p k key

def fullFromLite (image : String := liteImage) (deployment : Option LiteDeployment := none) : Fleet where
  name := "typednotes-lite"
  keys := keys
  plan := plan image deployment
  regions := typednotes.regions
  forgets := []

def deployed (deployment : LiteDeployment) : Except String Fleet := do
  let _ ← typednotesLiteDeployed deployment
  let result := fullFromLite deployment.image deployment
  unless result.plan.migrationsAreSound do throw "Invalid full-from-lite migration histories"
  return result

#guard (fullFromLite).plan.secretsAreSound
#guard (fullFromLite).plan.migrationsAreSound
#guard (fullFromLite).plan.accessIsSound
#guard keys.count .scaleway .postgres = 3
-- New full resource kinds must be explicitly handled above rather than
-- falling through with legacy names or untransformed references.
#guard (Finite.elems (α := Kind)).all fun kind =>
  keys.count .scaleway kind == 0 ||
    [Kind.iam, .secrets, .postgres, .postgresMigrations,
      .scalewayContainerNamespace, .scalewayContainer].contains kind
#guard (Finite.elems (α := Kind)).all fun kind =>
  let names := (Finite.elems (α := keys.Key .scaleway kind)).map (keys.name .scaleway kind)
  names.length == names.eraseDups.length

-- Every Lite storage resource, IAM identity and secret has exactly one stable
-- counterpart. Promotion cannot silently mint a replacement master key or DB.
#guard [Kind.postgres, .iam, .secrets, .postgresMigrations, .scalewayContainerNamespace].all fun kind =>
  (Finite.elems (α := Lite.typednotesLite.keys.Key .scaleway kind)).all fun key =>
    let name := Lite.typednotesLite.keys.name .scaleway kind key
    ((Finite.elems (α := keys.Key .scaleway kind)).filter fun fullKey =>
      keys.name .scaleway kind fullKey == name).length == 1

#guard resourceName .scalewayContainer "typednotes-app" == "typednotes-lite"
#guard resourceName .scalewayContainerNamespace "typednotes" == "typednotes-lite"
#guard (Finite.elems (α := keys.Key .scaleway .postgres)).all fun key =>
  typednotesLiteBoundary.prefixes.any ((keys.name .scaleway .postgres key).startsWith ·)

-- Bookkeeping and connection secrets follow each existing database. Merely
-- renaming a postgres resource without these strings would lose its history.
#guard (Finite.elems (α := keys.Key .scaleway .postgresMigrations)).all fun key =>
  match (plan liteImage).assign .scaleway .postgresMigrations key with
  | .present spec =>
    let vault := spec.schema.asLit == some "secrets"
    spec.database.asLit == some (if vault then "lite-typednotes-secrets-db" else "lite-typednotes-db") &&
    spec.connectionSecret.asLit == some (if vault then "lite-typednotes-secrets-migrator-url" else "lite-typednotes-migrator-url") &&
    spec.observerSecret.asLit == some (if vault then "lite-typednotes-secrets-observer-url" else "lite-typednotes-observer-url")
  | _ => false

private def testBundle : LiteDeployment :=
  { image := "ghcr.io/typednotes/typednotes-lite@sha256:fixture", runtimeVersion := 2
    vaultIdentities := "image-specific-policies"
    histories := ["core", "ledger", "liaison", "secrets"].map fun schema =>
      { schema, migrations := [{ id := "0001", sql := "SELECT 1;" }] } }

#guard (deployed testBundle).isOk
#guard !(deployed { testBundle with runtimeVersion := 1 }).isOk
#guard (Finite.elems (α := keys.Key .scaleway .postgresMigrations)).all fun key =>
  match (plan testBundle.image testBundle).assign .scaleway .postgresMigrations key with
  | .present spec => spec.migrations.asLit == some [{ id := "0001", source := .text "SELECT 1;" }]
  | _ => false

#guard (Finite.elems (α := keys.Key .scaleway .scalewayContainer)).all fun key =>
  let name := typednotes.keys.name .scaleway .scalewayContainer key
  match serviceName name, (plan testBundle.image testBundle).assign .scaleway .scalewayContainer key with
  | some _, .present spec => spec.image.asLit == some testBundle.image
  | none, .present _ => true
  | _, _ => false

#guard (Finite.elems (α := keys.Key .scaleway .scalewayContainer)).all fun key =>
  if typednotes.keys.name .scaleway .scalewayContainer key != "secrets-server" then true else
  match (plan testBundle.image testBundle).assign .scaleway .scalewayContainer key with
  | .present spec =>
    ((spec.env.asKnown.bind fun expr => expr.eval? { observed := fun _ _ _ => none }).getD []).contains
      ("SECRETS_SERVER_SERVICE_IDENTITIES", testBundle.vaultIdentities)
  | _ => false

end Promotion
