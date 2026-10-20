import Fleet.Shared

open Infra.Core

namespace Lite

def typednotesLite : Fleet := SharedDeployment.fleetFor .lite

end Lite

open Lite

def typednotesLiteWithImage (image : String) : Fleet := SharedDeployment.fleetFor .lite image

def typednotesLiteDeployed (bundle : BundleDeployment) : Except String Fleet := SharedDeployment.deployed .lite bundle

/-- Only durable resources participate during a legacy copy. Keys remain
    known to discovery, so unmanaged runtimes/histories cannot become orphans. -/
def typednotesLiteStorage : Fleet :=
  { typednotesLite with plan.assign
      | .scaleway, .scalewayContainer, _ => .unmanaged
      | .scaleway, .postgresMigrations, _ => .unmanaged
      | p, k, key => typednotesLite.plan.assign p k key }

#guard !typednotesBoundary.prefixes.any ("lite-typednotes-db".startsWith ·)
#guard !typednotesBoundary.prefixes.any ("lite-typednotes-secrets-db".startsWith ·)
#guard !typednotesLiteBoundary.prefixes.any ("typednotes-db".startsWith ·)
#guard !typednotesLiteBoundary.prefixes.any ("secrets-db".startsWith ·)
#guard typednotesBoundary.fleetName != typednotesLiteBoundary.fleetName
