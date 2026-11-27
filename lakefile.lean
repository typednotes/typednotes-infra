import Lake
open System Lake DSL

package «typednotes-infra» where
  version := v!"0.10.5"

-- A tag rather than `main`. `Main.lean` hands the whole declaration to
-- `Infra.Cli.run` in one value, which does not compile against an `infra`
-- older than 0.9.0; and the reverse — tracking `main` — means the next
-- breaking change in the front end arrives here unannounced, in whatever
-- state it happens to be in. Moving forward is a deliberate edit: bump this,
-- run `lake update infra`, and read the library's CHANGELOG on the way.
require infra from git "https://github.com/typednotes/infra" @ "v0.23.0"

-- The root selects the Linen release for the whole fleet build.
-- The root requirement deliberately overrides that older transitive version.
require linen from git "https://github.com/typednotes/linen" @ "bcfec9a81d6e738ecb273f89e2102b4712d8e160"


@[default_target]
lean_lib Fleet

@[default_target]
lean_exe «typednotes-infra» where
  root := `Main

/-
  Bare `lake build` only compiles `@[default_target]`s — it does not run any IO, so it cannot
  itself print a plan. A custom Lake `target` that runs IO as part of the *build* was
  considered (making `lake build` alone show the plan) and deliberately not pursued: it would
  make an ordinary build perform network IO and need live credentials, which is a much bigger
  behavior change than "one more `lake exe` subcommand" for a benefit that is mostly typing four
  fewer characters. `lake exe typednotes-infra <cmd>` is unambiguous about when a cloud is
  touched; these `lake script`s exist only to save typing the executable's name.

  `apply` is the exception to "only to save typing": it adds a refusal. See its
  own comment below.
-/

/-- `lake script run check` — same as `lake exe typednotes-infra check`. -/
script check args do
  let out ← IO.Process.output { cmd := "lake", args := #["exe", "typednotes-infra", "check"] ++ args.toArray }
  IO.print out.stdout
  IO.eprint out.stderr
  return out.exitCode

/-- `lake script run plan` — needs live credentials; see `main`'s `withLive`. -/
script plan args do
  let out ← IO.Process.output { cmd := "lake", args := #["exe", "typednotes-infra", "plan"] ++ args.toArray }
  IO.print out.stdout
  IO.eprint out.stderr
  return out.exitCode

/-- `lake script run apply --yes` — the only command here that changes a
    cloud.

    Unlike `check` and `plan`, this does not merely save typing: it **refuses
    without `--yes`**. A one-word `apply` sitting next to a one-word `plan` is
    too easy to reach for by accident, and the two differ by whether real,
    billable resources are created or destroyed — so the intent has to be
    stated separately from the command name. CI supplies the flag from a
    manually dispatched workflow and never from a push; see
    `.github/workflows/apply.yml`.

    Every other argument is passed to `apply` — `--refresh-secrets`, which
    CI always passes, and `--force` — so the flags keep the meaning `infra`
    gives them, and a typo is `infra`'s usage error rather than silently
    dropped here.

    Output is streamed rather than captured, because an apply can take minutes
    and a CI log that stays empty until the end is unreadable — and if it
    fails partway, what already happened is the important part. -/
script apply args do
  unless args.contains "--yes" do
    IO.eprintln "refusing to apply without --yes."
    IO.eprintln ""
    IO.eprintln "  This creates, modifies or deletes real, billable Scaleway resources."
    IO.eprintln "  Review the plan first:  lake script run plan"
    IO.eprintln "  Then, deliberately:     lake script run apply --yes"
    return 1
  let child ← IO.Process.spawn
    { cmd := "lake", args := #["exe", "typednotes-infra", "apply"] ++ (args.filter (· != "--yes")).toArray }
  return (← child.wait)
