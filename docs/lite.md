# Typednotes Lite

Lite is the default deployment architecture for the local CLI and the CI
Apply / Plan / Destroy workflows. Select `full-from-lite` to expand it in place,
or `full` for the independent original distributed fleet.

## Runtime and storage

`Fleet/Lite.lean` declares one public Serverless Container (`typednotes-lite`)
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

Built-in PostgreSQL notebook connectors and `db` sinks are unavailable:
Scaleway Serverless SQL does not support their actor-role provisioning. Lite
does not set `COMPUTE_DB_URL`; `/api/health` therefore reports `compute:false`,
alongside configured Lode and Lun. Pure/connector-backed graph execution,
generation and vault storage use the existing service paths. Selecting full
topology adds the separately provisioned compute database; a second Serverless
SQL database alone cannot support actor-role provisioning.

## Building the image

`scripts/build-images.sh` resolves each service's newest stable
`vMAJOR.MINOR.PATCH` tag, peels it to an immutable commit and discovers that
commit's numbered SQL files. `lite/docker-bake.hcl` builds each service through
its repository's Dockerfile and assembles **both Lite and Local** from the same
snapshot. The generated `.images/bake.json` supplies the frozen source refs.
Intermediate service images do not need publishing.

The final Debian Trixie base meets the app's glibc requirement and contains the
native libraries the Lean executables need. Identical installed Lean toolchains
are deduplicated; different worker release toolchains remain supported. Each
worker has its own warm package cache and private writable elan home. Native
amd64 and arm64 variants are built and tested in CI.

To build locally, from the repository root with a running Docker daemon:

```sh
scripts/build-images.sh
```

The wrapper disables GitHub cache exporters outside CI and defaults to the
host's native architecture. A new service tag needs no version-file edit here.
Source commits and SQL checksums are recorded in the image's build manifest.
Live Lite plan/apply resolves the image once, reads that manifest and supplies
its verified SQL to Infra, keeping migrations aligned with the executable even
as `latest` changes. Offline checks use the declared baseline without networking.
See [the shared build guide](../images/README.md) for the metadata boundary.

## CI deployment

Run **Apply** with `deployment: lite` (the default) and the existing
`typednotes` confirmation. The workflow:

1. Calls the reusable Combined images publisher. New service versions or
   packaging changes build and smoke-test both Lite and Local on native amd64
   and arm64 runners; an already published snapshot can be reused.
2. Checks both fleets, process/configuration tests and required deployment secrets.
3. Passes the returned immutable Lite image reference to plan, apply and
   convergence with `TYPEDNOTES_LITE_IMAGE`. Each call obtains the same image's
   matching migration SQL; Infra retains the migration/rollout gates.

The publisher also runs on a fifteen-minute tag-check schedule, packaging pushes,
manual dispatch and `service-version-updated` repository dispatch. A service
repository does not need a cross-repository token for scheduled detection.
Automatic image publication never applies cloud infrastructure.

`GITHUB_TOKEN` needs `packages:write`, which the job declares. Like the other
service packages, **the GHCR package must be public** so Infra and Scaleway can
pull it. GitHub does not let `GITHUB_TOKEN` make a new package public: after the
first upload, set both combined packages' visibility to public and rerun Apply.
The image-metadata read in the live plan checks anonymous access before cloud
creation. Packaging pushes can publish images; deployment remains manual.
Before the first publication, a live Lite plan cannot resolve its `latest` image.

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
metadata helper as well as by the build tools.

## Startup, shutdown and recovery

`lite/runtime.py` starts the vault, ledger, liaison, Lun and Lode, waits for their
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

`Fleet/Promotion.lean` derives the distributed fleet over Lite's existing
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
service `latest` images. Bundles must declare `runtimeVersion: 2` (built with
Infra 0.10.0 or later). Older bundles are refused before cloud reconciliation.

1. For a pre-0.10.0 single-DB installation, complete the vault split below and
   deploy the new Lite bundle first. Fresh two-DB installations skip this step.
2. Drain active notebook work. Ensure full's existing Private Network is ready
   ([service access](service-access.md)) and supply `COMPUTE_DB_PASSWORD`,
   `DB_INSPECTOR_USERNAME` and `DB_INSPECTOR_PASSWORD` in addition to Lite's secrets.
   Keep the same vault key, service passwords and `LUN_ID_SALT`.
3. Read the **currently deployed** Lite digest from the container's image setting.
   Use that digest for the whole promotion, including its convergence check:

```sh
export TYPEDNOTES_DEPLOYMENT=full-from-lite
export TYPEDNOTES_LITE_IMAGE=ghcr.io/typednotes/typednotes-lite@sha256:…
scripts/check-deployment-secrets.sh
lake exe typednotes-infra plan --refresh-secrets
lake script run apply --yes --refresh-secrets
lake exe typednotes-infra plan --refresh-secrets
```

In CI select `full-from-lite` and supply the same digest in `lite_image`.
The workflow uses the selected existing image rather than publishing a new
bundle during promotion. Verify `/api/health` (including `compute:true`), sign-in,
existing notebooks and a connection whose credential is stored in the vault.
The old combined runtime is replaced only after its new service dependencies
have been created. Worker scratch state remains ephemeral.

**Continue selecting `full-from-lite` for subsequent deployments and teardown.**
It and Lite are two topologies of the **same fleet**, not independent
environments. Applying Lite afterward would retire full-only resources,
including compute storage; it is not a supported downgrade. In particular,
never destroy `lite` as a cleanup step after promotion: that is the same fleet.
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

Destroy defaults to Lite and keeps its database/history with `--keep-data`, just
as full mode does. Select the intended mode in the workflow before teardown.

## Verification

```sh
lake build
lake exe typednotes-infra check
TYPEDNOTES_DEPLOYMENT=full lake exe typednotes-infra check
TYPEDNOTES_DEPLOYMENT=full-from-lite lake exe typednotes-infra check
TYPEDNOTES_DEPLOYMENT=lite-storage lake exe typednotes-infra check
python3 -m unittest discover -s lite/tests -v
LOCAL_POSTGRES_BIN=/path/to/postgresql/bin python3 -m unittest discover -s lite/tests -v
python3 -m images.releases --output .images
python3 lite/check-image.py ghcr.io/typednotes/typednotes-lite:latest .images/manifest.json
```

The image check needs Docker and a built image matching the resolved snapshot.
It uses the packaged SQL with disposable Docker resources and makes no cloud or
paid-provider calls. See [Local](../local/README.md) for the single-image,
directory-backed runtime, including Podman usage.
