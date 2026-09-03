import Fleet

open Infra.Core

/-- Checks the declared fleet against the placeholder backends, offline: every
    resource is a create, since nothing has been observed, and they must be
    ordered so the composed database URL comes after both the password it
    reads and the database whose endpoint it needs. Needs no credentials and
    touches no network. -/
def checkFleet : IO Unit := do
  let dry ← push Infra.Providers.all typednotes.plan (worldOf []) {}
  let creates := dry.filter (·.startsWith "would CREATE")
  unless creates.length == 5 do
    throw (IO.userError s!"expected 5 creates in one apply, got {creates.length}: {dry}")

  let idx (needle : String) : Option Nat :=
    dry.findIdx? fun l => (l.splitOn needle).length > 1
  match idx "secrets/secrets-db-password", idx "postgres/secrets-db",
        idx "secrets/secrets-db-url", idx "scaleway-container/secrets-server" with
  | some password, some db, some url, some server =>
    unless password < url && db < url do
      throw (IO.userError s!"the composed database URL must come last: {dry}")
    unless url < server do
      throw (IO.userError s!"the container must come after the secrets it binds: {dry}")
  | _, _, _, _ => throw (IO.userError s!"expected all five slots in the plan: {dry}")

  IO.println s!"fleet: ok ({creates.length} resources, one apply, correctly ordered)"

/-- The dispatch lives in `infra`; this repo declares. -/
def main (args : List String) : IO UInt32 :=
  Infra.Cli.run "typednotes-infra" typednotes.plan checkFleet (args := args)
