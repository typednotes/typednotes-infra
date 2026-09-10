import Fleet

open Infra.Core

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
    | .scaleway => some "4d7c630f-df06-43fe-b9e5-df729c8be4e3"
    -- This fleet declares nothing on Google Cloud, so there is nothing to
    -- check there; `none` means "do not check it". The case is required
    -- because `expect` is total over `ProviderId`, which gained `.gcp`.
    | .gcp      => none

/-- The dispatch lives in `infra`; this repo declares.

    `typednotes` is the whole declaration — its keys, its plan, its `in paris`
    placement and its `forget`s — as the single value the `fleet` command
    builds. As of infra 0.9.0 the front end takes that rather than three
    arguments prised out of it, so there is no longer a way for this file to
    hand over the plan and leave the placement or the releases behind. -/
def main (args : List String) : IO UInt32 :=
  Infra.Cli.run "typednotes-infra" typednotes
    (accounts := accounts) (args := args)
