# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28).
typednotes-infra gets linen only through `infra`; it moves to linen v1.6.1 by
moving `require infra` to v0.18.1 (infra's release that pins it). Each item
names where it comes from; re-check before acting.

## linen, through infra

- [ ] **Keep getting linen through infra — no direct `require linen`.** A direct
  pin would override infra's and run infra on a linen it was never tested with.
  Move linen by moving infra (bump the tag, `lake update infra`, read infra's
  `CHANGELOG.md`), as the README says.
- [ ] **Re-diff the native link-flag block against infra's on every infra
  bump.** Its header says "copied from infra v0.14.0"; only the comments differ
  from v0.18.x. Better: a CI check like infra's own `ci/check-lakefile-sync.sh`,
  so drift fails rather than waits for someone to notice. (S)

## CI

- [ ] **One composite action for the native deps.** The same `apt-get` line is
  in `plan.yml:21`, `apply.yml:46` and `destroy.yml:70` — the drift linen fixed
  for itself with `.github/actions/setup-native-deps`. (S)
- [ ] **Pin runners to `ubuntu-24.04`** (they use `ubuntu-latest`): linen ≥1.2.0
  audits its sealed DuckDB library with `nm` on every linking Linux build, and
  that audit has only been measured on 24.04. (XS)

## Workarounds that linen could remove

- [ ] **`SSL_CERT_FILE`** in `Fleet.lean:516` exists because linen's TLS uses
  only OpenSSL's compiled-in default paths (`linen/ffi/tls.c:553`); liaison,
  lun and lode set it too. A fallback in linen would drop all of them.
