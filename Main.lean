import Fleet.Topology

open Infra.Core
open Lite

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
    | .scaleway => some "8460bf58-4c44-431e-9df4-8eae3888b1ce"
    -- This fleet declares nothing on Google Cloud, so there is nothing to
    -- check there; `none` means "do not check it". The case is required
    -- because `expect` is total over `ProviderId`, which gained `.gcp`.
    | .gcp      => none

/-- The dispatch lives in `infra`; this repo declares.

    `full-from-lite` expands Lite in place; `full` retains its independent
    ownership boundary. `lite-storage` prepares a legacy vault split without
    migrations or runtime changes. `TYPEDNOTES_LITE_IMAGE` pins the bundle.

    `typednotes` is the whole declaration — its keys, its plan, its `in paris`
    placement and its `forget`s — as the single value the `fleet` command
    builds. As of infra 0.9.0 the front end takes that rather than three
    arguments prised out of it, so there is no longer a way for this file to
    hand over the plan and leave the placement or the releases behind.

    `boundary` is the one part of the declaration the `fleet` command has no
    syntax for, so it is passed here; `Fleet.lean` defines it next to the
    resources it is about. Without it the Serverless SQL database would be
    `foreign` — never adopted and never destroyed — because it is the one
    kind in this fleet with nowhere to write an ownership marker. -/
def main (args : List String) : IO UInt32 := do
  let mode := (← IO.getEnv "TYPEDNOTES_DEPLOYMENT").getD "lite"
  if ["lite", "lite-storage"].contains mode &&
      ((Infra.Cli.parseReconcile args).isSome || args.head? == some "dump") then
    try
      let (backends, credentials) ← Infra.Cli.liveFor SharedDeployment.keys typednotes.regions "typednotes-lite"
      Infra.Cli.checkAccounts SharedDeployment.keys accounts credentials false
      DeploymentTopology.requireLite backends
    catch error =>
      IO.eprintln s!"error: {error}"
      return 1
  match mode with
  | "lite" | "full-from-lite" =>
    let image := (← IO.getEnv "TYPEDNOTES_LITE_IMAGE").getD liteImage
    if image.isEmpty then
      IO.eprintln "TYPEDNOTES_LITE_IMAGE must be a non-empty registry image reference"
      return 2
    let mut selectedFleet := if mode == "lite" then typednotesLiteWithImage image else Promotion.fullFromLite image
    -- Freeze latest once, and use THAT image's SQL, not independently resolved
    -- service tags. Offline checks and teardown never need a registry read.
    if ["plan", "apply"].contains (args.headD "") && !args.contains "--destroy" then
      if mode == "full-from-lite" && !(image.startsWith "ghcr.io/typednotes/typednotes-lite@sha256:") then
        IO.eprintln "full-from-lite requires TYPEDNOTES_LITE_IMAGE pinned to a tested bundle digest (the deployed Lite digest for initial promotion)"
        return 2
      let metadata ← IO.Process.output { cmd := "python3", args := #["-m", "images.deployment", image] }
      if metadata.exitCode != 0 then
        IO.eprint metadata.stderr
        return 1
      match Lean.Json.parse metadata.stdout >>= Lean.fromJson? (α := BundleDeployment) with
      | .error error => IO.eprintln error; return 1
      | .ok deployment =>
        match (if mode == "lite" then typednotesLiteDeployed deployment else Promotion.deployed deployment) with
        | .error error => IO.eprintln error; return 1
        | .ok resolved => selectedFleet := resolved
    Infra.Cli.run "typednotes-infra" selectedFleet
      (headline := if mode == "lite" then
        "Typednotes Lite — one container and two Serverless SQL databases; compute DB sinks disabled"
        else "Typednotes full-from-lite — full topology over the existing Lite storage and public endpoint")
      (accounts := accounts) (boundary := typednotesLiteBoundary) (args := args)
  | "lite-storage" =>
    Infra.Cli.run "typednotes-infra" typednotesLiteStorage
      (headline := "Typednotes Lite storage preparation — no migrations or runtime rollout")
      (accounts := accounts) (boundary := typednotesLiteBoundary) (args := args)
  | "full" =>
    Infra.Cli.run "typednotes-infra" typednotes
      (accounts := accounts) (boundary := typednotesBoundary) (args := args)
  | _ =>
    IO.eprintln "TYPEDNOTES_DEPLOYMENT must be lite (default), full-from-lite, full or lite-storage"
    return 2
