import Infra

namespace Typednotes.Access

/-- Existing dedicated internal network. Access/endpoints are resource
    properties in Fleet.lean, reconciled by infra >= 0.23.0. -/
def privateNetworkId := "9dd55512-09f6-4e7a-a864-19c82f348ab8"
def publicContainer := "typednotes-app"
def gatewayContainer := "operator-gateway"
def supportingContainers := ["secrets-server", "ledger", "liaison", "lode", "lun", "db-inspector"]

/-- Operator-private workstation addresses for the DB admin proxy. The
    committed value is RFC 5737 documentation space: bounded and valid, so it
    passes every offline check, yet no real traffic can originate from it.
    The operator's real addresses are deliberately **not** in this (public)
    repository. They are supplied at plan/apply time through the
    `OPERATOR_CIDRS` environment variable, which `Main.lean` validates and
    splices into the gateway with `withOperatorCidrs` in `Fleet.lean`. -/
def operatorCidrs : List String :=
  ["192.0.2.0/24"]

/-- Native private URLs use the platform's HTTP front door, not the vault
    executable's listening port. Preserve explicit ports and TLS as well. -/
def vaultEnvironment (url username : String) : List (String × String) :=
  match Network.HTTP.Simple.parseUrl url with
  | none => []
  | some endpoint =>
    [("SECRETS_HOST", endpoint.host), ("SECRETS_PORT", toString endpoint.port.toNat),
     ("SECRETS_INSECURE", if endpoint.isSecure then "0" else "1"), ("SECRETS_USERNAME", username)]

#guard (vaultEnvironment "http://vault.example.internal" "lun").contains ("SECRETS_PORT", "80")
#guard (vaultEnvironment "https://vault.example:9443" "liaison").contains ("SECRETS_PORT", "9443")
#guard (vaultEnvironment "https://vault.example" "liaison").contains ("SECRETS_INSECURE", "0")

def gatewayImage := "docker.io/library/nginx:alpine"

#guard !operatorCidrs.isEmpty && operatorCidrs.all Infra.Specs.boundedCidr
#guard !supportingContainers.contains publicContainer
#guard !supportingContainers.contains gatewayContainer

end Typednotes.Access
