---
id: "083-code-graph"
title: "Code graph: a cross-repository SCIP symbol projection keyed by tree"
status: approved
kind: "feature"
domain: "l5-projection"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 6
depends_on:
  - "080-projection-framework"
  - "025-semantic-anchors"
establishes:
  - "crates/hqgit-projection/src/codegraph/mod.rs"
  - "crates/hqgit-projection/src/codegraph/scip.rs"
  - "crates/hqgit-projection/src/codegraph/store.rs"
  - "crates/hqgit-projection/tests/codegraph.rs"
  - "crates/hqgit-projection/testdata/scip/"
extends:
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/lib.rs", nature: additive }
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/registry.rs", nature: additive }
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/Cargo.toml", nature: additive }
  # The `scip` protobuf bindings (and prost, if 070 has not yet added it) join the table.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
  # An index is evidence about a tree: it arrives under a registered predicate.
  - { spec: "027-attestation-primitive", unit: "crates/hqgit-domain/src/predicate.rs", nature: additive }
summary: >
  Design §1.1 point 6: there is no ecosystem graph, and the first half of
  one is a type-aware, cross-repository code index. This spec ingests SCIP
  indexes, produced per revision tree by external indexers and delivered
  as attestations under the predicate hqgit/code-index/v1, into a
  projection keyed by (namespace, tree cid): symbols with a stable
  content-derived id, definitions, references, and relationships, in one
  shared SQLite file that spans repositories so a reference in one
  namespace resolves to a definition in another. It is the one legitimately
  centralized component (thesis §8) and therefore the most carefully
  non-authoritative: nothing originates here, every answer names the tree
  and ledger entry it was computed from, and any namespace's rows can be
  dropped and rebuilt from its own ledger alone.
---

# 083: Code graph

## 1. Purpose

Thesis §4.7 places the SCIP-class cross-repo index in L5 and names it,
with the package graph (084), the one component that is legitimately
centralized. Thesis §8 lists it as a standing risk for exactly that
reason: a central index is where authority leaks in. This spec builds the
index inside the 080 framework so the leak is impossible by construction:
indexes enter only as evidence appended to a repository's ledger, the
store answers "as of" a tree and an entry, and a namespace's rows are a
pure function of that namespace's facts. Anchors (025) are the bridge from
a review location to the symbols under it.

## 2. Territory

The `codegraph` module of `hqgit-projection`: `mod.rs` (the projection,
symbol ids, query API), `scip.rs` (decoding and normalizing a SCIP
index), `store.rs` (the shared cross-namespace storage), `tests/codegraph.rs`,
and fixture indexes with expectations under `testdata/scip/`. Additively:
the `lib.rs` re-exports, the `register_all` entry, the crate manifest, the
workspace dependency table (`scip`, pinned exact, and `prost`), and the
`hqgit/code-index/v1` claim validator in 027's registry. Producing indexes
is not here (§6).

## 3. Behavior

