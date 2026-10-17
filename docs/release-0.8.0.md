# Fleet v0.8.0 — default Lite deployment

This release adds a Lite architecture and makes it the default in the local
CLI and CI Apply / Plan / Destroy workflows. The existing distributed fleet
is selected with `TYPEDNOTES_DEPLOYMENT=full`, or the workflow's `full` option.

## Deployment

- One warm Serverless Container (`typednotes-lite`, 4 vCPU / 8 GiB) and one
  Serverless SQL database (`lite-typednotes-db`) in Paris, with supporting IAM,
  namespace and Secret Manager resources.
- All four existing SQL histories share the database. Schema releases remain
  app **0.11.0**, ledger **0.3.7**, liaison **0.6.0** and secrets **1.3.0**.
- Six service processes run under a supervisor, with separate Unix users,
  allowlisted environments, startup checks and process-group shutdown.
- Lode and Lun share the installed Lean toolchain and warm package cache.
- Built-in PostgreSQL connectors / `db` sinks are unavailable because Serverless
  SQL cannot provision actor roles. Lite omits `COMPUTE_DB_URL`.

Lite and full have independent ownership markers and database prefixes.
Selecting Lite creates a separate deployment; it does not migrate full-mode
users, notebooks or encrypted vault data. Existing operators can keep selecting
`full` until a deliberate data/domain cutover. Container disks remain ephemeral.

## Image build and CI

`lite/docker-bake.hcl` builds the app **0.11.0**, ledger **0.3.7**, liaison
**0.6.3**, secrets **1.3.0**, Lode **0.5.0** and Lun **0.4.2** from their source
tags and each repository's Dockerfile, then assembles a single Linux amd64 image.
The image uses Linen **1.12.0** for its runtime build dependencies and cache.

Lite Apply builds the image, runs the six-service smoke test against disposable
PostgreSQL, publishes the tested image and passes its exact digest through the
live plan, apply and convergence check. Full mode uses its existing service
images. Lite does not require compute DB or DB-inspector credentials.

The new `ghcr.io/typednotes/typednotes-lite` package must be public for anonymous
Infra/Scaleway pulls. Its first upload may require a one-time visibility change
and an Apply retry. Before the first image publication, the automatic live Lite
plan cannot resolve `latest`. Pushing source runs Plan; image publication and
deployment remain part of the manually dispatched Apply workflow.

## Validation

Release checks cover the Lean build, both offline fleets, ten supervisor and
configuration tests, source-build/schema alignment, Dockerfile/Python/workflow
linting and whitespace checks. All twenty declared migration files were also
applied together to a disposable PostgreSQL database; the real vault started
with DML-only credentials and recovered an encrypted value after restart.

The assembled Linux image build and complete container smoke test remain CI
verification: local Docker execution is blocked by administrator-enforced
Docker Desktop sign-in. This release does not claim a completed live rollout.

See [the Lite deployment guide](lite.md) and
[the build/Bake explanation](../lite/README.md) for commands and operating details.
