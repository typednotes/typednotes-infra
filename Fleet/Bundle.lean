import Fleet

open Infra.Core Infra.Specs

structure BundleSqlMigration where
  id : String
  sql : String
  deriving Lean.FromJson

structure BundleSqlHistory where
  schema : String
  migrations : List BundleSqlMigration
  deriving Lean.FromJson

/-- The verified executable/policy/SQL snapshot, independent of topology. -/
structure BundleDeployment where
  image : String
  runtimeVersion : Nat := 1
  vaultIdentities : String
  histories : List BundleSqlHistory
  deriving Lean.FromJson

namespace BundleDeployment

def validate (bundle : BundleDeployment) : Except String Unit := do
  unless bundle.runtimeVersion == 2 do
    throw "This deployment needs a runtimeVersion 2 bundle (split vault and standalone services); rebuild/publish the combined images"
  unless bundle.histories.map (·.schema) == ["core", "ledger", "liaison", "secrets"] do
    throw "The service bundle must supply exactly the four migration histories"

def migrationsFor (bundle : BundleDeployment) (schema : String) : List MigrationDecl :=
  (bundle.histories.find? (·.schema == schema)).toList.flatMap fun history =>
    history.migrations.map fun migration => { id := migration.id, source := .text migration.sql }

def applyHistories {κ : Keys} (plan : Plan κ) (bundle : Option BundleDeployment) : Plan κ where
  assign
    | p, .postgresMigrations, key =>
      match plan.assign p .postgresMigrations key, bundle with
      | .present spec, some snapshot =>
        .present { spec with migrations := .lit (snapshot.migrationsFor (spec.schema.asLit.getD "")) }
      | state, _ => state
    | p, k, key => plan.assign p k key

end BundleDeployment
