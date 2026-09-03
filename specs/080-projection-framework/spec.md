---
id: "080-projection-framework"
title: "Projection framework: disposable read models folded from the total order"
status: approved
kind: "kernel"
domain: "l5-projection"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 6
depends_on:
  - "021-local-repository"
  - "032-cli-skeleton"
establishes:
  - "crates/hqgit-projection/Cargo.toml"
  - "crates/hqgit-projection/src/lib.rs"
  - "crates/hqgit-projection/src/projection.rs"
  - "crates/hqgit-projection/src/runner.rs"
  - "crates/hqgit-projection/src/sqlite.rs"
  - "crates/hqgit-projection/src/checkpoint.rs"
  - "crates/hqgit-projection/src/registry.rs"
  - "crates/hqgit-projection/tests/"
  - "crates/hqgit-cli/src/cmd_projection.rs"
extends:
  # The `hq projection` verb rides in the CLI 032 founded.
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/Cargo.toml", nature: additive }
  # rusqlite (bundled) joins the shared dependency table.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Constitution VI in code: every index, timeline, queue, and dashboard is a
  projection that can be rebuilt from zero, and no projection is ever read
  as authority. This spec founds hqgit-projection: the Projection trait, a
  runner that folds the ledger in the deterministic total order (018) from
  a crash-consistent checkpoint, SQLite-backed storage under .hq/projections
  where the apply and the checkpoint commit in one transaction, a registry
  that later specs (081 to 085) plug their read models into, the rule that
  every read answers "as of entry N", the rule that erased payloads render
  as erased, and the `hq projection` verbs to inspect and rebuild. It owns
  no concrete view.
---

# 080: Projection framework

## 1. Purpose

Thesis §3: canonical state is the signed DAG; everything else is derived
and must be rebuildable from zero. Thesis §4.7 places projections in L5,
the disposable layer, and constitution XIII forbids them from writing
authoritatively. Holding that line is a mechanism, not a habit: this spec
is the one place a read model is allowed to be built, the one fold that
feeds it, and the one checkpoint that says how far it has read. Specs 081
through 085 are instances of the trait defined here; the API (093) and the
UI (095) query them and repeat, on every answer, which ledger entry the
answer is projected as of.

## 2. Territory

`crates/hqgit-projection` as founded here: the manifest, `lib.rs`,
`projection.rs` (the trait and the fold step types), `runner.rs` (the fold
driver), `sqlite.rs` (the storage seam and its SQLite implementation),
`checkpoint.rs` (the cursor), `registry.rs` (named projections by
factory), and the `tests/` subtree. The `hq projection` verb lives in
`cmd_projection.rs` and extends the CLI frame of 032. The crate depends on
`hqgit-types`, `hqgit-object`, `hqgit-ledger`, and `hqgit-domain` only,
and never on `hqgit-cli` or `hqgit-server`.

## 3. Behavior

- **B-1 (the trait).** `trait Projection { const NAME: &'static str;
  const SCHEMA_VERSION: u32; fn init(&mut self, tx: &mut Tx) ->
  Result<(), Error>; fn apply(&mut self, tx: &mut Tx, step: &FoldStep) ->
  Result<(), Error>; fn on_tombstone(&mut self, tx: &mut Tx, target: &Cid)
  -> Result<(), Error>; fn reset(&mut self, tx: &mut Tx) -> Result<(),
  Error>; }`. `NAME` matches `^[a-z][a-z0-9-]*$` and names the storage
  file. `FoldStep { ordinal: u64, entry_hash: EntryHash, entry: Entry,
  fact: FactView, cursor: Cursor }` where `FactView` is `Present(FactEnvelope)
  | Opaque { kind: FactKind, bytes: Vec<u8> } | Erased { target: Cid } |
  Missing { target: Cid }` (spec 020 `resolve_payload` mapped one to one;
  `Opaque` is a fact kind the 019 registry does not know, passed through
  and counted, never dropped).
- **B-2 (the runner).** `Runner::new(entries: &dyn EntryReader, objects:
  &dyn ObjectStore, registry: &FactRegistry, storage: &dyn
  ProjectionStorage)`; `run<P: Projection>(&self, p: &mut P) ->
  Result<RunReport, Error>` reads the checkpoint (B-3), iterates
  `order_from(cursor)` (018) over the ledger, resolves each payload (020),
  decodes it through the registry, and calls `apply` once per entry inside
  one storage transaction that also writes the new checkpoint. `rebuild`
  is `reset` followed by `run` from ordinal zero in one call. `RunReport {
  name, from_ordinal, to_ordinal, applied, opaque, erased, missing,
  reset_reason: Option<String> }`.
- **B-3 (checkpoint).** `Cursor { ordinal: u64, entry: EntryHash,
  heads_hash: Hash }` where `heads_hash` is `Hash::of` of the sorted head
  set at the time of the step. Stored in the projection's own storage in
  table `_hq_checkpoint(name TEXT PRIMARY KEY, schema_version INTEGER,
  ordinal INTEGER, entry_hash BLOB, heads_hash BLOB)`. On open, a stored
  `schema_version` different from `SCHEMA_VERSION` MUST trigger `reset`
  (the projection is disposable; a schema bump is the migration), recorded
  in `reset_reason`. A stored `entry_hash` the ledger does not contain is
  `Error::Stale` and the CLI's advice is `rebuild`; the runner never guesses
  a resume point.
