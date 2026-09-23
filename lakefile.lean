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
  rather than depend on inheriting it. Kept byte-for-byte identical to `infra`'s own copy
  (between the `⟪native-link-flags⟫` markers) so the two stay obviously in sync. Since infra
  0.13.0 that includes `libpq`: the `postgresMigrations` backend speaks the Postgres wire
  protocol through `linen`'s FFI, so `libpq` (and `pkg-config`) must be installed wherever
  this builds — CI installs `libpq-dev`.
-/

-- ⟪native-link-flags:begin⟫ — copied verbatim from `infra`'s own lakefile (v0.14.0).
-- Diff the marked blocks when bumping `infra`; they must stay identical.
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
    directory to the search path.

    On Linux, `pkg-config --variable=libdir` is typically
    `/usr/lib/x86_64-linux-gnu`, which holds the *system* `libc.so` alongside
    everything else. Passing that as `-L` makes `ld.lld` prefer the system
    glibc over the one Lean bundles, and Lean's own `Scrt1.o` references
    `__libc_csu_init` — removed in glibc 2.34. The result is a link that fails
    with an undefined symbol in the C runtime, nowhere near anything this
    package wrote.

    Linen has the same `-L` and never hits this, because only `lean_lib Linen`
    is a default target there: `lake build` never links an executable. `infra`
    does.

    Naming the library file directly links exactly the intended file and
    shadows nothing — `.dylib` on macOS, `.so` on Linux (`ledger`'s lakefile
    carries the same two-extension probe, for the same reason: a Homebrew
    libpq is `libpq.dylib`, and a `.so`-only probe falls back to a bare
    `-lpq` whose directory nothing added). Falls back to `-lfoo` if the file
    is absent, so a distro with a different layout still gets a chance. -/
def pkgAbsoluteLibs (pkg : String) : IO (Array String) := do
  let libs ← pkgConfigFlags #["--libs", pkg]
  let libdirs ← pkgConfigFlags #["--variable=libdir", pkg]
  let libdir : Option String := (libdirs.filter (· != ""))[0]?
  let ext := if System.Platform.isOSX then "dylib" else "so"
  let mut out : Array String := #[]
  for tok in libs do
    if tok.startsWith "-L" then
      continue                                  -- deliberately dropped
    else if tok.startsWith "-l" then
      let name := (tok.drop 2).toString
      match libdir with
      | some d =>
        let candidate : FilePath := (d : FilePath) / s!"lib{name}.{ext}"
        if ← candidate.pathExists then
          out := out.push candidate.toString
        else
          out := out.push tok
      | none => out := out.push tok
    else
      out := out.push tok
  return out

/-- The active macOS SDK's framework and library search paths. Lean ships its
    own `lld`, which has no default framework path, so these are required for
    `-framework` to resolve. `#[]` off macOS. -/
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
  -- `Database.SQL`'s libpq. Absolute-path form on Linux for the same reason
  -- the comment above `pkgAbsoluteLibs` gives: an `-L` to the system libdir
  -- lets the distro's glibc shadow Lean's bundled one.
  let libpq : Array String ← pkgAbsoluteLibs "libpq"
  -- OpenSSL is deliberately absent, though `jose.o` and `tls.o` both reference
  -- it. Lean already ends every executable link with its own
  -- `LEANC_INTERNAL_LINKER_FLAGS`:
  --
  --     -L <toolchain>/lib … -lgmp -luv -lssl -lcrypto
  --
  -- which resolves against the *static* `libssl.a`/`libcrypto.a` the release
  -- toolchain bundles (`script/prepare-llvm-linux.sh`: `cp $OPENSSL/lib/libssl.a
  -- $OPENSSL/lib/libcrypto.a stage1/lib/`). Those archives are already the
  -- last thing on the line, which is exactly where an archive has to sit to
  -- satisfy `liblinenffi.a` above it.
  --
  -- Naming the system OpenSSL as well is not merely redundant on Linux, it is
  -- fatal. A current distro's `libssl.so`/`libcrypto.so` need
  -- `stat@GLIBC_2.33`, `dlopen@GLIBC_2.34` and `__isoc23_strtol@GLIBC_2.38`,
  -- while the glibc Lean bundles under `lib/glibc` predates all three — it
  -- still has the `__libc_csu_init` that glibc 2.34 removed. Under lld's
  -- default `--no-allow-shlib-undefined` that is an immediate link failure on
  -- eighteen symbols no code here can reach.
  --
  -- Dropping it retires the macOS hazard too: the reason to point at
  -- Homebrew's OpenSSL was that dyld could otherwise bind to the system's
  -- incompatible `libboringssl` and crash on the first TLS call. A static
  -- archive cannot be re-bound at runtime, so the failure mode is gone rather
  -- than merely avoided.
  --
  -- The Linux CI still installs `libssl-dev`, for the *headers* Linen's
  -- `jose.c`/`tls.c` compile against. Only the link flags are unnecessary.
  mkDef `nativeLinkArgs (keychain ++ libpq)
-- ⟪native-link-flags:end⟫

package «typednotes-infra» where
  version := v!"0.4.0"
  moreLinkArgs := nativeLinkArgs

-- A tag rather than `main`. `Main.lean` hands the whole declaration to
-- `Infra.Cli.run` in one value, which does not compile against an `infra`
-- older than 0.9.0; and the reverse — tracking `main` — means the next
-- breaking change in the front end arrives here unannounced, in whatever
-- state it happens to be in. Moving forward is a deliberate edit: bump this,
-- run `lake update infra`, and read the library's CHANGELOG on the way.
require infra from git "https://github.com/typednotes/infra" @ "v0.17.0"


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

/-- `lake script run apply --yes` — the only command here that changes a
    cloud.

    Unlike `check` and `plan`, this does not merely save typing: it **refuses
    without `--yes`**. A one-word `apply` sitting next to a one-word `plan` is
    too easy to reach for by accident, and the two differ by whether real,
    billable resources are created or destroyed — so the intent has to be
    stated separately from the command name. CI supplies the flag from a
    manually dispatched workflow and never from a push; see
    `.github/workflows/apply.yml`.

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
    { cmd := "lake", args := #["exe", "typednotes-infra", "apply"] }
  return (← child.wait)
