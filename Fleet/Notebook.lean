import Infra

namespace Typednotes.Notebook

/-- Stateful workers cannot request scale-to-zero or multiple independent disks. -/
structure WorkerCapacity where
  private mk ::
  minScale : Nat
  maxScale : Nat
  keptWarm : minScale = 1
  singleInstance : maxScale = 1

def workerCapacity : WorkerCapacity := ⟨1, 1, rfl, rfl⟩

/-- Only these vault namespaces can be granted to notebook services. -/
inductive VaultScope where
  | thirdparty | connectorPolicy | connectorAuthority
  | compute | graphData | graphMetadata | postgresPolicy | vaultPolicy
  deriving BEq, DecidableEq

inductive VaultOperation where
  | create | read | update | delete | list
  deriving BEq, DecidableEq

private def pathPrefix : VaultScope → String
  | .thirdparty => "secret/data/thirdparty/"
  | .connectorPolicy => "secret/data/connector-policy/"
  | .connectorAuthority => "secret/data/connector-authority/"
  | .compute => "secret/data/compute/"
  | .graphData => "secret/data/graph/"
  | .graphMetadata => "secret/metadata/graph/"
  | .postgresPolicy => "secret/data/thirdparty/postgres/"
  | .vaultPolicy => "secret/data/thirdparty/vault/"

private def operation : VaultOperation → String
  | .create => "create"
  | .read => "read"
  | .update => "update"
  | .delete => "delete"
  | .list => "list"

/-- The app stores credentials and authority but never reads secret values. -/
def appOperations : VaultScope → List VaultOperation
  | .thirdparty | .compute | .graphData => [.create, .delete]
  | .connectorPolicy | .connectorAuthority => [.create, .update, .delete]
  | _ => []

/-- Lun reads bounded runtime credentials/policies, never provider credentials. -/
def lunOperations : VaultScope → List VaultOperation
  | .connectorPolicy | .connectorAuthority | .compute | .postgresPolicy | .vaultPolicy => [.read]
  | .graphData => [.read, .create, .update]
  | .graphMetadata => [.read, .list]
  | .thirdparty => []

theorem app_never_reads (scope : VaultScope) :
    (appOperations scope).contains .read = false ∧ (appOperations scope).contains .list = false := by
  cases scope <;> exact ⟨rfl, rfl⟩

theorem lun_has_no_provider_credential_grant : lunOperations .thirdparty = [] := rfl

theorem lun_cannot_delete (scope : VaultScope) : (lunOperations scope).contains .delete = false := by
  cases scope <;> rfl

/-- The rendering boundary is tested against the vault's real config parser. -/
def rules (permissions : VaultScope → List VaultOperation) : String :=
  let scopes := [VaultScope.thirdparty, .connectorPolicy, .connectorAuthority,
    .compute, .graphData, .graphMetadata, .postgresPolicy, .vaultPolicy]
  String.intercalate "," (scopes.filterMap fun scope =>
    let ops := permissions scope
    if ops.isEmpty then none else
      some (s!"\{prefix=\"{pathPrefix scope}\", capabilities=[" ++
        String.intercalate "," (ops.map fun op => s!"\"{operation op}\"") ++ "]}"))

end Typednotes.Notebook
