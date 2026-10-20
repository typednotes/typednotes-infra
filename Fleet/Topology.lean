import Fleet.Promotion

open Infra.Core

namespace DeploymentTopology

def conflictsWithLite (kind : Kind) (name : String) (environment : List (String × String) := []) : Bool :=
  SharedDeployment.isFullOnlyName kind name ||
    (kind == .scalewayContainer && name == SharedDeployment.publicContainer &&
      environment.any (fun pair => pair.1 == "TYPEDNOTES_SERVICE" && !pair.2.isEmpty))

/-- Inspect ownership and actual resources, not a local flag. This also catches
    partial promotion and retained compute storage after runtime teardown. -/
def requireLite (backends : Backends) : IO Unit := do
  for kind in [Kind.secrets, .postgres, .scalewayContainer] do
    let backend := backends.backendFor .scaleway kind SharedDeployment.publicContainer
    for observed in ← backend.list kind do
      let handle := observedHandle kind observed
      let name := handle.raw
      unless conflictsWithLite kind name || (kind == .scalewayContainer && name == SharedDeployment.publicContainer) do continue
      let evidence ← backend.ownershipInfo kind handle
      if let .unreadable := evidence then
        throw (IO.userError s!"{name}: cannot verify ownership/topology; refusing Lite reconciliation or teardown")
      unless (ownershipOf typednotesLiteBoundary .scaleway kind name evidence).isOurs do continue
      let mut conflict := conflictsWithLite kind name
      if kind == .scalewayContainer && name == SharedDeployment.publicContainer then
        let reported ← backend.read .scalewayContainer ⟨name⟩
        let some environment := reported.env.asKnown
          | throw (IO.userError "Cannot verify the deployed runtime topology")
        conflict := conflict || conflictsWithLite kind name environment
      if conflict then
        throw (IO.userError s!"{name}: this fleet has been promoted or has full-only resources; use TYPEDNOTES_DEPLOYMENT=full-from-lite. Downgrade and Lite teardown are refused, including with --force.")

#guard conflictsWithLite .postgres "lite-typednotes-compute-db"
#guard conflictsWithLite .secrets "lite-typednotes-compute-password"
#guard conflictsWithLite .scalewayContainer "typednotes-lite" [("TYPEDNOTES_SERVICE", "app")]
#guard !conflictsWithLite .scalewayContainer "typednotes-lite" [("PUBLIC_URL", appPublicUrl)]
#guard !conflictsWithLite .postgres "typednotes-compute-db"

end DeploymentTopology
