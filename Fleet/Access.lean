import Infra

namespace Typednotes.Access

/-- Existing dedicated internal network. Access/endpoints are resource
    properties in Fleet.lean, reconciled by infra >= 0.23.0. -/
def privateNetworkId := "9dd55512-09f6-4e7a-a864-19c82f348ab8"
def publicContainer := "typednotes-app"
def gatewayContainer := "operator-gateway"
def supportingContainers := ["secrets-server", "ledger", "liaison", "lode", "lun", "db-inspector"]

/-- Workstation addresses observed on 2026-10-11. These grant external access
    only to the DB admin proxy; application authentication remains required. -/
def operatorCidrs : List String :=
  ["REDACTED-OPERATOR-CIDR", "REDACTED-OPERATOR-CIDR",
   "REDACTED-OPERATOR-CIDR", "REDACTED-OPERATOR-CIDR"]

/-- Lean vault clients accept a host rather than a URL. Parse the provider's
    private URL, without reconstructing it from a name or opaque UUID. -/
def privateHost (url : String) : String :=
  ((Network.HTTP.Simple.parseUrl url).map (·.host)).getD ""

def gatewayImage := "docker.io/library/nginx:alpine"

#guard !operatorCidrs.isEmpty && operatorCidrs.all Infra.Specs.boundedCidr
#guard !supportingContainers.contains publicContainer
#guard !supportingContainers.contains gatewayContainer

end Typednotes.Access
