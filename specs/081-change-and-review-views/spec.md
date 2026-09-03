---
id: "081-change-and-review-views"
title: "Change and review views: the SQL read models for changes, threads, attestations, stacks"
status: approved
kind: "feature"
domain: "l5-projection"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 6
depends_on:
  - "080-projection-framework"
  - "026-review-threads"
  - "027-attestation-primitive"
  - "050-stacked-changes"
establishes:
  - "crates/hqgit-projection/src/views/mod.rs"
  - "crates/hqgit-projection/src/views/changes.rs"
  - "crates/hqgit-projection/src/views/threads.rs"
  - "crates/hqgit-projection/src/views/attestations.rs"
  - "crates/hqgit-projection/src/views/stacks.rs"
  - "crates/hqgit-projection/tests/views.rs"
  - "crates/hqgit-projection/testdata/views/"
extends:
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/lib.rs", nature: additive }
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/registry.rs", nature: additive }
summary: >
  The four read models the API (093) and the review UI (095) query: changes
  with their revisions and stack position, threads with their per-revision
  anchor resolution (exact, moved, text, lost), attestations by subject and
  predicate with a verification column a composing binary fills, and
  stacks. Each is a Projection instance (080) with its own schema version,
  every write is an upsert keyed by a fact-derived id so replay is
  idempotent, comment bodies stay in the object store as a Cid plus an
  erased flag, and every query answers as of a ledger entry. Nothing here
  is authority: a rebuild from zero reproduces every row.
---

# 081: Change and review views

## 1. Purpose

The domain folds of 024, 026, 027, and 050 answer questions one change at
a time from the ledger. A list of open changes sorted by activity, the
threads of a change re-anchored against its latest revision, or every
attestation over a subject are set queries, and answering them by folding
the whole ledger on each request is the wrong shape. This spec materializes
those folds as SQL tables through the 080 framework, keeping the constraint
that makes them safe (constitution VI): the tables are disposable, and the
answers carry the ledger entry they were computed from.

## 2. Territory

The `views` module of `hqgit-projection`: `changes.rs`, `threads.rs`,
`attestations.rs`, `stacks.rs`, their `mod.rs` with the shared query
types, the `tests/views.rs` suite, and the fixture ledgers under
`testdata/views/`. Additively: the `lib.rs` re-exports and the
`register_all` entry in `registry.rs`. The view of issues is a later spec
(§6); search is 082.

## 3. Behavior

- **B-1 (changes).** `ChangesProjection` (`NAME = "changes"`,
  `SCHEMA_VERSION = 1`) owns `changes(change_id TEXT PRIMARY KEY,
  opened_by TEXT NOT NULL, title TEXT, state TEXT NOT NULL CHECK (state IN
  ('open','merged','abandoned')), latest_revision INTEGER NOT NULL,
  latest_revision_id TEXT, latest_tree TEXT, opened_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, stack_id TEXT, stack_position INTEGER)` and
  `revisions(revision_id TEXT PRIMARY KEY, change_id TEXT NOT NULL,
  number INTEGER NOT NULL, tree_cid TEXT NOT NULL, base_cid TEXT NOT NULL,
  parent_revision_id TEXT, submitted_by TEXT NOT NULL, at TEXT NOT NULL,
  git_commit TEXT, UNIQUE(change_id, number))`, folded from the 024 facts
  (`change.opened`, `change.revision_submitted`, `change.abandoned`, and
  the merge facts 076 appends). `title` and `state` follow the 024
  `ChangeView` LWW rules, replayed here on the fact's `Hlc`; `updated_at`
  is the greatest `Hlc` of any fact about the change or its threads. All
  `Hlc` columns use the 080 B-9 fixed-width text.
- **B-2 (threads).** `ThreadsProjection` (`NAME = "threads"`,
  `SCHEMA_VERSION = 1`) owns `threads(thread_id TEXT PRIMARY KEY,
  change_id TEXT NOT NULL, opened_at_revision TEXT, anchor_path TEXT,
  anchor_json TEXT, resolved INTEGER NOT NULL DEFAULT 0, resolved_at
  TEXT)`, `comments(comment_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  author TEXT NOT NULL, body_cid TEXT NOT NULL, at TEXT NOT NULL, erased
  INTEGER NOT NULL DEFAULT 0)`, and `thread_positions(thread_id TEXT,
  revision_id TEXT, resolution TEXT NOT NULL CHECK (resolution IN
  ('exact','moved','text','lost','unavailable')), start_line INTEGER,
  end_line INTEGER, PRIMARY KEY (thread_id, revision_id))`. On every
  `change.revision_submitted` the projection re-resolves each open
  anchored thread of that change against the new revision's tree through
  025 `resolve`, reading the tree from the object store; a tree the store
  does not hold yields `unavailable`, never a guess. Comment bodies are
  never copied: `body_cid` plus `erased`, and `on_tombstone(cid)` sets
  `erased = 1` for every comment whose `body_cid` matches.
