---
id: "082-search-index"
title: "Search index: a tantivy projection over changes, comments, issues, and attestations"
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
establishes:
  - "crates/hqgit-projection/src/search.rs"
  - "crates/hqgit-projection/tests/search.rs"
extends:
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/lib.rs", nature: additive }
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/registry.rs", nature: additive }
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Full-text search as one more disposable projection: a tantivy index over
  change titles, comment bodies resolved from the object store, issue
  fields, and attestation predicates, keyed by stable document ids so
  replay is idempotent, with erased bodies never indexed and removed on
  tombstone, quarantine documents excluded by default, and a query API
  whose pages carry the ledger cursor they were computed from. Because
  tantivy is not SQLite, this spec fixes the commit ordering that keeps the
  index crash-consistent with the 080 checkpoint. Rebuild wipes the
  directory; nothing here is authority.
---

# 082: Search index

## 1. Purpose

Thesis §4.7 names search as a projection; constitution VI says it must
therefore be rebuildable from zero and never read as authority. Search is
also where the erasure rule (constitution X) is easiest to break by
accident: a copied comment body in an inverted index outlives the blob it
came from. This spec builds the index inside the 080 framework, resolves
every body from the object store at apply time, and makes the tombstone
hook delete by content id, so the search surface forgets exactly when the
ledger does.

## 2. Territory

`search.rs` in `hqgit-projection` (the `SearchProjection`, its schema, the
commit discipline, and the query API) and `tests/search.rs`. Additively:
the `lib.rs` re-export, the `register_all` entry, the crate manifest
(tantivy), and the workspace dependency table. A CLI verb is not in this
spec (§6).

## 3. Behavior

- **B-1 (the projection).** `SearchProjection` (`NAME = "search"`,
  `SCHEMA_VERSION = 1`) keeps a tantivy index directory at
  `<repo>/.hq/projections/search/index/` and its 080 checkpoint in the
  ordinary `search.db` SQLite file. Because the index is not inside the
  SQLite transaction, `apply` MUST order its effects: tantivy writer
  commit first, then the checkpoint commit. A crash between the two
  replays the ordinal; every document is keyed by a stable `doc_id`
  (B-2) and re-indexing is delete-by-term then add, so the replay is
  idempotent.
- **B-2 (schema).** Fields: `doc_id` (STRING, stored, indexed as a single
  term: `<kind>:<id>`), `kind` (STRING, one of `change`, `comment`,
  `issue`, `attestation`), `subject_id` (STRING: the change, issue, or
  attestation subject), `change_id` (STRING, optional), `namespace`
  (STRING), `title` (TEXT, default tokenizer), `body` (TEXT), `predicate`
  (STRING), `author` (STRING), `at` (STRING fast field in the 080 B-9
  fixed-width form), `ordinal` (U64 fast field). Stored fields are `doc_id`,
  `kind`, `subject_id`, `change_id`, `namespace`, `title`, `predicate`,
  `author`, `at`, `ordinal`; `body` is indexed but not stored (the object
  store is the source of the text).
- **B-3 (content resolution).** For `review.comment_posted` the body is
  read from the object store by `Cid` at apply time; a `FactView::Erased`
  or `Missing` body is never indexed and the document is written with an
  empty `body`. `on_tombstone(cid)` deletes every document whose indexed
  body came from that `Cid` (the projection keeps a `body_cids(doc_id
  TEXT PRIMARY KEY, body_cid TEXT)` table in `search.db` for that
  reverse lookup) and re-adds the document without a body.
- **B-4 (what is indexed).** `change.opened` and title changes index the
  change (`title`); `review.comment_posted` indexes the comment (`body`,
  `change_id`); `issue.opened` and `issue.field_set` index the issue
  (`title`, `body` from the description field); `attestation.issued`
  indexes the attestation (`predicate`, `subject_id`, `author`). Facts in
  the quarantine namespace (021) are indexed with `namespace` set and are
  excluded by default queries (B-5).
- **B-5 (query API).** `search(store, q: &str, filter: SearchFilter {
  kinds: Vec<Kind>, namespaces: Vec<Namespace> (empty means main only),
  since_ordinal: Option<u64> }, mode: SearchMode::{Relevance, Recent},
  cursor: Option<SearchCursor>, limit: u32) -> Result<AsOf<SearchPage>,
  Error>`. `Recent` orders by `(ordinal DESC, doc_id ASC)` and its cursor
  is `(ordinal, doc_id)`. `Relevance` orders by BM25 with ties broken by
  `(ordinal DESC, doc_id ASC)` and its cursor is the offset within the
  same query string; a cursor from a different query is
  `Error::Validation`. Results expose rank position, never the float
  score: floats never leave tantivy (constitution VIII applies to hashed
  paths; here it is defense in depth). A query string that fails to parse
  is `Error::Parse`.
- **B-6 (disposable).** `reset` deletes the index directory and the
  `body_cids` table; `rebuild` re-indexes from ordinal zero and yields an
  index whose `Recent` results are identical to the incremental one.
- **B-7 (bounds).** Indexed text per document is capped at 1 MiB (a
  longer body is truncated and the document flagged `truncated` in a
  stored boolean field); the index writer heap is a constant in the
  module.

## 4. Functional requirements

- **FR-001.** Tests cover: index a change, a comment, an issue, and an
  attestation from a fixture ledger and find each by a distinguishing
  term; a tombstoned comment body is unfindable and the document still
  exists without a body; a quarantine document is excluded by default and
  included when its namespace is named; `Recent` pagination across two
  pages is stable; `Relevance` cursor reuse across query strings is
  refused; applying one ordinal twice leaves one document; rebuild equals
  incremental for `Recent` results.
- **FR-002.** The crash-ordering test simulates a failure after the
  tantivy commit and before the checkpoint commit and asserts the replay
  leaves exactly one document per id.
- **FR-003.** No comment body text is stored in `search.db` or in a
  tantivy stored field (a test reads the stored fields of every document
  and asserts `body` is absent).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-projection --locked search` passes.
- **AC-2.** On the 033 offline-review fixture, a query for a word that
  appears only in one comment returns that comment's `doc_id`, and after
  `hq` erases that comment's body (020) the same query returns nothing.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

An `hq search` CLI verb and the API route (093 exposes the query through
the Connect surface and the CLI client), highlighting and snippets,
search over code (083), and cross-repository search (each repository's
index is local; a server that wants federated search queries each).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-projection --locked search
```