- **B-4 (storage).** `trait ProjectionStorage { fn open(&self, name: &str)
  -> Result<Box<dyn Store>, Error>; }` and `trait Store { fn begin(&mut
  self) -> Result<Tx, Error>; }` with `Tx` exposing `execute`, `query`, and
  `commit`. `SqliteStorage` keeps one database per projection at
  `<repo>/.hq/projections/<name>.db` (rusqlite, bundled SQLite, WAL mode,
  `synchronous=FULL`). `MemoryStorage` (in-memory SQLite) backs tests. The
  apply for one step and the checkpoint update commit in the same
  transaction, so a crash leaves either both or neither: replay after a
  crash starts from the last committed cursor, and every `apply` MUST be
  idempotent for the same ordinal (writes keyed by fact-derived ids with
  upsert semantics), which the framework checks in tests by applying a
  step twice.
- **B-5 (never authority).** Every query type this crate and its
  instances expose returns `AsOf<T> { value: T, cursor: Cursor }`, and
  every CLI rendering prints `projected as of <entry-hash-short> (ordinal
  N)`. The crate holds no `Signer`, appends nothing to any ledger, and
  exposes no write to an object store; a projection that needs to record
  something records nothing (constitution XIII).
- **B-6 (erasure).** A `FactView::Erased` step reaches `apply` so the
  projection can record that something existed and is gone; the runner
  additionally calls `on_tombstone(target)` when the step's fact is a
  `ledger.tombstone` (020), and every instance MUST remove any previously
  projected content derived from that `Cid` and render it as erased
  thereafter. Content is never copied into a projection when a `Cid`
  suffices (constitution X): views store the `Cid` and an `erased` flag.
- **B-7 (registry).** `ProjectionRegistry` holds `Box<dyn
  ProjectionFactory>` entries keyed by `NAME`; `register`, `names()`
  sorted, `build(name) -> Result<Box<dyn DynProjection>, Error::NotFound>`.
  `DynProjection` is the object-safe form of B-1 the CLI and the server
  drive. Specs 081 to 085 register their instances in `register_all`.
- **B-8 (the verb).** `hq projection status [--json]` lists every
  registered projection with `name`, `schema_version`, `ordinal`,
  `entry`, and `behind` (the ledger's ordinal count minus the cursor).
  `hq projection run <name> | --all` catches up. `hq projection rebuild
  <name> | --all` resets and runs from zero. Exit codes through
  `Error::exit_code` (010 B-9); `--json` output is sorted-key canonical
  JSON (032).
- **B-9 (no ambient input).** Projections read no clock; every timestamp
  a view stores is an `Hlc` from an entry, encoded as the fixed-width
  sortable text `<wall_ms:020><logical:010><node-hex>` so SQL `ORDER BY`
  reproduces `Hlc` order. `BTreeMap` is the only map type in the crate.

## 4. Functional requirements

- **FR-001.** The runner is a pure function of `(entry reader, object
  store, fact registry, storage, projection)`; `EntryReader` is the read
  seam of 021's `EntryStore` and tests supply an in-memory one.
- **FR-002.** Tests cover: rebuild-from-zero equals incremental (the two
  SQLite dumps are byte-identical after the checkpoint row is excluded);
  a storage that fails after `apply` and before `commit` leaves the
  cursor unchanged and the replay applies the same ordinal once more with
  no duplicate rows; a schema bump resets and reports the reason; an
  erased fact reaches `apply` and `on_tombstone` removes prior content; an
  unknown fact kind is passed as `Opaque` and counted; `Error::Stale` on a
  foreign cursor.
- **FR-003.** A fixture projection (`tests/fixtures/counter.rs`) counting
  facts per kind is the reference instance the framework tests run.
- **FR-004.** CLI tests with `assert_cmd`: `status` on a fresh repo lists
  the registered names at ordinal zero; `rebuild --all` then `status`
  shows `behind 0`; an unknown name exits 1.
- **FR-005.** The crate depends on `hqgit-types`, `hqgit-object`,
  `hqgit-ledger`, and `hqgit-domain` only within the workspace.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-projection --locked` passes.
- **AC-2.** Against a fixture repo with fifty facts, `hq projection
  rebuild counter` twice produces identical dumps, and `hq projection
  status --json` reports `behind: 0` with the cursor naming the last
  entry.
- **AC-3.** `spec-spine index` discovers `hqgit-projection` bound to this
  spec and `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The concrete views (081), full-text search (082), the code graph (083),
the ecosystem graph (084), feeds (085), serving projections over the API
(093), and replicating projections between nodes (091 replicates the
ledger; a node rebuilds its own projections).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-projection --locked
cargo test -p hqgit-cli --locked projection
```
