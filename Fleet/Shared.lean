import Fleet.Bundle

open Infra.Core Infra.Specs

def liteImage : String := "ghcr.io/typednotes/typednotes-lite:latest"

namespace SharedDeployment

inductive Topology | lite | full deriving BEq

/-- Existing physical names are an explicit compatibility boundary. Full's
    resource specs are the single storage declaration; both new topologies
    construct their keys and connection recipes using this layout. -/
def layout : List (Kind × List (String × String)) :=
  [(.postgres, [("typednotes-db", "lite-typednotes-db"), ("secrets-db", "lite-typednotes-secrets-db"),
      ("typednotes-compute-db", "lite-typednotes-compute-db")]),
   (.iam, [("typednotes-db-migrator", "lite-typednotes-migrator"), ("typednotes-db-observer", "lite-typednotes-observer"),
      ("typednotes-db-runtime", "lite-typednotes-runtime")]),
   (.postgresMigrations, [("typednotes-core-history", "lite-typednotes-core-history"),
      ("typednotes-ledger-history", "lite-typednotes-ledger-history"), ("typednotes-liaison-history", "lite-typednotes-liaison-history"),
      ("secrets-history", "lite-typednotes-secrets-history")]),
   (.scalewayContainerNamespace, [("typednotes", "typednotes-lite")]),
   (.scalewayContainer, [("typednotes-app", "typednotes-lite"), ("secrets-server", "lite-typednotes-secrets-server"),
      ("ledger", "lite-typednotes-ledger"), ("liaison", "lite-typednotes-liaison"), ("lun", "lite-typednotes-lun"),
      ("lode", "lite-typednotes-lode"), ("db-inspector", "lite-typednotes-db-inspector"),
      ("operator-gateway", "lite-typednotes-operator-gateway")]),
   (.secrets, [("secrets-master-key", "lite-typednotes-master-key"),
      ("secrets-bootstrap-password", "lite-typednotes-bootstrap-password"), ("liaison-root-key", "lite-typednotes-liaison-root-key"),
      ("app-secrets-password", "lite-typednotes-app-password"), ("liaison-secrets-password", "lite-typednotes-liaison-password"),
      ("lun-secrets-password", "lite-typednotes-lun-password"), ("lode-token", "lite-typednotes-lode-token"),
      ("lun-token", "lite-typednotes-lun-token"), ("lun-id-salt", "lite-typednotes-lun-id-salt"),
      ("typednotes-compute-password", "lite-typednotes-compute-password"),
      ("github-client-id", "lite-typednotes-github-id"), ("github-client-secret", "lite-typednotes-github-secret"),
      ("google-client-id", "lite-typednotes-google-id"), ("google-client-secret", "lite-typednotes-google-secret"),
      ("gitlab-client-id", "lite-typednotes-gitlab-id"), ("gitlab-client-secret", "lite-typednotes-gitlab-secret"),
      ("dropbox-client-id", "lite-typednotes-dropbox-id"), ("dropbox-client-secret", "lite-typednotes-dropbox-secret"),
      ("slack-client-id", "lite-typednotes-slack-id"), ("slack-client-secret", "lite-typednotes-slack-secret"),
      ("slack-signing-secret", "lite-typednotes-slack-signing-secret"), ("whatsapp-app-secret", "lite-typednotes-whatsapp-secret"),
      ("whatsapp-verify-token", "lite-typednotes-whatsapp-verify-token"),
      ("db-inspector-username", "lite-typednotes-db-inspector-username"), ("db-inspector-password", "lite-typednotes-db-inspector-password"),
      ("typednotes-db-migrator-key", "lite-typednotes-migrator-key"), ("typednotes-db-observer-key", "lite-typednotes-observer-key"),
      ("typednotes-db-runtime-key", "lite-typednotes-runtime-key"),
      ("typednotes-db-migrator-url", "lite-typednotes-migrator-url"), ("typednotes-db-observer-url", "lite-typednotes-observer-url"),
      ("typednotes-db-runtime-url", "lite-typednotes-runtime-url"),
      ("secrets-db-migrator-url", "lite-typednotes-secrets-migrator-url"), ("secrets-db-observer-url", "lite-typednotes-secrets-observer-url"),
      ("secrets-db-runtime-url", "lite-typednotes-secrets-runtime-url"),
      ("typednotes-compute-url", "lite-typednotes-compute-url"), ("typednotes-db-pgweb-url", "lite-typednotes-pgweb-url")])]

