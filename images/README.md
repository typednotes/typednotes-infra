# Combined images

The combined **Lite** and **Local** images package the six service repositories
(app, ledger, liaison, vault, Lode and Lun) into one application bundle:

- **Lite:** six application services, with separate application/vault PostgreSQL databases provisioned by Infra.
- **Local:** the exact Lite service bundle plus PostgreSQL 17 and persistent directory bootstrap. See [Local usage](../local/README.md).

Both variants are built and published by the
[typednotes-lite repository](https://github.com/typednotes/typednotes-lite)
as `ghcr.io/typednotes/typednotes-{lite,local}`. This repository no longer
builds them; it deploys the published images and reads their build metadata.

## Build manifest

Every image records its resolved sources in a build manifest (versions,
immutable commits, migration paths/checksums, worker dependencies, vault service
policies and a content-derived build ID), packaged inside the image and recorded
in its OCI config label `io.typednotes.build-manifest`. New builds declare
`runtimeVersion: 2`: split-vault configuration and standalone service
supervision. Cloud reconciliation refuses older bundles that would silently
ignore the separate vault URL or launch all services after promotion.

`images/releases.py` defines the manifest format and its validation;
`images/deployment.py` reads a published image's manifest from the registry.

The policy snapshot `images/vault-identities.json` is generated from the owning
Lean declaration (`scripts/lite-config.lean` exports it). CI checks exact
correspondence; update the snapshot when changing those rules.

```sh
lake env lean --run scripts/lite-config.lean | jq '{vaultIdentities}' > images/vault-identities.json
```

## Schema alignment during Lite deployment

Newest service tags can include new migrations. Lite plan/apply therefore cannot
keep using the old statically listed schema versions independently of the image.

For a live Lite or full-from-lite plan/apply, `Main.lean` calls `python3 -m images.deployment` to
resolve the image selector, select the Linux amd64 manifest, verify registry
content digests and read the built source manifest. The helper fetches SQL only
from those immutable service commits and checks it against the packaged hashes.
The resulting frozen image and exact SQL are supplied to Infra's four migration
histories. Infra retains its append-only validation, ordering and rollout gate.

Thus SQL and executable versions stay aligned even if service tags or image
`latest` change during reconciliation. A pinned `TYPEDNOTES_LITE_IMAGE` keeps the
same image across CI plan/apply/convergence. Registry metadata and immutable
source hosting remain trusted execution boundaries, alongside the image itself.

Offline `check` uses the declared baseline without networking. Teardown does not
need registry metadata. Full-from-lite requires an explicit Lite digest and runs
that same bundle for all six services. Independent `full` mode retains its explicitly reviewed schema releases.
Local startup instead consumes the SQL packaged inside its image without network
access. Both paths compare applied history rather than replaying changed SQL.

## Verification

```sh
python3 -m unittest discover -s images/tests -v
python3 -m unittest discover -s local/tests -v
python3 -m unittest discover -s lite/tests -v
LOCAL_POSTGRES_BIN=/path/to/postgresql/bin python3 -m unittest discover -s local/tests -v
LOCAL_POSTGRES_BIN=/path/to/postgresql/bin python3 -m unittest discover -s lite/tests -v
```
