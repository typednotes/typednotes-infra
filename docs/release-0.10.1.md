# Release 0.10.1 — correct and simplify Lite promotion

This patch fixes two runtime defects found during review of 0.10.0 and makes
the shared deployment model and workflow selection explicit.

## Correctness fixes

- Worker preparation stays stdlib-only under its scrubbed environment. The
  database helper import is confined to the database-check path, so Lode and
  Lun no longer fail with `ModuleNotFoundError: images` during preparation.
- Vault client host, port and TLS settings are derived together from the
  provider URL. Standalone services use the native HTTP front-door port (80),
  rather than inheriting Lite's loopback listener port (8200).
- Lite plan/apply, storage preparation, dump and teardown inspect owned cloud
  resources before reconciliation. Full-only resources, partial promotion,
  retained compute storage and a promoted public app refuse a downgrade or
  Lite teardown, including with `--force`. Unverifiable ownership/topology is
  refused; known foreign resources are left outside this check.
- Combined runtime rollouts explicitly restore the image entrypoint, including
  after a legacy-copy maintenance revision.

## Shared construction

`Fleet/Shared.lean` constructs Lite and promoted full from one storage
declaration, an explicit compatibility layout for existing physical names and
typed connection recipes. No rendered URL/password rewriting or secret-name
inference is used. `Fleet/Bundle.lean` shares bundle validation and SQL history
conversion. The original independent full fleet remains selectable.

Runtime service definitions contain each command, required configuration,
allowlist, health path and bundle-credential mapping once. Combined mode adds
loopback endpoints; standalone mode constructs only the selected service with
the fleet's explicit endpoint configuration.

## Workflow configuration and upgrades

Plan, Apply and Destroy default to `current`, resolved by one reusable
configuration workflow from repository variable `TYPEDNOTES_DEPLOYMENT` (Lite
when unset). Push-triggered plans use this same persisted selection.

Before initial promotion, deploy a newly built fixed Lite bundle. Persist its
digest in repository variable `TYPEDNOTES_LITE_IMAGE`, then set repository
variable `TYPEDNOTES_DEPLOYMENT=full-from-lite`. Promotion and subsequent updates
require the persisted image pin, so a later automatic plan cannot silently
select an older image or the Lite topology. Teardown does not need a valid image
pin or registry metadata. For later updates, publish/test a new bundle, replace
the repository image pin, then run Plan/Apply with `current`.

Both the declaration and the combined image need updating from 0.10.0. The
existing single-DB vault-copy procedure still applies to pre-0.10.0 installs.
See [the deployment guide](lite.md#upgrade-lite-to-full-in-place) for commands.

## Verification

The Lean build, all four offline deployment selections, owned/foreign/partial
promotion guard cases, 47 Python tests (including native PostgreSQL 16 copy and
recovery tests), vault-policy correspondence, Ruff and workflow lint pass.

Smoke fixtures are exported from the actual Lean service environments and
secret-input bindings, including the selected bundle's vault policies. Docker
fixtures model front-door HTTP ports rather than substituting internal listener
ports. Worker preparation is tested in a real scrubbed subprocess. Full image
smoke execution remains pending because local Docker Desktop requires enforced
organization sign-in; the publisher retains both native-architecture smoke
gates before image publication.