- **B-3 (attestations).** `AttestationsProjection` (`NAME =
  "attestations"`, `SCHEMA_VERSION = 1`) owns `attestations(attestation_id
  TEXT PRIMARY KEY, subject TEXT NOT NULL, predicate TEXT NOT NULL, issuer
  TEXT NOT NULL, issuer_kind TEXT NOT NULL CHECK (issuer_kind IN
  ('human','agent','service','org')), issuer_key TEXT NOT NULL, claim_cid
  TEXT NOT NULL, at TEXT NOT NULL, entry_hash TEXT NOT NULL, verification
  TEXT NOT NULL DEFAULT 'unverified' CHECK (verification IN
  ('unverified','ok','failed')), verification_reason TEXT, verified_at
  TEXT)` with indexes on `(subject)` and `(predicate, subject)`, folded
  from `attestation.issued` (027). The projection crate does not depend on
  `hqgit-trust`; the composing binary (CLI or server) that holds a 064
  verifier calls `record_verification(tx, attestation_id, verdict, at)`,
  the one write this view accepts from outside the fold, and a rebuild
  resets the column to `unverified` (verification is re-derived, never
  trusted from a prior table).
- **B-4 (stacks).** `StacksProjection` (`NAME = "stacks"`,
  `SCHEMA_VERSION = 1`) owns `stacks(stack_id TEXT PRIMARY KEY,
  root_change_id TEXT NOT NULL, depth INTEGER NOT NULL, state TEXT NOT
  NULL CHECK (state IN ('valid','invalid')), reason TEXT)` and
  `stack_members(stack_id TEXT, change_id TEXT, position INTEGER,
  depends_on_change_id TEXT, PRIMARY KEY (stack_id, change_id))`, folded
  from `change.depends_on` (050) with `stack_id = Hash::of` of the sorted
  member set's root; a dependency cycle 050 refuses is recorded as
  `invalid` with the cycle path in `reason` rather than omitted. The
  `changes` view's `stack_id` and `stack_position` are filled from this
  view's rows in the same fold (both projections run in one runner pass
  when registered together; each remains rebuildable alone).
- **B-5 (queries).** `mod.rs` defines `ChangesQuery { state:
  Option<ChangeState>, author: Option<Principal>, cursor: Option<PageCursor>,
  limit: u32 }` and the functions `list_changes(store, q) ->
  AsOf<Page<ChangeRow>>`, `change_detail(store, id) ->
  AsOf<Option<ChangeDetail>>` (change, revisions, stack position),
  `threads_for(store, change, revision) -> AsOf<Vec<ThreadRow>>` with the
  position for that revision, `attestations_for(store, subject) ->
  AsOf<Vec<AttestationRow>>`, `attestations_by_predicate(store, predicate,
  cursor, limit)`, and `stack_of(store, change) -> AsOf<Option<StackRow>>`.
  `PageCursor` is `(updated_at, change_id)`, opaque to callers, and
  ordering is `updated_at DESC, change_id ASC` so pages are stable across
  refreshes.
- **B-6 (idempotent apply).** Every write is `INSERT ... ON CONFLICT DO
  UPDATE` keyed by the fact-derived id (023 `ids.rs`), so re-applying an
  ordinal after a crash (080 B-4) changes no row.
- **B-7 (as of).** Every function of B-5 returns `AsOf<T>` carrying the
  view's cursor; the composing binary renders 080 B-5's line.

## 4. Functional requirements

- **FR-001.** Each view is a separate `Projection` registered by name; a
  rebuild of one never touches another's database.
- **FR-002.** Tests cover, from the fixture ledgers: expected rows for a
  change with three revisions and an abandonment; thread positions across
  a revision that moves the anchored function and one that deletes it
  (`moved`, then `lost`); a tombstoned comment body flagged `erased`;
  attestation rows per subject and predicate with `record_verification`
  round trip and reset on rebuild; a valid stack and an invalid (cyclic)
  one; pagination stability across two pages with an insert between them;
  applying one ordinal twice yields the same dump.
- **FR-003.** Rebuild equivalence: for every fixture, the incremental dump
  equals the rebuild-from-zero dump (080 FR-002's check, run per view).
- **FR-004.** No comment body text is stored in any table (a test greps
  the dump for a fixture body string and asserts absence).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-projection --locked views` passes.
- **AC-2.** On the offline-review fixture of 033, `hq projection rebuild
  --all` followed by `list_changes` through the crate returns the change
  with `latest_revision` equal to the revision count and every thread
  positioned for the latest revision.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Issue read models (a later feature spec adds `views/issues.rs`), full-text
search (082), feeds (085), serving these views over the API (093), and the
review UI (095). Verification itself is 064; this spec only records its
verdict.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-projection --locked views
```
