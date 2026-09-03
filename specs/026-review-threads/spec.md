---
id: "026-review-threads"
title: "Review threads: anchored comments, resolution state, and approvals as attestations"
status: approved
kind: "feature"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 1
depends_on:
  - "025-semantic-anchors"
establishes:
  - "crates/hqgit-domain/src/review.rs"
  - "crates/hqgit-domain/tests/review.rs"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  The review conversation as facts: a thread is opened on a change at a
  revision, optionally anchored (025), comments are posted with their
  bodies in the object store so they are erasable (constitution X), and
  resolution is a last-writer-wins register (constitution VII). Threads are
  re-anchored against every new revision, and a reviewer sees "moved" and
  "lost" rather than an orphaned comment. Approval is not a comment: it is
  a fact that references an Attestation (027) with the approval predicate,
  so "who approved which revision" is a signed, verifiable claim and never
  prose. This spec adds the ThreadView and ApprovalView folds and the pure
  builders the CLI (033) and the server (093) call.
---

# 026: Review threads

## 1. Purpose

Design §1.1 point 1: clone the repo, get the argument that produced it.
The argument is the review conversation, and in every incumbent it is rows
in someone else's database, anchored to lines that a rebase invalidates.
This spec makes the conversation facts in the ledger, anchored to syntax
(025), with bodies that can be erased without rewriting history and with
approvals that are attestations rather than text (constitution IX).

## 2. Territory

`review.rs` in `crates/hqgit-domain`: the `Thread`, `Comment`, and
`Approval` types, the `ThreadView` and `ApprovalView` folds, the
re-anchoring function, and the builders; plus `tests/review.rs`.
Additively: `lib.rs` re-exports and the typed decoding of the `anchor`
field in `facts.rs` (from the opaque `Value` spec 023 reserved to spec
025's `Anchor`).

## 3. Behavior

- **B-1 (`Thread`).** `Thread { id: ThreadId, change: ChangeId, anchor:
  Option<Anchor>, opened_at_revision: RevisionId, opened_by: Principal,
  opened_at: Hlc, resolved: LwwRegister<bool>, comments: Vec<CommentId>,
  warnings: Vec<ReviewWarning> }`. A thread with `anchor: None` is a
  change-level thread. `comments` is in total order (018).
- **B-2 (`Comment`).** `Comment { id: CommentId, thread: ThreadId, author:
  Principal, body: Cid, reply_to: Option<CommentId>, at: Hlc }`. `body` is
  a `Raw` object holding UTF-8 markdown; the fact carries only the
  commitment (constitution X). `comment_body(comment, store) ->
  Result<Resolved, Error>` returns spec 020's `Resolved::{Present(bytes),
  Erased(TombstoneRef), Missing}`; a renderer MUST show `Erased` as erased
  and never fail on it.
- **B-3 (resolution).** `review.thread_resolved` sets the `resolved`
  register at the fact's `Hlc`; concurrent resolve and unresolve converge
  by the register's rule. A comment posted on a resolved thread reopens
  nothing by itself (a fact is a fact) but is recorded with
  `ReviewWarning::CommentOnResolvedThread` so a UI can offer to reopen.
- **B-4 (re-anchoring).** `reanchor(thread: &Thread, tree: &Tree) ->
  Option<Resolution>` resolves the thread's anchor (025) against the tree
  of a revision; `None` for an unanchored thread. This is a pure
  content-derived computation, not fact-derived, so it lives outside the
  fold: the CLI (033) computes it on demand and the views projection (081)
  stores it per `(thread, revision)`. A `Lost` resolution never deletes a
  thread; the thread stays with its last resolvable revision named.
- **B-5 (`Approval`).** `Approval { attestation: AttestationId, change:
  ChangeId, revision: RevisionId, approver: Principal, at: Hlc }` folded
  from `review.approval_issued`. `ApprovalView::approvals_for(change) ->
  Vec<Approval>` and `approvals_for_revision(change, revision)`. An
  approval of a revision that is not the latest is `stale` in
  `ApprovalStatus { Current | Stale { latest: RevisionId } }`; staleness
  is a query over the ChangeView (024), never a fact. The fold records an
  approval whose `revision` the ChangeView does not know with
  `ReviewWarning::ApprovalForUnknownRevision`. Whether the referenced
  attestation exists, verifies, and carries the approval predicate is the
  trust plane's question (064); the view stores the reference.
- **B-6 (builders).** `open_thread(change, at_revision, anchor,
  opened_by, nonce) -> (ThreadId, DomainFact)`, `post_comment(thread,
  author, body_cid, reply_to, nonce) -> (CommentId, DomainFact)`,
  `set_resolved(thread, resolved) -> DomainFact`, `issue_approval(change,
  revision, attestation) -> DomainFact`. Pure; the caller stores the
  comment body object (013) before appending the fact, and refuses (in the
  CLI) a `reply_to` outside the thread; the fold records such a reply with
  `ReviewWarning::ReplyOutsideThread` rather than dropping it.
- **B-7 (queries).** `ThreadView::threads_for(change) -> Vec<&Thread>` in
  opening order, `thread(id)`, `comment(id)`, `unresolved_count(change)`.

## 4. Functional requirements

- **FR-001.** Tests: open, comment, reply, resolve, unresolve, and the
  register's convergence under two orders; every `ReviewWarning` variant;
  `comment_body` on present, erased (after a spec 020 tombstone), and
  missing objects; `reanchor` on the 025 fixtures giving `Exact`, `Moved`,
  `Text`, and `Lost`; approval status `Current` then `Stale` after a new
  revision; approval for an unknown revision.
- **FR-002.** A property test folds a random thread history through two
  permutations agreeing on total order and asserts equal views.
- **FR-003.** No function in `review.rs` reads a clock or performs I/O
  beyond the `ObjectStore` seam used by `comment_body`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked review` passes.
- **AC-2.** A fixture where a thread is opened on a Rust function, the
  function is moved by the next revision, and the comment body is then
  erased folds to: one thread, resolution `Moved` at revision 2, body
  `Erased`, and zero failures.

## 6. Out of scope

The attestation object itself and its verification (027, 064); rendering
and re-anchor storage (081, 095); suggested edits and batch review
submission (a later feature spec); notification (085).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked review
```