def nameFor (kind : Kind) (source : String) : String :=
  ((((layout.find? (·.1 == kind)).map (·.2)).getD []).find? (·.1 == source)).map (·.2) |>.getD source

def keys : Keys := { typednotes.keys with name := fun p k key => nameFor k (typednotes.keys.name p k key) }

def publicContainer : String := nameFor .scalewayContainer "typednotes-app"

def key (kind : Kind) (name : String)
    (h : (typednotes.keys.keyOfName? .scaleway kind name).isSome := by decide) : keys.Key .scaleway kind :=
  (typednotes.keys.keyOfName? .scaleway kind name).get h

def serviceName (name : String) : Option String :=
  match name with
  | "typednotes-app" => some "app"
  | "secrets-server" => some "vault"
  | "ledger" | "liaison" | "lode" | "lun" => some name
  | _ => none

private def fullOnly (kind : Kind) (name : String) : Bool :=
  match kind with
  | .postgres => name == "typednotes-compute-db"
  | .secrets => ["typednotes-compute-password", "typednotes-compute-url", "typednotes-db-pgweb-url",
      "db-inspector-username", "db-inspector-password"].contains name
  | .scalewayContainer => name != "typednotes-app"
  | _ => false

private def renamed (kind : Kind) (value : Expr keys.Key String) : Expr keys.Key String :=
  match value.asLit with
  | some "" => .lit ""
  | some source => .lit (nameFor kind source)
  | none => value.map (nameFor kind)

/-- Recompose URLs from typed database/identity references and the layout.
    No rendered URL, password or prefix is searched/replaced. -/
private def connectionRecipe (name : String) : Option (Expr keys.Key String) :=
  let app := key .postgres "typednotes-db"
  let vault := key .postgres "secrets-db"
  let migrator := key .secrets "typednotes-db-migrator-key"
  let observer := key .secrets "typednotes-db-observer-key"
  let runtime := key .secrets "typednotes-db-runtime-key"
  match name with
  | "typednotes-db-migrator-url" => some (pgUrl migrator app (nameFor .postgres "typednotes-db"))
  | "typednotes-db-observer-url" => some (pgUrl observer app (nameFor .postgres "typednotes-db"))
  | "typednotes-db-runtime-url" => some (pgUrl runtime app (nameFor .postgres "typednotes-db"))
  | "secrets-db-migrator-url" => some (pgUrl migrator vault (nameFor .postgres "secrets-db"))
  | "secrets-db-observer-url" => some (pgUrl observer vault (nameFor .postgres "secrets-db"))
  | "secrets-db-runtime-url" => some (pgUrl runtime vault (nameFor .postgres "secrets-db"))
  | "typednotes-db-pgweb-url" => some (pgUrlWithoutSni observer app (nameFor .postgres "typednotes-db"))
  | "typednotes-compute-url" => some (computeUrl (key .postgres "typednotes-compute-db") (key .secrets "typednotes-compute-password"))
  | _ => none

private def combinedSecrets : List (String × keys.Key .scaleway .secrets) :=
  [("DATABASE_URL", key .secrets "typednotes-db-runtime-url"),
   ("SECRETS_SERVER_STORAGE_DATABASE_URL", key .secrets "secrets-db-runtime-url")] ++
  (Finite.elems (α := keys.Key .scaleway .secrets)).filterMap fun key =>
    if fullOnly .secrets (typednotes.keys.name .scaleway .secrets key) then none else
    match typednotes.plan.assign .scaleway .secrets key with
    | .present spec => match spec.valueFrom.asLit with
      | some (.fromEnv variableName) => some ((variableName, key) : String × keys.Key .scaleway .secrets)
      | _ => none
    | _ => none

