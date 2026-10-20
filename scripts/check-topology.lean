import Fleet.Topology

open Infra.Core Infra.Providers

private def fixture (kindFound : Kind) (name : String) (owned : Bool := true)
    (environment : Option (List (String × String)) := some []) (readable : Bool := true) : Backends :=
  { backend := fun _ =>
      { placeholderBackend "topology-test" with
        list := fun kind => pure (if kind == kindFound then [placeholderObserved kind name] else [])
        ownershipInfo := fun kind handle => pure (if !readable then .unreadable
          else if !owned then .tags [(markerKey, "other-fleet")] none
          else if kind == .postgres then .named handle.raw none
          else .tags [(markerKey, "typednotes-lite")] none)
        read := fun kind handle => match kind with
          | .scalewayContainer => pure { placeholderReported .scalewayContainer handle with
              env := match environment with | some env => .known env | none => .unknown }
          | kind => pure (placeholderReported kind handle) } }

private def expect (backends : Backends) (refused : Bool) : IO Unit := do
  let result ← (DeploymentTopology.requireLite backends).toBaseIO
  let rejected := match result with | .error _ => true | .ok _ => false
  unless rejected == refused do throw (IO.userError "Incorrect topology guard result")

def main : IO Unit := do
  expect (fixture .scalewayContainer "typednotes-lite") false
  expect (fixture .scalewayContainer "typednotes-lite" true (some [("TYPEDNOTES_SERVICE", "app")])) true
  expect (fixture .scalewayContainer "typednotes-lite" true none) true
  expect (fixture .postgres "lite-typednotes-compute-db") true
  expect (fixture .secrets "lite-typednotes-compute-password") true
  expect (fixture .scalewayContainer "lite-typednotes-lun") true
  expect (fixture .scalewayContainer "lite-typednotes-lun" false) false
  expect (fixture .scalewayContainer "typednotes-lite" (readable := false)) true
  expect (fixture .postgres "typednotes-compute-db") false
  IO.println "ok: topology guard refuses partial/full promotion and preserves foreign fleets"
