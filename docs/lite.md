# Typednotes Lite

Lite is the local CLI default and the initial CI topology. Apply / Plan /
Destroy default to `current`, resolved from repository variable
`TYPEDNOTES_DEPLOYMENT` (initially `lite` when unset). Push-triggered plans use
that same persisted selection. `full-from-lite` expands Lite in place; `full`
is the independent original distributed fleet.

## Runtime and storage

`Fleet/Lite.lean` selects one public Serverless Container (`typednotes-lite`)
and two Serverless SQL databases (`lite-typednotes-db` and
`lite-typednotes-secrets-db`) in Paris. Its namespace,
three IAM identities (migrator / observer / runtime), keys and Secret Manager
entries are the supporting plumbing. No private network or classic RDB instance
is required. Capacity starts at 4 vCPU / 8 GiB with exactly one warm instance;
Lun starts with one loaded worker. This is a deployment capacity choice, not a
measured minimum or a scale-to-zero configuration.

The image contains six service executables. The app serves the public port
(`PORT`, default 8080); ledger uses 8081, liaison 8082, Lun 8083, Lode 8084 and
the vault 8200. Calls between them use localhost. Only the app port is published.
The DB inspector and operator gateway are full-mode operational conveniences.

Application, ledger and audit tables share the application database, with
independent `core`, `ledger` and `liaison` bookkeeping schemas. Encrypted vault
tables and the `secrets` bookkeeping schema live in the vault database. The
supervisor receives distinct `DATABASE_URL` and
`SECRETS_SERVER_STORAGE_DATABASE_URL` secrets and passes each only to its service.
Four service migration histories from the selected image are applied by Infra.
The combined container waits for all four. No serving process migrates itself
or receives the migrator's credentials.

`Fleet/Shared.lean` constructs both topologies from full's single storage
declaration, an explicit physical-name layout and typed connection recipes.
`Fleet/Bundle.lean` validates and applies one `BundleDeployment` snapshot to
either topology; migration conversion is shared too.

Built-in PostgreSQL notebook connectors and `db` sinks are unavailable:
Scaleway Serverless SQL does not support their actor-role provisioning. Lite
does not set `COMPUTE_DB_URL`; `/api/health` therefore reports `compute:false`,
alongside configured Lode and Lun. Pure/connector-backed graph execution,
generation and vault storage use the existing service paths. Selecting full
topology adds the separately provisioned compute database; a second Serverless
SQL database alone cannot support actor-role provisioning.

## The combined image

