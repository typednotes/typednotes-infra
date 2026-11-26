# Typednotes Lite runtime and storage helpers

Lite packages the Typednotes app, Ledger, Liaison, Secrets, Lode and Lun into
one application image, backed by separate application and vault PostgreSQL databases. The
combined image is built and published by the
[typednotes-lite repository](https://github.com/typednotes/typednotes-lite);
this directory holds the runtime supervisor and legacy-storage tooling that the
Lite deployment in this repository checks and operates against.
See [the deployment guide](../docs/lite.md) for CI, configuration, database
limitations and recovery, and [the metadata guide](../images/README.md) for the
build-manifest boundary.

## Runtime, storage and deployment responsibilities

- **[`runtime.py`](runtime.py)** supervises the six processes in Lite, or one
  selected service (`TYPEDNOTES_SERVICE`) per container after promotion.
- **[`Fleet/Shared.lean`](../Fleet/Shared.lean)** builds Lite and promoted full
  from one storage declaration and an explicit physical-name layout.
- **[`Fleet/Lite.lean`](../Fleet/Lite.lean)** and
  **[`Fleet/Promotion.lean`](../Fleet/Promotion.lean)** select the topology.
- **[`Fleet/Bundle.lean`](../Fleet/Bundle.lean)** shares bundle validation and
  migration conversion across those topologies.
- **[`Fleet/Topology.lean`](../Fleet/Topology.lean)** refuses Lite reconciliation
  or teardown after cloud resources indicate full/partial promotion.
- **[`storage.py`](storage.py)** copies and verifies a legacy single-DB vault
  before archiving the original table and migration history.
- **[`apply.yml`](../.github/workflows/apply.yml)** deploys the published
  image's immutable digest with the SQL identified by its build manifest.

The deployed image never builds anything at runtime. For the image build recipe
itself, see the typednotes-lite repository.

## Offline deployment validation tests

Run `python3 -m unittest discover -s lite/tests -p test_runtime.py -k DeploymentSecretTests -v`
from the repository root. These tests supply an example operator CIDR
so password checks reach the intended validation, and verify that full deployments
still reject a missing `OPERATOR_CIDRS`. No cloud resources are contacted.
