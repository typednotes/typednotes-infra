import Fleet.Lite

open Infra.Core Infra.Specs

/-- Smoke tests consume the real declaration, not a second list of SQL files
    or vault policies. This export is offline and contains no secret values. -/
def main : IO Unit := do
  let migrations := appMigrations ++ ledgerMigrations ++ liaisonMigrations ++ secretsMigrations
  let urls := migrations.filterMap fun migration => match migration.source with
    | .url url => some url
    | _ => none
  IO.println (Lean.Json.compress (Lean.Json.mkObj
    [("vaultIdentities", Lean.toJson vaultServiceIdentities)
    , ("migrations", Lean.toJson urls)
    , ("schemaRefs", Lean.Json.mkObj
        [("app", Lean.toJson s!"v{appRelease}"), ("ledger", Lean.toJson s!"v{ledgerRelease}")
        , ("vault", Lean.toJson s!"v{secretsRelease}")])]))
