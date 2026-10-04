# Fleet v0.7.0 — project notes and stateless Lun

This local source release selects app source **0.11.0** through append-only
`0014_project_notes.sql` and `0015_durable_schedules.sql`. Ledger remains **0.3.7**
through 0003; broker/vault operation grants and resource declarations are unchanged.
The fleet's locked Linen **1.12.0** includes the warning-free TLS patch.

The matching services are **Lun 0.4.1** and **Lode 0.5.0** with
background checkout and bounded user questions. Source tags/images must be
published before live Plan/Apply. App/Lode/fleet release commits and annotated
tags are local and unpublished; existing tags remain immutable. No cloud operation
was performed.

The old runner's session API is removed. Drain active writers/runtime work and
pause old caller dispatch/input traffic for the coordinated migration. Apply the
real service SQL through 0015 before serving the new application, roll the matching
caller/runtime/writer, and confirm authority-retirement queue completion before
resuming dispatch. Inspect project model/grants and regenerate merged code;
old public links are revoked and secret origins remain protected.

Review [the app's rollout and trust boundaries](https://github.com/typednotes/typednotes/blob/main/docs/release-0.11.0.md)
and [scheduling ownership](https://github.com/typednotes/typednotes/blob/main/docs/scheduling-ownership.md).
`lake exe typednotes-infra check` is offline. Live Plan/Apply and Linux/container
verification remain operator/CI actions.
