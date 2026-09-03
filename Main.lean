import Fleet

open Infra.Core
open TypednotesInfra

/-- Where the observed-state cache lives. Gitignored — see `infra`'s `docs/persistence.md`. -/
def cacheRoot : System.FilePath := ".infra"

/-- Nothing observed anywhere yet — `worldOf []` gives this for any fleet, regardless of what
    `fleetKeys` declares, unlike a hand-rolled `sighting := fun _ _ key => nomatch key` (which
    only typechecks while every key type is `Nothing`, i.e. while the fleet is empty). -/
def emptyWorld : World fleetKeys := worldOf []

/-- Checks `push`'s dry run against the placeholder backends, without touching a cloud. Every
    declared resource is a create, since nothing has been observed. -/
def checkPush : IO Unit := do
  let dry ← push Infra.Providers.all fleetPlan emptyWorld {}
  let creates := dry.filter (·.startsWith "would CREATE")
  unless creates.length == 5 do
    throw (IO.userError s!"expected 5 creates, got {creates.length}: {dry}")
  IO.println "push: ok (dry run against the placeholder backends)"

/-- Self-checks, run when no subcommand is given. Everything here works offline; nothing touches
    a cloud, and none of it needs credentials. -/
def selfCheck : IO Unit := do
  IO.println "typednotes-infra: fleet loaded"
  checkPush

def usage : String := String.intercalate "\n"
  [ "usage: typednotes-infra [check | plan | pull | push [--apply]]"
  , ""
  , "  check           run the offline self-checks (default)"
  , "  pull            observe both clouds and cache what is there"
  , "  plan            show what would change, without changing anything"
  , "  push            same as plan — a dry run"
  , "  push --apply    actually reconcile"
  ]

/-- Live commands need credentials for both clouds; the failure names every place that was
    searched — see `infra`'s `docs/authentication.md`. -/
def withLive (act : Infra.Core.Backends → IO Unit) : IO Unit := do
  act (← Infra.Providers.liveFromEnvironment)

def main (args : List String) : IO UInt32 := do
  match args with
  | [] | ["check"] => selfCheck; return 0
  | ["pull"] =>
    withLive fun bs => do
      let world ← pull (κ := fleetKeys) cacheRoot bs
      let outstanding := plan fleetPlan world
      IO.println s!"pulled; {outstanding.length} action(s) outstanding"
    return 0
  | ["plan"] | ["push"] =>
    withLive fun bs => do
      let world ← pull (κ := fleetKeys) cacheRoot bs
      for line in ← push bs fleetPlan world {} do IO.println line
    return 0
  | ["push", "--apply"] =>
    withLive fun bs => do
      let world ← pull (κ := fleetKeys) cacheRoot bs
      for line in ← push bs fleetPlan world { apply := true } do IO.println line
    return 0
  | _ =>
    IO.eprintln usage
    return 2
