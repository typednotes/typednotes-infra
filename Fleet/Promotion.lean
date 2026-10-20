import Fleet.Lite

open Infra.Core

namespace Promotion

def fullFromLite (image : String := liteImage) (bundle : Option BundleDeployment := none) : Fleet :=
  SharedDeployment.fleetFor .full image bundle

def deployed (bundle : BundleDeployment) : Except String Fleet := SharedDeployment.deployed .full bundle

private def testBundle : BundleDeployment :=
  { image := "ghcr.io/typednotes/typednotes-lite@sha256:fixture", runtimeVersion := 2
    vaultIdentities := "image-specific-policies"
    histories := ["core", "ledger", "liaison", "secrets"].map fun schema =>
      { schema, migrations := [{ id := "0001", sql := "SELECT 1;" }] } }

#guard (deployed testBundle).isOk
#guard !(deployed { testBundle with runtimeVersion := 1 }).isOk
#guard !(typednotesLiteDeployed { testBundle with histories := [] }).isOk
#guard [SharedDeployment.Topology.lite, .full].all fun topology =>
  (Finite.elems (α := SharedDeployment.keys.Key .scaleway .postgresMigrations)).all fun key =>
    match (SharedDeployment.plan topology testBundle.image testBundle).assign .scaleway .postgresMigrations key with
    | .present spec => spec.migrations.asLit == some [{ id := "0001", source := .text "SELECT 1;" }]
    | _ => false

end Promotion
