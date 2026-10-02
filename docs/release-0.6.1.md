# Typednotes-infra v0.6.1

Adopts Typednotes v0.9.0's complete SQL history through 0011 before rolling out
the app. The three new append-only migrations implement future duplicate-provider
creation refusal, per-user default workspaces, and public share/visitor records.
Historical connection rows are preserved; new insertions are guarded even when
older duplicates exist. No production reset was required in local verification.

Required service release images: Liaison v0.6.3 (bounded repository paging and
verified metadata selection), Lun v0.3.1 (proof-checked public pure sessions),
Typednotes v0.9.0 (selectors, setup, sharing). Lode and Linen pins are unchanged.
The fleet continues to resolve latest selectors into immutable digests.

The user can push branch and new release tags together in their repositories.
Wait for each main CI and image publication before this fleet's live Plan/Apply.
App v0.9.0 must exist remotely so the declaration can fetch its migration files.
Push this declaration's main branch and, optionally, its source release tag, then
run the existing manually dispatched Apply. No automatic cloud apply is added.

Offline fleet build/checks and all eleven migrations were exercised locally;
the actual app/broker/browser/compiled-runner fixtures use disposable databases.
Public share execution has no credential grants or external effects and does not
mutate the author's notebook input log. Visitor sessions expire after 30 minutes.
