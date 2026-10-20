import Fleet.Promotion

open Infra.Core Infra.Specs

/-- Evaluate the real fleet's service environments against provider-shaped
    HTTP endpoints. The Docker fixture uses short DNS aliases, still on port
    80, so it cannot hide an internal-listener/front-door port mismatch. -/
def fixtureWorld (docker : Bool) : Env SharedDeployment.keys.Key where
  observed p kind key := match p, kind with
    | .scaleway, .scalewayContainer =>
      let source := typednotes.keys.name .scaleway .scalewayContainer key
      let host := (SharedDeployment.serviceName source).getD source
      some { handle := ⟨SharedDeployment.keys.name .scaleway .scalewayContainer key⟩
             url := "unused", privateUrl := s!"http://{host}{if docker then "" else ".example.internal"}" }
    | _, _ => none

def main (args : List String) : IO Unit := do
  let identities ← match args[1]? with
    | none => pure vaultServiceIdentities
    | some path =>
      let json ← IO.ofExcept (Lean.Json.parse (← IO.FS.readFile (System.FilePath.mk path)))
      IO.ofExcept (json.getObjValAs? String "vaultIdentities")
  let bundle : BundleDeployment := { image := liteImage, runtimeVersion := 2, vaultIdentities := identities, histories := [] }
  let plan := SharedDeployment.plan .full liteImage bundle
  let mut services := []
  for key in Finite.elems (α := SharedDeployment.keys.Key .scaleway .scalewayContainer) do
    let some service := SharedDeployment.serviceName (typednotes.keys.name .scaleway .scalewayContainer key) | continue
    let .present spec := plan.assign .scaleway .scalewayContainer key | continue
    let some environment := spec.env.asKnown.bind (·.eval? (fixtureWorld (args.head? == some "docker")))
      | throw (IO.userError s!"Could not evaluate {service} environment")
    let bindings := (spec.secretEnv.asKnown.bind Expr.asLit).getD []
    let inputs := bindings.map fun (variableName, secret) =>
      let origin := match plan.assign .scaleway .secrets secret with
        | .present secretSpec => match secretSpec.valueFrom.asLit with
          | some (.fromEnv origin) => origin
          | _ => variableName
        | _ => variableName
      (variableName, Lean.toJson origin)
    services := services ++ [(service, Lean.Json.mkObj
      [("env", Lean.Json.mkObj (environment.map fun (k, v) => (k, Lean.toJson v)))
      , ("port", Lean.toJson ((spec.port.asKnown.bind Expr.asLit).getD 8080))
      , ("secretInputs", Lean.Json.mkObj inputs)])]
  IO.println (Lean.Json.mkObj services).compress
