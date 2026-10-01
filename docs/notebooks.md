# Notebook deployment — v0.6.0

The previous fleet published the app image but supplied no writer/runtime URLs:
production health reported `lode:false`, `lun:false`, `compute:false` on 2026-10-01.
This release declares all three dependencies.

## Services and data

- Lode and Lun track their published `:latest` images, like every other fleet
  container. Each Plan/Apply resolves the current tag to a verified digest;
  changed content redeploys on Apply. They use the existing namespace and broker,
  and their URLs come from observed resource domains, not manually copied strings.
- The app and Lode share the declared `LODE_TOKEN`. The app, Lode and Lun share
  `LUN_TOKEN`; Lun also receives a stable `LUN_ID_SALT`.
- App/Lode/Lun are pinned to one warm instance. Workers receive 4 GiB memory,
  2 vCPU and a 900-second request timeout; the app receives a 120-second timeout.
- `typednotes-compute-db` is a separate classic `db-dev-s` PostgreSQL 16 instance
  with 10 GB SBS 5K block storage (Infra ≥ 0.22.2). Serverless SQL cannot supply
  CREATE ROLE/SCHEMA, so its existing application/vault databases are not reused.
  The classic default logical database is `rdb`; its actual public host/port
  composes `COMPUTE_DB_URL`.
- Only the app receives that administrator URL. Lun reads the actor-bound
  credential at `compute/{org}/{user}` and consumes the existing scoped runtime
  witnesses; neither Lode nor generated code receives the administrator.

The vault creates a separate `lun` service identity. It can read compute
credentials, connector policy/authority, and the reserved local PostgreSQL/vault
permission documents. Graph data allows bounded runtime reads/writes and graph
metadata allows listing. It has no general third-party credential grant and no
delete grant. The app remains write-only. `Fleet/Notebook.lean` carries
kernel-checked no-read/no-delete facts and private, proof-carrying worker capacity.
Vault parsing/enforcement, authenticated service transport and provider isolation
remain trusted execution boundaries.

## Required new deployment secrets

Add these under the existing repository/production Actions secret configuration:

- `LODE_TOKEN`
- `LUN_TOKEN`
- `LUN_ID_SALT`
- `LUN_SECRETS_PASSWORD`
- `COMPUTE_DB_PASSWORD`

Use independent random values, at least 32 characters for the first four.
The compute password must be 8–128 characters with uppercase, lowercase, a digit
and a special character. The Apply workflow checks these before cloud mutation.
Secret values remain outside Git and reach services through Secret Manager.
Keep the compute password stable: the provider cannot observe/reconcile database
password rotation merely by updating a secret.

## Publication and rollout

1. Publish Infra `v0.22.2` first: push its main commit, wait for that exact
   commit's main CI to pass, then push its tag. It uses supported SBS 5K storage
   instead of deprecated BSSD, fixes classic declarations, preserves the real
   endpoint port, waits for database readiness and avoids guessed username
   drift. The fleet lockfile pins that exact commit.
2. Publish Typednotes `v0.7.3` after its main CI passes, and wait for the image.
   This adds the beta mark; notebook runtime code is unchanged from `0.7.2`.
3. Push the fleet main commit and `v0.6.0`, supply the five secrets, review the
   Plan workflow and run the existing manual Apply workflow. No push auto-applies.
4. Confirm `/api/health` reports `lode:true`, `lun:true`, `compute:true`; then
   generate a notebook with its repository and generative AI connection selected.
   Check a DB-backed notebook to verify live role/schema privileges.

## Recovery and limits

The 2026-10-01 Apply run failed creating `typednotes-compute-db` because Infra
0.22.1 requested deprecated `volume_type=bssd`. Infra 0.22.2 requests `sbs_5k`;
the declared 10 GB size is supported by `db-dev-s` in `fr-par`. Publish the Infra
release and fleet update, review the new plan, then rerun the manual Apply workflow.
The rejected create did not create the compute instance; resources applied before
it remain and are read again on the next run.

The accompanying AWS note and `docs.typednotes.org` bucket warning are non-fatal:
AWS is not scanned without credentials, and the undeclared bucket is left alone
because its ownership marker cannot be read. Remove AWS from `accounts` only
after confirming it holds no fleet resources. If the bucket belongs to this
fleet, grant marker-read access; a subsequent apply will then destroy it because
it is no longer declared. Neither message caused the database creation failure.

Warm single instances avoid scale-to-zero and divergent worker disks, but do not
make Serverless Container storage durable. Rollout/recycling discards unfinished
writer sessions and runtime builds. The app reconstructs notebooks from committed
repository code and stored inputs; an interrupted writer must be generated again.
Run one worker pair per trust domain: allowed shell/Lake code is not a sandbox for
mutually untrusted organizations. Compute data and vault values live outside the
worker disks. Persistent worker volumes and a live cloud generation smoke are
not claimed by local release preparation.

## Local verification

`lake build` checks the fleet's proofs, concrete URL/token wiring, rollout
ordering and capacity/credential restrictions. `lake exe typednotes-infra check`
prints the 54-resource offline plan. The real vault correspondence check uses
a disposable PostgreSQL cluster, the actual declared identity string and the
compiled secrets-server, including forbidden reads/writes and metadata listing:

```sh
# Use the PostgreSQL server tools, not a client-only libpq initdb installation.
python3 scripts/check-notebook-vault.py /path/to/secrets-server
```

Set `NOTEBOOK_TEST_TMPDIR` to choose a private scratch parent. The check never
contacts the cloud or the deployed vault and removes its test database afterward.
