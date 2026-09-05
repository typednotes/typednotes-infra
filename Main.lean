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
  -- Six: the namespace the container is placed into is now declared too.
  unless creates.length == 6 do
    throw (IO.userError s!"expected 6 creates in one apply, got {creates.length}: {dry}")

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

  -- The namespace must precede the container placed into it.
  match idx "scaleway-container-namespace/typednotes",
        idx "scaleway-container/secrets-server" with
  | some ns, some server =>
    unless ns < server do
      throw (IO.userError s!"the namespace must come before its container: {dry}")
  | _, _ => throw (IO.userError s!"expected the namespace and the container: {dry}")

  IO.println s!"fleet: ok ({creates.length} resources, one apply, correctly ordered)"

/-- The accounts this fleet is for.

    Checked before any live command touches anything: `plan`, `pull` and
    `push` all verify that the credentials in force actually belong here, and
    refuse otherwise. That is worth a call per run because the credential chain
    has three sources — an exported `AWS_PROFILE`, a stale keychain entry or a
    CI secret pointing somewhere else all look identical at the point of use,
    and the first visible sign would otherwise be a plan proposing to build
    this fleet in the wrong place.

    Neither value is a secret: an AWS account id appears in every ARN, and a
    Scaleway organization id is visible in the console URL. They are recorded
    here, in the repo that declares the fleet, rather than in `infra`, which
    has no business knowing whose accounts it is pointed at. -/
def accounts : Infra.Cli.Accounts where
  expect
    | .aws      => some "616568506952"
    | .scaleway => some "4d7c630f-df06-43fe-b9e5-df729c8be4e3"

/-- The dispatch lives in `infra`; this repo declares. -/
def main (args : List String) : IO UInt32 :=
  Infra.Cli.run "typednotes-infra" typednotes.plan checkFleet accounts
    (regions := typednotes.regions) (args := args)
