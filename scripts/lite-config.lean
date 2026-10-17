import Fleet.Lite

open Infra.Core Infra.Specs

/-- Export proof-checked vault policies and baseline schema metadata for
    offline correspondence checks. Images carry their resolved-release SQL
    separately. This export contains no secret values. -/
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