private def combined (image identities : String) : ScalewayContainerSpec keys.Key Partial (Expr keys.Key) :=
  { name := .lit publicContainer, namespace' := .lit (key .scalewayContainerNamespace "typednotes"), image := .lit image
    port := .known (.lit 8080), access := .known (.lit (some (ScalewayAccess.mk none true false)))
    privacy := .known (.lit (some .openAccess)), httpsOnly := .known (.lit (some true))
    minScale := .known (.lit 1), maxScale := .known (.lit 1), memoryMb := .known (.lit 8192)
    cpuLimit := .known (.lit 4000), timeoutSec := .known (.lit 900)
    migrations := .known (.lit (Finite.elems (α := keys.Key .scaleway .postgresMigrations)))
    env := .known (.lit [("PUBLIC_URL", appPublicUrl), ("SECRETS_SERVER_SERVICE_IDENTITIES", identities), ("LUN_WORKERS", "1")])
    secretEnv := .known (.lit combinedSecrets)
    -- Restore the image entrypoint after a legacy-copy maintenance revision.
    command := .known (.lit (some [])), args := .known (.lit (some [])), proxy := .unknown }

private def basePlan (topology : Topology) (image : String) (bundle : Option BundleDeployment) : Plan keys where
  assign p kind r :=
    let source := typednotes.keys.name p kind r
    if topology == .lite && fullOnly kind source then .unmanaged else
    match p, kind, r with
    | .scaleway, .iam, r =>
      match typednotes.plan.assign .scaleway .iam r with
      | .present spec => .present { spec with name := .lit (keys.name .scaleway .iam r) }
      | state => state
    | .scaleway, .secrets, r =>
      match typednotes.plan.assign .scaleway .secrets r with
      | .present spec =>
        let recipe := match connectionRecipe source with
          | some url => composed url
          | none => match spec.valueFrom.asLit with
            | some (.apiKeyFor identity) => apiKeyFor (nameFor .iam identity)
            | _ => spec.valueFrom
        .present { spec with name := .lit (keys.name .scaleway .secrets r), valueFrom := recipe }
      | state => state
    | .scaleway, .postgres, r =>
      match typednotes.plan.assign .scaleway .postgres r with
      | .present spec => .present { spec with
          name := .lit (keys.name .scaleway .postgres r)
          masterPasswordSecret := renamed .secrets spec.masterPasswordSecret }
      | state => state
    | .scaleway, .postgresMigrations, r =>
      match typednotes.plan.assign .scaleway .postgresMigrations r with
      | .present spec => .present { spec with
          name := .lit (keys.name .scaleway .postgresMigrations r)
          database := renamed .postgres spec.database
          connectionSecret := renamed .secrets spec.connectionSecret
          observerSecret := renamed .secrets spec.observerSecret }
      | state => state
    | .scaleway, .scalewayContainerNamespace, r =>
      match typednotes.plan.assign .scaleway .scalewayContainerNamespace r with
      | .present spec => .present { spec with name := .lit (keys.name .scaleway .scalewayContainerNamespace r) }
      | state => state
    | .scaleway, .scalewayContainer, r =>
      let identities := bundle.map (·.vaultIdentities) |>.getD vaultServiceIdentities
      if topology == .lite then .present (combined image identities) else
      match typednotes.plan.assign .scaleway .scalewayContainer r with
      | .present spec =>
        let spec := { spec with name := .lit (keys.name .scaleway .scalewayContainer r) }
        match serviceName source with
        | none => .present spec
        | some service =>
          let environment := spec.env.getD (.lit []) |>.map fun env =>
            let env := if service == "vault" then
              env.filter (·.1 != "SECRETS_SERVER_SERVICE_IDENTITIES") ++ [("SECRETS_SERVER_SERVICE_IDENTITIES", identities)]
              else env
            env ++ [("TYPEDNOTES_SERVICE", service)] ++ (if service == "lun" then [("LUN_WORKERS", "1")] else [])
          .present { spec with
            image := .lit image
            env := .known environment
            command := .known (.lit (some ["/usr/bin/tini", "--", "python3", "/usr/local/lib/typednotes-lite/runtime.py"]))
            args := .known (.lit (some [])) }
      | state => state
    | p, kind, r => typednotes.plan.assign p kind r