- **B-1 (the predicate).** `PredicateType("hqgit/code-index/v1")` is
  registered with claim schema `{ format: "scip", index: Cid (codec Raw),
  tree: Cid (codec DagCbor), language: String, indexer: String,
  indexer_version: String }`; the attestation's `subject` MUST equal
  `tree.hash`. The issuer is whoever ran the indexer (a Service under 075
  later, a human running `hq attest` today); the projection records the
  issuer and never judges it (verification is 064's, rendered by 081 B-3).
- **B-2 (ingestion).** `CodeGraphProjection { namespace: Hash }` (`NAME =
  "codegraph"`, `SCHEMA_VERSION = 1`) applies `attestation.issued` facts
  whose predicate is B-1: it reads the claim object and the Raw index from
  the object store, decodes the index with the `scip` crate
  (`scip::types::Index`), and writes B-4's rows in the same transaction as
  the checkpoint. An index over 256 MiB, a decode failure, a claim whose
  `subject` disagrees with `tree`, or more than 8,000,000 occurrences is
  recorded with `status = 'rejected'` and a `reason`; an absent object is
  `'missing'`; the fold never fails on an index. Every other fact kind is
  ignored by this projection.
- **B-3 (symbol ids).** SCIP symbols are `<scheme> <manager> <package>
  <version> <descriptors>` or `local <id>`. `SymbolId = Hash::of(
  b"hqgit/codegraph/symbol/v1" || 0x00 || symbol_with_version_dot)` where
  the version field is replaced by `.` so the same item at two versions
  shares an id and the observed version is stored beside each occurrence.
  A local symbol's id is `Hash::of(b"hqgit/codegraph/local/v1" || 0x00 ||
  namespace || tree cid hash || path || 0x00 || symbol)` and is flagged
  `local = 1`. `scip.rs` exposes `parse_symbol(&str) -> Result<ScipSymbol,
  Error>` and the role bitmask constants `DEFINITION = 0x1`, `IMPORT =
  0x2`, `WRITE = 0x4`, `READ = 0x8`, `GENERATED = 0x10`, `TEST = 0x20`,
  `FORWARD_DEFINITION = 0x40`. A three-element SCIP range expands to
  `(line, start, line, end)`; all positions are 0-based as SCIP records.
- **B-4 (tables).** `code_indexes(namespace TEXT, tree_cid TEXT,
  index_cid TEXT, attestation_id TEXT NOT NULL, issuer TEXT NOT NULL,
  language TEXT NOT NULL, indexer TEXT NOT NULL, indexer_version TEXT NOT
  NULL, ordinal INTEGER NOT NULL, status TEXT NOT NULL CHECK (status IN
  ('ingested','missing','rejected','erased')), reason TEXT, documents
  INTEGER NOT NULL DEFAULT 0, symbols INTEGER NOT NULL DEFAULT 0,
  occurrences INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (namespace,
  tree_cid, index_cid))`; `code_symbols(symbol_id TEXT PRIMARY KEY,
  scheme TEXT NOT NULL, manager TEXT NOT NULL, package TEXT NOT NULL,
  descriptors TEXT NOT NULL, display_name TEXT, kind INTEGER NOT NULL
  DEFAULT 0, local INTEGER NOT NULL DEFAULT 0)`;
  `code_definitions(namespace, tree_cid, index_cid, symbol_id, path TEXT,
  start_line INTEGER, start_col INTEGER, end_line INTEGER, end_col
  INTEGER, version TEXT, roles INTEGER NOT NULL, PRIMARY KEY (namespace,
  tree_cid, index_cid, symbol_id, path, start_line, start_col))`;
  `code_references` with the same columns and `PRIMARY KEY (namespace,
  tree_cid, index_cid, path, start_line, start_col, symbol_id)`;
  `code_relationships(namespace, tree_cid, index_cid, symbol_id,
  related_symbol_id, relation TEXT NOT NULL CHECK (relation IN
  ('reference','implementation','type-definition','definition')), PRIMARY
  KEY (namespace, tree_cid, index_cid, symbol_id, related_symbol_id,
  relation))`. Indexes on `code_definitions(symbol_id)`,
  `code_references(symbol_id)`, and `(namespace, tree_cid, path)` on both.
  Every write is an upsert keyed by the primary key (080 B-4).
- **B-5 (shared store).** `store.rs` provides `SharedStorage::open(path)
  -> SharedStorage`, an implementation of 080's `ProjectionStorage` over
  one SQLite file that many namespaces share. Its checkpoint row name is
  `<NAME>@<namespace-hex>` so each repository resumes independently, and
  `reset` for one namespace deletes only rows `WHERE namespace = ?` plus
  `code_symbols` rows no definition or reference still names. The CLI
  passes `<repo>/.hq/projections/codegraph.db` (a one-namespace file);
  the server passes `<data>/projections/codegraph.db`. The file is never
  attached to another projection's database and no projection other than
  084 reads it; the operator may delete it and rebuild every namespace.
- **B-6 (queries).** `Scope::{Tree { namespace, tree_cid }, Namespace(Hash),
  All}`; for `Namespace` and `All` the answer comes from each namespace's
  latest ingested index (greatest `ordinal`), and every returned
  `Location { namespace, tree_cid, path, range: Range { start_line,
  start_col, end_line, end_col }, roles: u32, version: Option<String> }`
  names its tree. `definitions(store, symbol, scope) -> AsOf<Vec<Location>>`;
  `references(store, symbol, scope, roles: Option<u32>, cursor, limit) ->
  AsOf<Page<Location>>` with cursor `(namespace, tree_cid, path,
  start_line, start_col)` and that ordering; `relationships(store, symbol,
  relation, scope)`; `symbol_by_scip(store, &str) -> AsOf<Option<SymbolRow>>`;
  `latest_indexed_tree(store, namespace) -> AsOf<Option<Cid>>`. Local
  symbols are answered only under `Scope::Tree` and never cross a
  namespace. `symbols_in(store, objects, namespace, tree_cid, anchor:
  &Anchor) -> AsOf<SymbolsAt>` resolves the anchor against the tree's file
  through 025 `resolve`, converts the byte range to lines with 025
  `line_range`, and returns `SymbolsAt::Found { resolution, occurrences }`
  for occurrences intersecting the range, `Unindexed` when the tree has no
  ingested index, `Unavailable` when the object store lacks the file, or
  `Lost` when the anchor does not resolve.
- **B-7 (erasure).** `on_tombstone(cid)` deletes every definition,
  reference, and relationship row whose `index_cid` is that cid and sets
  the `code_indexes` row to `'erased'` (constitution X): the store never
  keeps content an erased index carried, and never copies source text.
- **B-8 (no ambient input).** No clock, no `HashMap`, no floats; ranges
  and counts are integers. Rows are a pure function of the namespace's
  facts and the object store, so a rebuild is byte-identical (080 FR-002).

## 4. Functional requirements

- **FR-001.** Fixtures under `testdata/scip/`: `rust-two-crates/{a,b}.scip`
  (crate `b` references a symbol crate `a` defines), `ts-single/index.scip`,
  `local-only.scip`, `malformed.scip`, `symbol-ids.json` (frozen SCIP
  symbol to `SymbolId` vectors, including a local one), and `expected/`
  JSON per query.
- **FR-002.** Tests cover: ingest `a.scip` and query its definitions;
  `b.scip` under a second namespace resolves references to `a`'s symbol
  under `Scope::All`; a local symbol is invisible outside its tree; a
  malformed and an oversized index are `'rejected'` with a reason and the
  next ordinal still applies; a missing object is `'missing'`; a
  tombstone on the index cid erases its rows; `Namespace` scope answers
  from the newest index after two are ingested; `symbols_in` over a 025
  fixture anchor returns the occurrence at the anchored node and
  `Unindexed` before ingestion; two namespaces in one file checkpoint
  independently and a reset of one leaves the other's rows; rebuild equals
  incremental for both.
- **FR-003.** The symbol id vectors are frozen (constitution VIII): a
  change to `symbol-ids.json` is an amendment to this spec.
- **FR-004.** The `scip` crate is pinned exact in `[workspace.dependencies]`
  and a test asserts `Cargo.lock` agrees.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-projection --locked codegraph` passes.
- **AC-2.** With `a.scip` attested into one repository and `b.scip` into
  another, both projected into one shared file, `references` for the
  shared symbol under `Scope::All` returns `b`'s call site naming `b`'s
  namespace and tree, and `definitions` returns `a`'s.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Running indexers (a 075 build target that emits the B-1 attestation is a
later feature spec); the package dependency graph and impact analysis
(084); serving queries over the API (093); code search (082 indexes prose,
not symbols); languages beyond what an external SCIP indexer supports.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-projection --locked codegraph
```
