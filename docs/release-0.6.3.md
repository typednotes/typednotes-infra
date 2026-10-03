# Typednotes-infra v0.6.3 (local declaration)

Adopts app v0.10.0's history through `0013_guided_workspace.sql`: atomic new-user
default org/project/preferences, reauthorization binding/revision and durable
actor-bound generation requests. Existing migration prefix, fleet shape and
service credential scopes are unchanged. Ledger remains v0.3.7.

Publish app v0.10.0, Lode v0.4.3 and Lun v0.3.2 source tags/images before manually reviewed
Plan/Apply; the app refuses older writers that do not acknowledge caller pins.
The Lun worker cache requires a new runtime image. Publish Linen v1.11.0 first,
then the dependent Lun image; Lun's exact SDK pin and immutable lock are prepared.
The declaration retains `latest` selectors resolved to digests; no resource or
credential expansion is needed for caching. The broker release remains v0.6.3.

Offline shape/source guards and the app's actual isolated SQL history were
verified. Release commits/tags are local; source publication and live cloud Apply
remain the user's actions.
