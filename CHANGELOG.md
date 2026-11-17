# Changelog

Notable changes to the Typednotes fleet declaration. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are
[semantic](https://semver.org/). Releases before 0.10.2 are described by their
git tags and by `docs/release-*.md`.

## [Unreleased]

### Changed

- `autoImplicit` is back to Lean's default (on): it automates implicit binders,
  which are still fully checked, so it is not a weakening (agents-md standard v4).
  Warnings still fail the build (`lake build --wfail`).

## [0.10.2] — 2026-11-17

### Fixed

- The combined-image smoke test now sees what the Local runtime prints on
  stderr, so its exclusive-directory check passes when the second instance
  refuses the shared directory, and a failing container's output is shown
  before cleanup. Commands whose output is parsed keep stderr separate.

### Changed

- Strict checking in CI: Lean builds with `autoImplicit` and
  `relaxedAutoImplicit` off and `lake build --wfail` (a warning fails the
  build), and the Python under `images/`, `lite/`, `local/` and `scripts/` is
  checked by `mypy --strict`. The declared fleet is unchanged.

Details: [docs/release-0.10.2.md](docs/release-0.10.2.md).