The Lite and Local images are built and published by the
[typednotes-lite repository](https://github.com/typednotes/typednotes-lite),
which freezes each service's newest stable `vMAJOR.MINOR.PATCH` tag to its
immutable commit and records that snapshot — source commits and SQL checksums —
in the image's build manifest. This repository no longer builds images; it
consumes the published `ghcr.io/typednotes/typednotes-{lite,local}` packages.

Live Lite plan/apply resolves the image once, reads that manifest and supplies
its verified SQL to Infra, keeping migrations aligned with the executable even
as `latest` changes. Offline checks use the declared baseline without networking.
See [the shared metadata guide](../images/README.md) for the metadata boundary.

## CI deployment

Run **Apply** with `deployment: current` (initially Lite) and the existing
`typednotes` confirmation. The workflow:

1. Checks both fleets, process/configuration tests and required deployment secrets.
2. Passes the selected immutable Lite image reference to plan, apply and
   convergence with `TYPEDNOTES_LITE_IMAGE`. Each call obtains the same image's
   matching migration SQL; Infra retains the migration/rollout gates.

The image is not rebuilt in this repository: Apply deploys the digest of the
already published combined image. Publication never applies cloud infrastructure.

Like the other
service packages, **the GHCR package must be public** so Infra, Scaleway and the
live plan's anonymous image-metadata read can access it. If the package is
private, set its visibility to public; before the first publication, a live Lite
plan cannot resolve its `latest` image.

Lite requires the existing four Scaleway credentials and fleet values except
`COMPUTE_DB_PASSWORD`, `DB_INSPECTOR_USERNAME`, `DB_INSPECTOR_PASSWORD`. The complete
mode-aware check is `scripts/check-deployment-secrets.sh`. The OAuth callback and
webhook configuration remains as documented in the README.

Local deployment uses the same declaration:

```sh
lake exe typednotes-infra check
lake exe typednotes-infra plan --refresh-secrets
lake script run apply --yes --refresh-secrets
```

Set `TYPEDNOTES_LITE_IMAGE=ghcr.io/typednotes/typednotes-lite@sha256:…` for an
explicit immutable image; otherwise live runs freeze `latest` and its matching
schema manifest before handing the plan to Infra. Python 3 is required by this
metadata helper.

## Startup, shutdown and recovery

`lite/runtime.py` constructs services from one set of service definitions.
Combined mode supplies loopback endpoints; standalone mode requires the remote
endpoint configuration from the fleet. Native private HTTP URLs use front-door
port 80, independently of the process's container listening port. Host, port and
TLS are derived together from the observed vault URL.

The supervisor starts the vault, ledger, liaison, Lun and Lode, waits for their
health endpoints, then starts the public app. Any required process exiting—even
with exit code zero—stops the others and exits nonzero so the platform can recycle
the instance. Shutdown signals reach compiler/worker process groups; Tini reaps
orphaned children. The image's healthcheck probes all six services.

Each service runs under its own Unix user with an allowlisted environment.
Workers do not inherit the vault master key, database URL, warrant root or
provider OAuth credentials. The supervisor retains the deployment secrets to
launch those processes. The services still share a container and resource/failure
domain; this follows the existing single-trust-domain worker model.

Serverless Container disk is ephemeral. Database and encrypted vault contents
survive recycling; unfinished Lode sessions and warm Lun builds do not. The
stable `LUN_ID_SALT`, vault master key and service credentials stay in Secret
Manager. Recover notebooks from committed repository code and persisted app state;
regenerate interrupted writer work. Retain a durable copy of the vault master key.

## Upgrade Lite to full in place

`Fleet/Promotion.lean` selects the distributed topology over Lite's existing
resource identities. `TYPEDNOTES_DEPLOYMENT=full-from-lite` (also available in
Apply / Plan / Destroy) keeps both databases, all four migration histories, IAM
identities, encryption key, service credentials and namespace. The public
`typednotes-lite` container becomes the standalone app **in place**, preserving
its container ID and custom-domain binding. Separate vault, ledger, liaison,
Lode and Lun containers, the private compute database, inspector and operator
gateway are added using full's network/access policies.

All six services run the **same immutable Lite image** with a service selector
(`TYPEDNOTES_SERVICE`). This retains the exact binaries, policies, worker caches
and SQL already deployed; promotion never substitutes independently moving
service `latest` images. Bundles must declare `runtimeVersion: 2`, introduced in
Typednotes Infra 0.10.0. Use a bundle built from **0.10.1 or later** for the worker
startup and standalone-endpoint fixes. Older bundle formats are refused before
cloud reconciliation.

1. For a pre-0.10.0 single-DB installation, complete the vault split below.
   Rebuild/publish and deploy a fixed Lite bundle from 0.10.1 or later before
   initial promotion, including when upgrading an existing 0.10.0 two-DB install.
2. Drain active notebook work. Ensure full's existing Private Network is ready
   ([service access](service-access.md)) and supply `COMPUTE_DB_PASSWORD`,
   `DB_INSPECTOR_USERNAME` and `DB_INSPECTOR_PASSWORD` in addition to Lite's secrets.
   Keep the same vault key, service passwords and `LUN_ID_SALT`.
3. Read the **currently deployed** fixed Lite bundle digest from the container's
   image setting. Initial promotion uses that same digest. Persist both the
   intended topology and image in **repository** variables (Settings → Secrets
   and variables → Actions → Variables), so future pushes plan the promoted
   topology. Set the image first, then the topology:

```sh
export TYPEDNOTES_DEPLOYMENT=full-from-lite
export TYPEDNOTES_LITE_IMAGE=ghcr.io/typednotes/typednotes-lite@sha256:…
gh variable set TYPEDNOTES_LITE_IMAGE --repo typednotes/typednotes-infra --body "$TYPEDNOTES_LITE_IMAGE"
gh variable set TYPEDNOTES_DEPLOYMENT --repo typednotes/typednotes-infra --body "$TYPEDNOTES_DEPLOYMENT"
scripts/check-deployment-secrets.sh
lake exe typednotes-infra plan --refresh-secrets
lake script run apply --yes --refresh-secrets
lake exe typednotes-infra plan --refresh-secrets
```

In CI select `current`; the common configuration workflow resolves the same
repository variables for Plan, Apply and Destroy. Promotion refuses to run
until its topology and image have been persisted. An explicit `lite_image`
must agree with the repository pin, preventing later automatic plans from
selecting an older bundle.
The workflow uses the selected existing image rather than publishing a new
bundle during promotion. Verify `/api/health` (including `compute:true`), sign-in,
existing notebooks and a connection whose credential is stored in the vault.
The old combined runtime is replaced only after its new service dependencies
have been created. Worker scratch state remains ephemeral.

### Updating a promoted deployment

For subsequent releases, first publish and test a **new** combined bundle
(built by the typednotes-lite repository), then
update repository variable `TYPEDNOTES_LITE_IMAGE` to its immutable digest.
Run Plan and Apply with `current`. Initial promotion reuses the deployed image;
later updates intentionally select a new tested image and its matching SQL.
For local updates, set `TYPEDNOTES_DEPLOYMENT=full-from-lite` and the new digest
in `TYPEDNOTES_LITE_IMAGE` before plan/apply/convergence.

**Continue using `current` (configured as `full-from-lite`) for deployments and teardown.**
It and Lite are two topologies of the **same fleet**, not independent
environments. Applying Lite afterward would retire full-only resources,
including compute storage; it is not a supported downgrade. In particular,
never destroy `lite` as a cleanup step after promotion: that is the same fleet.
The CLI checks ownership and actual cloud resources before Lite plan/apply,
storage preparation, dump or teardown. It refuses a promoted app, full-only
resources from a partial promotion, and retained compute storage. `--force`
does not bypass this check. Resume `full-from-lite` after a partial promotion.
Independent `full` remains a separate installation and does not perform this
promotion.

## One-time vault split for older Lite installations

Before upgrading a one-database Lite installation, move its vault to the new
database. The new runtime refuses startup while `public.kv_store` is still in
the application database, rather than silently initializing an empty vault.
The existing vault master key must be retained throughout.

1. Stop the old combined runtime and block traffic from restarting it. A
   maintenance revision that serves HTTP 503 without launching the application
   processes is sufficient. Wait for in-flight work to finish. The copy also
   takes table locks, but does not stop a running container for you.
2. Prepare the new database and its connection secrets, without applying new
   migrations or changing the runtime. Use the same operator secret values as
   the existing deployment:

```sh
TYPEDNOTES_DEPLOYMENT=lite-storage lake exe typednotes-infra plan --refresh-secrets
TYPEDNOTES_DEPLOYMENT=lite-storage lake script run apply --yes --refresh-secrets
```

`lite-storage` is a CLI preparation mode for this procedure. Existing histories
and the public container remain declared but unmanaged, so neither new SQL nor
a serving vault is started. It is not a runtime deployment or a cleanup mode.

3. Install matching-major PostgreSQL `psql` and `pg_dump` clients. Export the
   values of Secret Manager's `lite-typednotes-migrator-url` and
   `lite-typednotes-secrets-migrator-url` as `LITE_APP_MIGRATOR_URL` and
   `LITE_VAULT_MIGRATOR_URL`, respectively. Then run:

```sh
python3 -m lite.storage
unset LITE_APP_MIGRATOR_URL LITE_VAULT_MIGRATOR_URL
```

The tool copies `public.kv_store` and `secrets.infra_migrations` into an empty
destination in one transaction, verifies every row (including history SQL and
timestamps), then renames the source to `public.lite_retired_kv_store` and
`lite_retired_secrets`. No source rows are deleted. A mismatching/nonempty
destination is refused; an exact previous copy can resume after interruption.
Connection passwords are passed through libpq environment variables, not argv
or logs. The expected legacy layout is one vault table and one history table;
unexpected bookkeeping tables are refused.

4. Build/publish a new bundle, apply `lite` normally, and verify existing vault
   credentials, sign-in and notebooks before promoting. If rolling back before
   new vault writes, stop the new runtime and rename the archived source table
   and schema back before restoring the old image. After new writes, reconcile
   the vault database first; the archived copy is only the cutover snapshot.

## Independent full-mode coexistence and the public domain

Lite and full-from-lite use marker `managed-by-infra=typednotes-lite`, namespace `typednotes-lite`
and database prefix `lite-typednotes-`. Independent full mode keeps marker `typednotes` and
its existing database prefixes. Offline guards verify that neither prefix claims
the other's databases. Applying or destroying either independent fleet leaves the other alone.

Choosing independent `full` does **not** migrate users, notebooks or encrypted
vault data. Existing full-mode operators should keep selecting `full`.
The in-place upgrade for Lite operators is explicitly `full-from-lite`.

Both declarations currently use `app.typednotes.com` as `PUBLIC_URL`. Attach its
DNS/container-domain binding to the chosen container after applying; the binding
is external to Infra. The README's domain procedure also applies to Lite, and
`scripts/check-domain.sh` accepts `APP_CONTAINER=typednotes-lite`. The other
deployment stays accessible at its own container endpoint, but configured OAuth
redirects still use `PUBLIC_URL`.

Destroy defaults to the persisted `current` topology and keeps data with `--keep-data`, just
as full mode does. Select the intended mode in the workflow before teardown.

## Verification

```sh
lake build
lake exe typednotes-infra check
TYPEDNOTES_DEPLOYMENT=full lake exe typednotes-infra check
TYPEDNOTES_DEPLOYMENT=full-from-lite lake exe typednotes-infra check
TYPEDNOTES_DEPLOYMENT=lite-storage lake exe typednotes-infra check
lake env lean --run scripts/check-topology.lean
python3 -m unittest discover -s lite/tests -v
LOCAL_POSTGRES_BIN=/path/to/postgresql/bin python3 -m unittest discover -s lite/tests -v
```

The process/configuration tests use the Lean-exported service environments,
vault policies and secret-input bindings (`scripts/service-config.lean`) rather
than a hand-maintained full-mode fixture. They make no cloud or paid-provider
calls and need no Docker. See [Local](../local/README.md) for the single-image,
directory-backed runtime, including Podman usage.
