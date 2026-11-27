# Changelog

## [Unreleased]

## [0.10.5] — 2026-11-27

### Changed

- Update the Linen dependency to [4.1.0](https://github.com/typednotes/linen/releases/tag/v4.1.0).

## [0.10.4] — 2026-11-27

### Changed

- Build the fleet CLI against Linen 4.0.0 at its [release commit](https://github.com/typednotes/linen/commit/037925bc5068c54efd86690b78b258b9c6787959) and Lean 4.36.0.
- Supply the operator gateway allowlist at run time through `OPERATOR_CIDRS`.
- Delegate service image builds to `typednotes-lite`.
