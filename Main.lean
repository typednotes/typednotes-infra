import Fleet.Lite

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

    `TYPEDNOTES_DEPLOYMENT` chooses Lite (default) or the existing full fleet.
    Each has its own ownership boundary, including non-overlapping database
    prefixes. `TYPEDNOTES_LITE_IMAGE` pins a built image across CI's three calls.

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
  match (← IO.getEnv "TYPEDNOTES_DEPLOYMENT").getD "lite" with
  | "lite" =>
    let image := (← IO.getEnv "TYPEDNOTES_LITE_IMAGE").getD liteImage
    if image.isEmpty then
      IO.eprintln "TYPEDNOTES_LITE_IMAGE must be a non-empty registry image reference"
      return 2
    let mut selectedFleet := typednotesLiteWithImage image
    -- Freeze latest once, and use THAT image's SQL, not independently resolved
    -- service tags. Offline checks and teardown never need a registry read.
    if ["plan", "apply"].contains (args.headD "") && !args.contains "--destroy" then
      let metadata ← IO.Process.output { cmd := "python3", args := #["-m", "images.deployment", image] }
      if metadata.exitCode != 0 then
        IO.eprint metadata.stderr
        return 1
      match Lean.Json.parse metadata.stdout >>= Lean.fromJson? (α := LiteDeployment) with
      | .error error => IO.eprintln error; return 1
      | .ok deployment =>
        match typednotesLiteDeployed deployment with
        | .error error => IO.eprintln error; return 1
        | .ok resolved => selectedFleet := resolved
    Infra.Cli.run "typednotes-infra" selectedFleet
      (headline := "Typednotes Lite — one container and one Serverless SQL database; compute DB sinks disabled")
      (accounts := accounts) (boundary := typednotesLiteBoundary) (args := args)
  | "full" =>
    Infra.Cli.run "typednotes-infra" typednotes
      (accounts := accounts) (boundary := typednotesBoundary) (args := args)
  | _ =>
    IO.eprintln "TYPEDNOTES_DEPLOYMENT must be lite (default) or full"
    return 2
