# Release 0.10.2 — image smoke diagnostics and strict type checking

This patch makes the combined-image smoke test report the refusal it is
checking for, and turns on strict static checking for both languages in the
repository. The declared fleet is unchanged.

## Image smoke test

The Local exclusive-directory check failed on both native assemblies even though
the second container refused the shared directory correctly: the runtime prints
that refusal on stderr, and the smoke helper returned only stdout. `docker logs`
now captures both streams, while commands whose output is parsed (`inspect`,
SQL) keep stderr separate. A failing second container's output is included in
the error before cleanup. `images/tests/test_smoke.py` covers this with real
subprocess streams and no Docker daemon.

`images/README.md` records the CI failure, the account-level Actions billing
block seen on later runs, and how to restart the publisher and Lite plan at the
fixed revision once that is resolved.

## Strict type checking

- Lean: the package turns `autoImplicit` and `relaxedAutoImplicit` off, and
  every workflow builds with `lake build --wfail`, so a warning (including
  `sorry`) fails CI. The fleet needed no changes to pass.
- Python: `mypy --strict` (configured in `mypy.ini`) checks `images/`, `lite/`,
  `local/` and `scripts/*.py`, and runs first in `plan.yml` with a pinned mypy.
  Every function is annotated. Behaviour is unchanged, with three explicit
  checks where a value could previously be missing: a migration history naming a
  service without SQL is refused, `lite/check-build.py` requires `--build-run`
  with `--receipts`, and Local supervision treats a never-started PostgreSQL as
  exited.

## Verification

`lake build --wfail`, the offline `check` for all four deployment selections,
`scripts/check-topology.lean`, `mypy` (25 files, no issues) and the Python suites
(images 20, lite 23, local 7 tests; PostgreSQL 16 for the database tests) pass
locally. The image smoke suites themselves run in the publisher workflow.
