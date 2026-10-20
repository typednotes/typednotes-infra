# Release 0.10.0 — split Lite storage and in-place promotion

Lite now provisions two Serverless SQL databases, matching the distributed
deployment's durable layout: `lite-typednotes-db` for app/ledger/audit and
`lite-typednotes-secrets-db` for the encrypted vault. All four histories remain
Infra-managed. The supervisor requires distinct connection configuration and
keeps vault credentials out of the other service processes.

## Full from Lite

Select `full-from-lite` in Apply / Plan / Destroy, or set
`TYPEDNOTES_DEPLOYMENT=full-from-lite`. This derives the full fleet over Lite's
existing database, history, IAM, secret and namespace identities. The public
`typednotes-lite` container becomes the app in place, retaining its domain
binding. The other services become separate containers; compute storage and
full's private-network/operator access policies are added.

Promotion requires the existing Lite image **by digest**. Every service runs
its own executable from that exact bundle (`TYPEDNOTES_SERVICE`), with its own
Unix identity, allowlisted configuration and healthcheck. Image SQL and vault
policies are used for both layouts. Original independent `full` deployments
retain their existing names, ownership boundary and release behavior.

## Existing Lite installations

A pre-0.10.0 single-database installation needs a one-time vault split before
the runtime upgrade. CLI mode `lite-storage` prepares databases and secrets
without changing the runtime or applying migrations. `python3 -m lite.storage`
copies the encrypted vault and Infra history, verifies every row, and archives
the source under retired names without deleting rows. Interrupted copies can
resume; mismatching destinations are refused. The runtime refuses a legacy
vault still present in the application DB rather than bootstrapping an empty
replacement vault. Retain the original master key.

New combined manifests declare `runtimeVersion: 2`; cloud plan/apply refuses
older images which lack split storage and standalone service support. Local
keeps its existing single application/vault database and separate compute DB.

See [the deployment guide](lite.md#upgrade-lite-to-full-in-place) for promotion,
the legacy copy procedure, required secrets and recovery. After promotion,
continue using `full-from-lite`: Lite is the same fleet, not an old environment
to destroy. Downgrade is not supported.

## Verification

Release checks include the Lean build and all four offline selections; guards
for stable durable names, unique keys, history destinations, bundle version and
image/SQL alignment; Python process/configuration/build tests; and native
PostgreSQL 16 tests for copy fidelity, retained source data, destination refusal
and interruption/retry, plus existing Local lifecycle/migration tests.

The image publisher exercises two logical DML-only databases, combined-runtime
restart recovery, fail-fast supervision, then promotion to six containers using
the same image and retained vault data, with a separate compute DB enabled.
Both native image architectures must pass before publication.
