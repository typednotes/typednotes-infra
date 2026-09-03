import Lake
open System Lake DSL

/-
  Build configuration.

  `infra`'s own `lakefile.lean` is Lean rather than TOML because it needs platform-conditional
  link flags for Linen's FFI-backed features (`System.Keychain`, OpenSSL-backed TLS/SigV4) that
  Lake does not propagate from a dependency's `moreLinkArgs` to a *dependent's* executable — see
  the comment there. That gap is one level deeper here: `typednotes-infra`'s executable links
  against `Infra`, which links against `linen`, and Lake propagates neither package's
  `moreLinkArgs` to this one. The fix is the same one level up — duplicate the flag computation
  rather than depend on inheriting it. Kept byte-for-byte identical to `infra`'s own copy so the
  two stay obviously in sync; if `infra` grows a third FFI dependency, this needs the same
  addition.
-/

/-- Ask `pkg-config` for a package's flags, degrading to `#[]` when it or the
    package is missing — matching how Linen treats optional native
    dependencies. -/
def pkgConfigFlags (args : Array String) : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := "pkg-config", args }
    if out.exitCode != 0 then return #[]
    return (out.stdout.trimAscii.copy.splitOn " ").toArray.map (·.trimAscii.copy)
      |>.filter (· != "")
  catch _ => return #[]

/-- Link flags naming each library file outright, rather than adding its
    directory to the search path — see `infra`'s `lakefile.lean` for why a
    bare `-L` is unsafe on Linux (shadows the system glibc). -/
def pkgAbsoluteLibs (pkg : String) : IO (Array String) := do
  let libs ← pkgConfigFlags #["--libs", pkg]
  let libdirs ← pkgConfigFlags #["--variable=libdir", pkg]
  let libdir : Option String := (libdirs.filter (· != ""))[0]?
  let mut out : Array String := #[]
  for tok in libs do
    if tok.startsWith "-L" then
      continue                                  -- deliberately dropped
    else if tok.startsWith "-l" then
      let name := (tok.drop 2).toString
      match libdir with
      | some d =>
        let candidate : FilePath := (d : FilePath) / s!"lib{name}.so"
        if ← candidate.pathExists then
          out := out.push candidate.toString
        else
          out := out.push tok
      | none => out := out.push tok
    else
      out := out.push tok
  return out

/-- The active macOS SDK's framework and library search paths. `#[]` off macOS. -/
def macSdkArgs : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := "xcrun", args := #["--show-sdk-path"] }
    if out.exitCode != 0 then return #[]
    let sdk := out.stdout.trimAscii.copy
    if sdk.isEmpty then return #[]
    return #["-F", sdk ++ "/System/Library/Frameworks", "-L", sdk ++ "/usr/lib"]
  catch _ => return #[]

open Lean Elab Command in
run_cmd do
  let mkDef (n : Name) (flags : Array String) : CommandElabM Unit := do
    let lits : Array (TSyntax `term) := flags.map (fun s => quote s)
    elabCommand (← `(def $(mkIdent n) : Array String := #[$lits,*]))
  -- `System.Keychain`: Security.framework on macOS, libsecret on Linux.
  let keychain : Array String ←
    if System.Platform.isOSX then
      (macSdkArgs).map (· ++ #["-framework", "Security", "-framework", "CoreFoundation"])
    else if System.Platform.isWindows then
      pure #["-ladvapi32", "-lcredui"]
    else
      pkgAbsoluteLibs "libsecret-1"
  -- OpenSSL is deliberately absent here too — see `infra`'s `lakefile.lean`
  -- for why naming the system OpenSSL is not merely redundant but fatal.
  mkDef `nativeLinkArgs keychain

package «typednotes-infra» where
  version := v!"0.1.0"
  moreLinkArgs := nativeLinkArgs

require infra from git "https://github.com/typednotes/infra" @ "main"

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
-/

/-- `lake script run check` — same as `lake exe typednotes-infra check`. -/
script check (_args) do
  let out ← IO.Process.output { cmd := "lake", args := #["exe", "typednotes-infra", "check"] }
  IO.print out.stdout
  IO.eprint out.stderr
  return out.exitCode

/-- `lake script run plan` — needs live credentials; see `main`'s `withLive`. -/
script plan (_args) do
  let out ← IO.Process.output { cmd := "lake", args := #["exe", "typednotes-infra", "plan"] }
  IO.print out.stdout
  IO.eprint out.stderr
  return out.exitCode
