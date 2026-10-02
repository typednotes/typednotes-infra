# Typednotes-infra v0.6.2

Adopts app v0.9.1's history through `0012_tenant_deletion.sql` and ledger v0.3.7's
history through `0003_tenant_deletion.sql`. Both are append-only. Parent/child
history ordering still derives from SQL; containers wait for their declared
histories before rolling out. App deletion refuses older restrictive ledger FKs
before credential cleanup. No new container, credential scope or SDK pin is added.

Publish the new source tags and successful service images before this declaration's
read-only Plan and manual Apply. The local source release changes no live cloud
resources; deployment remains a manually reviewed action. All prior source tags remain immutable.
Images continue to resolve `latest` into fixed digests; other service selectors
and migration refs remain unchanged.

Offline checks verify both updated histories' IDs and source URLs. The app
fixture applies actual SQL to disposable PostgreSQL and verifies owner checks,
organization/account cascades, ownership transfer, defaults, scoped external
cleanup, retries after compute-role removal and concurrent account deletion.
