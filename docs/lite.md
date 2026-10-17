# Typednotes Lite

Lite is the default deployment architecture for the local CLI and the CI
Apply / Plan / Destroy workflows. Set `TYPEDNOTES_DEPLOYMENT=full`, or select
`full` in the workflow, to use the existing distributed fleet.

## Runtime and storage

`Fleet/Lite.lean` declares one public Serverless Container (`typednotes-lite`)
and one Serverless SQL database (`lite-typednotes-db`) in Paris. Its namespace,
three IAM identities (migrator / observer / runtime), keys and Secret Manager
entries are the supporting plumbing. No private network or classic RDB instance
is required. Capacity starts at 4 vCPU / 8 GiB with exactly one warm instance;
Lun starts with one loaded worker. This is a deployment capacity choice, not a
measured minimum or a scale-to-zero configuration.

The image contains six service executables. The app serves the public port
(`PORT`, default 8080); ledger uses 8081, liaison 8082, Lun 8083, Lode 8084 and
the vault 8200. Calls between them use localhost. Only the app port is published.
The DB inspector and operator gateway are full-mode operational conveniences.

All application, ledger, audit and encrypted vault tables share one logical
database. The same four migration histories as full mode are applied by Infra,
with independent `core`, `ledger`, `liaison` and `secrets` bookkeeping schemas.
The combined container waits for all four. No serving process migrates itself
or receives the migrator's credentials.

Built-in PostgreSQL notebook connectors and `db` sinks are unavailable:
Scaleway Serverless SQL does not support their actor-role provisioning. Lite
does not set `COMPUTE_DB_URL`; `/api/health` therefore reports `compute:false`,
alongside configured Lode and Lun. Pure/connector-backed graph execution,
generation and vault storage use the existing service paths. Selecting full
mode restores the separately provisioned compute database.

## Building the image

`lite/docker-bake.hcl` builds each service from its source release, through
that repository's own Dockerfile, then supplies the results as named contexts
to `lite/Dockerfile`. No six-service intermediate images need publishing.
The checked-in source tags are:

- App `v0.11.0`, Ledger `v0.3.7`, Secrets `v1.3.0` (matching the schema releases).
- Liaison `v0.6.3` (its schema history remains `v0.6.0`).
- Lode `v0.5.0` and Lun `v0.4.2`, using Linen `v1.12.0`.

The final Debian Trixie base meets the app's glibc requirement and contains the
native libraries the Lean executables need. Lode and Lun share one installed
Lean toolchain and Lun's warmed Linen package cache. Their toolchain versions
must match; the image build rejects drift. Each worker gets a private writable
elan home with links to the bundled toolchains.

To build locally, from the repository root with a running Docker daemon:

```sh
docker buildx bake -f lite/docker-bake.hcl --set '*.cache-from=' --set '*.cache-to=' --set lite.output=type=docker
```

The GitHub cache exporters are disabled in that local command because they
need the Actions runtime. Source repositories, tags and their dependencies
must be published before a build can resolve them. When adopting new app,
ledger or vault migrations, update both the schema declaration in `Fleet.lean`
and the corresponding Bake source ref. `lite/check-build.py` checks alignment
against the actual Lean declaration exported by `scripts/lite-config.lean`.

## CI deployment

Run **Apply** with `deployment: lite` (the default) and the existing
`typednotes` confirmation. The workflow:

1. Builds/checks both Lean fleets and tests process supervision and configuration.
2. Checks the selected mode's secrets before cloud creation.
3. Builds all six services and assembles one Linux amd64 image.
4. Runs the real image against a disposable local PostgreSQL with the declared
   migrations and DML-only runtime credentials. It checks all six health paths,
   the workers' Lean installations, vault persistence across a restart and
   nonzero container exit when a required service dies.
5. Publishes the tested image as a unique CI tag and `latest` under
   `ghcr.io/typednotes/typednotes-lite`.
6. Passes that exact `@sha256:` image to the plan, apply and convergence check
   using `TYPEDNOTES_LITE_IMAGE`.

`GITHUB_TOKEN` needs `packages:write`, which the job declares. Like the other
service packages, **the GHCR package must be public** so Infra and Scaleway can
pull it. GitHub does not let `GITHUB_TOKEN` make a new package public: after the
first upload, set the package visibility to public and rerun Apply. The workflow
tests anonymous pull access before creating cloud resources. Pushes to main
still only run checks and a live plan; deployment remains a manual dispatch.
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
explicit immutable image; otherwise local runs resolve `latest` through Infra.

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

## Full-mode coexistence and the public domain

Lite uses marker `managed-by-infra=typednotes-lite`, namespace `typednotes-lite`
and database prefix `lite-typednotes-`. Full mode keeps marker `typednotes` and
its existing database prefixes. Offline guards verify that neither prefix claims
the other's databases. Applying or destroying one mode leaves the other alone.

Changing the dropdown does **not** migrate users, notebooks or encrypted vault
data from the other deployment. Existing full-mode operators should keep selecting
`full` until deliberately cutting over. A data move needs a separate reviewed
database/vault migration.

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
python3 -m unittest discover -s lite/tests -v
lake env lean --run scripts/lite-config.lean > /tmp/lite-config.json
python3 lite/check-image.py ghcr.io/typednotes/typednotes-lite:latest /tmp/lite-config.json
```

The last command needs Docker, downloads the declared public SQL sources, and
creates/removes only disposable Docker resources. It makes no cloud or paid
provider calls.
