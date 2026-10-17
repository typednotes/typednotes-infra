# Fleet v0.9.0 — Local image and automatic combined builds

This release adds a self-contained Local image and switches both Local and Lite
to the newest stable release tag of each service, frozen to immutable commits
and matching SQL for each build. Lite remains the default cloud deployment.

## Local runtime

```sh
local/run.sh ./typednotes-data
```

The launcher prefers Podman, supports Docker explicitly, and publishes only a
localhost HTTP port. The image combines all six application services with
PostgreSQL 17. A dedicated persistent directory holds database files, generated
credentials, the vault master key and worker state. Human sign-in uses the
existing OAuth providers configured for localhost.

Startup initializes the database and applies packaged SQL before serving.
Append-only migration records, transactional application, stable service UIDs
and an exclusive directory lock protect restart/upgrade behavior. Shutdown
stops application processes before PostgreSQL. Actor-role provisioning uses a
separate logical compute database on the same server, enabling Local DB sinks.

## Newest releases and CI

- GitHub's paginated HTTPS tags API selects the greatest stable
  `vMAJOR.MINOR.PATCH` of each service; no source defaults fall back to old tags
  or branch heads. Both variants share one resolved source snapshot.
- The resolver packages numbered SQL and records source commits, checksums,
  worker dependencies and vault policy metadata in each image's build manifest.
- The Combined images workflow checks all six repositories every fifteen
  minutes. Packaging pushes, manual runs and `service-version-updated`
  repository dispatches also trigger it; scheduled detection needs no sender
  token in the service repositories.
- Native amd64 and arm64 jobs build both variants and run their container smoke
  tests before publication. Manual Apply and scheduled publishing have separate
  concurrency slots and run-specific image references.
- The standalone publisher advances multi-platform `latest` tags. Lite Apply
  reuses the build workflow and consumes its exact digest. Cloud deployment
  remains manual; first-time GHCR packages still need public visibility for
  anonymous pulls.

For live Lite plan/apply, the selected image's verified manifest supplies the
exact service SQL to Infra's four migration histories. Registry content and SQL
checksums are checked before reconciliation. Offline checks and teardown do
not require image metadata; full mode keeps its explicit schema releases.

## Validation

Release checks cover the Lean build, both offline fleet checks, both architecture
build graphs, vault-policy correspondence, Dockerfile/Python/workflow linting
and 25 tests. Native PostgreSQL integration checks include all 20 current
service SQL files, role isolation, migration rollback/history refusal and
restart recovery. The native database tests ran with PostgreSQL 16; PostgreSQL
17 and complete assembled-image execution are covered by the CI smoke path.

Full Linux image builds, container smoke execution and registry publication
remain CI verification; they were not completed locally. Pushing this release
starts the Combined images workflow as well as Plan and enables its schedule.

See [Local usage](../local/README.md), [combined image builds](../images/README.md)
and [Lite deployment](lite.md) for commands and configuration.
