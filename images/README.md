# Combined image builds

The [Bake graph](../lite/docker-bake.hcl) builds six service repositories once
per architecture and assembles two variants:

- **Lite:** six application services, with external PostgreSQL provisioned by Infra.
- **Local:** the exact Lite service bundle plus PostgreSQL 17 and persistent
  directory bootstrap. See [Local usage](../local/README.md).

## Newest service releases

`python3 -m images.releases --output .images` lists tags from all six repositories
and selects the greatest numeric stable `vMAJOR.MINOR.PATCH` for each. Prereleases,
aliases such as `latest`, and branch heads are excluded. Annotated tags are peeled
to the commit; lightweight tags already identify their commit. All versions are
resolved **once per build**, so both variants use the same source snapshot even
if another tag is published while they compile.
Tag discovery uses GitHub's paginated HTTPS API, independent of workstation Git
URL rewrites or SSH agents. CI supplies `GH_TOKEN`; set it locally too if making
enough resolver calls to reach GitHub's anonymous API limit.

The resolver reads each selected source archive without extracting untrusted
paths. It discovers the service's complete numbered SQL history, captures SQL
checksums, and records each worker's actual Lean/Linen dependencies. Outputs:

- `.images/manifest.json`: versions, immutable commits, migration paths/checksums,
  worker dependencies, vault service policies and a content-derived build ID.
- `.images/migrations/`: the SQL belonging to those commits.
- `.images/bake.json`: Bake overrides supplying peeled source commits, build
  arguments and identical manifest/provenance labels for both output images.

These generated files are ignored by Git and included selectively in the build
context. The manifest is packaged in each image and recorded in its OCI config
label `io.typednotes.build-manifest`.

The policy snapshot `images/vault-identities.json` is generated from the owning
Lean declaration (`scripts/lite-config.lean` exports it). CI checks exact
correspondence before publishing; update the snapshot when changing those rules.

```sh
lake env lean --run scripts/lite-config.lean | jq '{vaultIdentities}' > images/vault-identities.json
```

## Build commands

From the repository root:

```sh
scripts/build-images.sh          # resolve newest tags, build and load both images
scripts/build-images.sh --print  # resolve and inspect only; no builder needed
```

The wrapper disables GitHub Actions cache exporters outside CI. It selects the
native platform by default; override `PLATFORM`, `LITE_IMAGE` or `LOCAL_IMAGE` as
needed. To reuse an already resolved snapshot directly:

```sh
docker buildx bake -f lite/docker-bake.hcl -f .images/bake.json --print
```

Bare `docker-bake.hcl` has no source-ref defaults: it cannot silently fall back to
an old release or `main`. `lite/check-build.py` verifies that every source build,
both images' manifest labels and the selected platform match the snapshot.

## Automatic rebuilds

`.github/workflows/images.yml` supports:

- A scheduled tag check every fifteen minutes. GitHub schedules are best-effort,
  so this is an interval, not a maximum propagation latency.
- Pushes to the packaging/build files on `main`.
- A manual run, with `force` to refresh base images even for unchanged services.
- `repository_dispatch` with event type `service-version-updated`.
- A reusable workflow call from Lite Apply.

Scheduled detection needs no token in the service repositories and covers all
six services. It lists only tags when nothing changes. A cache of successfully
published snapshots avoids repeated source downloads/builds. Cache eviction
merely causes another build; image digests are always read from the registry.

For immediate notification, a release workflow/webhook can POST a repository
dispatch to this repository. The caller needs a GitHub App token or fine-grained
token with Contents write permission for `typednotes/typednotes-infra`; a service
repository's own `GITHUB_TOKEN` does not grant cross-repository access. Example:

```sh
gh api --method POST repos/typednotes/typednotes-infra/dispatches \
  -f event_type=service-version-updated
```

No sender is required for scheduled detection. Dispatch payloads are not used as
source refs or commands: the receiver independently resolves all newest tags.

Each rebuild uses native amd64 and arm64 runners. Each runner builds **both**
variants, tests Lite against disposable external PostgreSQL, and tests Local
through complete container recreation with its persisted database/key material.
Only after both architectures pass are multi-platform manifests published as
`ghcr.io/typednotes/typednotes-{lite,local}:latest` and `:build-BUILD_ID`.
The reusable workflow returns the exact image digests. Publication needs
`packages:write`, and both GHCR packages must be made public once for anonymous
pulls by users and Scaleway. Publication never applies cloud infrastructure.

The standalone publisher alone advances `latest`; reusable Apply calls consume
their own run-specific immutable digest. Their concurrency slots are separate
so a new scheduled check cannot cancel a queued manual Apply. Run-specific build
tags also prevent overlapping publishers from mixing architectures or returning
the other run's output. A cached snapshot's digest is read freshly from its
published build tag, including after a forced base-image refresh.

## Schema alignment during Lite deployment

Newest service tags can include new migrations. Lite plan/apply therefore cannot
keep using the old statically listed schema versions independently of the image.

For a live Lite plan/apply, `Main.lean` calls `python3 -m images.deployment` to
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
need registry metadata. Full mode retains its explicitly reviewed schema releases.
Local startup instead consumes the SQL packaged inside its image without network
access. Both paths compare applied history rather than replaying changed SQL.

## Verification

```sh
python3 -m unittest discover -s images/tests -v
python3 -m unittest discover -s local/tests -v
python3 -m unittest discover -s lite/tests -v
LOCAL_POSTGRES_BIN=/path/to/postgresql/bin python3 -m unittest discover -s local/tests -v
```

Set `LOCAL_RELEASE_BUNDLE=.images` as well to apply the real resolved service SQL
in the native PostgreSQL test. After building the images, CI runs:

```sh
python3 lite/check-image.py "$LITE_IMAGE" .images/manifest.json
python3 local/check-image.py "$LOCAL_IMAGE"
```