def plan (topology : Topology) (image : String) (bundle : Option BundleDeployment := none) : Plan keys :=
  BundleDeployment.applyHistories (basePlan topology image bundle) bundle

def fleetFor (topology : Topology) (image : String := liteImage) (bundle : Option BundleDeployment := none) : Fleet where
  name := "typednotes-lite"
  keys := keys
  plan := plan topology image bundle
  regions := typednotes.regions
  forgets := []

def deployed (topology : Topology) (bundle : BundleDeployment) : Except String Fleet := do
  if let .error error := bundle.validate then throw error
  let result := fleetFor topology bundle.image bundle
  unless result.plan.migrationsAreSound do throw "Invalid bundle migration histories"
  return result

def presentCount (topology : Topology) (kind : Kind) : Nat :=
  ((Finite.elems (α := keys.Key .scaleway kind)).filter fun key =>
    match (plan topology liteImage).assign .scaleway kind key with | .present _ => true | _ => false).length

def isFullOnlyName (kind : Kind) (name : String) : Bool :=
  (Finite.elems (α := keys.Key .scaleway kind)).any fun key =>
    keys.name .scaleway kind key == name && fullOnly kind (typednotes.keys.name .scaleway kind key)

#guard typednotes.forgets.isEmpty -- New legacy releases must be deliberately mapped too.
#guard keys.providers == [.scaleway]
#guard (Finite.elems (α := keys.Key .scaleway .secrets)).all fun key =>
  match typednotes.plan.assign .scaleway .secrets key with
  | .present spec => spec.valueFrom.asLit.isSome ||
      (connectionRecipe (typednotes.keys.name .scaleway .secrets key)).isSome
  | _ => false
#guard [Topology.lite, .full].all fun topology =>
  (plan topology liteImage).secretsAreSound && (plan topology liteImage).migrationsAreSound &&
  (plan topology liteImage).accessIsSound
#guard (Finite.elems (α := Kind)).all fun kind =>
  let names := (Finite.elems (α := keys.Key .scaleway kind)).map (keys.name .scaleway kind)
  names.length == names.eraseDups.length &&
  (Finite.elems (α := keys.Key .scaleway kind)).all fun key =>
    (((layout.find? (·.1 == kind)).map (·.2)).getD []).any (·.1 == typednotes.keys.name .scaleway kind key)
#guard presentCount .lite .scalewayContainer == 1
#guard presentCount .lite .postgres == 2
#guard presentCount .lite .secrets == 31
#guard presentCount .lite .postgresMigrations == 4
#guard presentCount .lite .iam == 3
#guard presentCount .full .scalewayContainer == 8
#guard presentCount .full .postgres == 3

-- The same layout supplies resource names, migration routes and URL paths.
#guard (Finite.elems (α := keys.Key .scaleway .postgresMigrations)).all fun key =>
  match (plan .lite liteImage).assign .scaleway .postgresMigrations key with
  | .present spec =>
    let vault := spec.schema.asLit == some "secrets"
    spec.database.asLit == some (if vault then "lite-typednotes-secrets-db" else "lite-typednotes-db") &&
    spec.connectionSecret.asLit == some (if vault then "lite-typednotes-secrets-migrator-url" else "lite-typednotes-migrator-url")
  | _ => false

end SharedDeployment

def typednotesLiteBoundary : Boundary :=
  { fleetName := some "typednotes-lite", namePrefix := some "lite-typednotes-" }

#guard (Finite.elems (α := SharedDeployment.keys.Key .scaleway .postgres)).all fun key =>
  typednotesLiteBoundary.prefixes.any ((SharedDeployment.keys.name .scaleway .postgres key).startsWith ·)
