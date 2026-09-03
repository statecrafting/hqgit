---
id: "018-deterministic-total-order"
title: "Deterministic total order over the DAG and hybrid logical clock generation"
status: approved
kind: "kernel"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "017-ledger-entry-dag"
establishes:
  - "crates/hqgit-ledger/src/order.rs"
  - "crates/hqgit-ledger/src/clock.rs"
  - "crates/hqgit-ledger/tests/order.rs"
extends:
  - { spec: "017-ledger-entry-dag", unit: "crates/hqgit-ledger/src/lib.rs", nature: additive }
summary: >
  Concurrent facts merge by set union under a deterministic total order,
  topological with a tiebreak on hash: that sentence from the thesis is
  what lets two replicas holding the same entries fold to the same state
  without coordination. This spec fixes the order (a Kahn sort whose ready
  set is ordered by hybrid logical clock then entry hash), its incremental
  form from a checkpoint, and the fold cursor projections resume from. It
  also owns the one place in the ledger crate that reads a clock: the
  hybrid logical clock generator, with an injected clock source, a drift
  bound, and the guarantee that it is never called on a hashing path.
---

# 018: Deterministic total order and clock generation

## 1. Purpose

Thesis §4.2 and constitution VII: facts never conflict because they merge
by set union under one deterministic total order. The DAG (017) gives
partial order; this spec gives the total order every fold (019, 080) and
every reconciliation (110) agrees on, so "the state of the repository at
entry X" means the same thing on every machine. The hybrid logical clock
that stamps entries lives here too, because its algorithm is what makes
the order meaningful across replicas whose wall clocks disagree.

## 2. Territory

`order.rs` (the total order, the incremental order, the fold cursor) and
`clock.rs` (the HLC generator and the `ClockSource` seam) in the crate 017
founded, plus `tests/order.rs`. Nothing here changes what an entry is or
how it hashes.

## 3. Behavior

- **B-1 (total order).** `total_order(dag: &Dag) -> Vec<EntryHash>` is a
  Kahn topological sort over the parent relation where the ready set is a
  `BTreeSet<(Hlc, EntryHash)>` and the smallest element is popped each
  step. The result MUST list every parent before its children, MUST order
  concurrent entries by `(hlc, hash)` ascending, and MUST be identical for
  any two DAGs holding the same entry set regardless of insertion order or
  the order `Dag` iterates internally. The genesis entry is always first.
- **B-2 (incremental order).** `order_from(dag, checkpoint: &FoldCursor) ->
  Result<Vec<EntryHash>, Error>` returns the suffix of `total_order(dag)`
  after the checkpoint's position when the checkpoint is a prefix of the
  current total order, and `Error::Stale` naming the first divergent
  position when new entries sorted earlier than the checkpoint's last
  entry (a late-arriving concurrent entry with a smaller `(hlc, hash)`),
  in which case the caller (080) MUST rebuild from zero or from the last
  stable prefix. Staleness is thus explicit, never a silently reordered
  fold.
- **B-3 (`FoldCursor`).** `FoldCursor { position: u64, last: EntryHash,
  prefix_hash: Hash }` where `prefix_hash` is the running BLAKE3 over the
  ordered entry hashes up to `position` (`Hash::of(prev_prefix_hash ||
  entry_hash)` with the genesis prefix hash being `Hash::of(genesis)`);
  a checkpoint from one replica validates against another replica's order
  by recomputing the prefix hash. It implements `Canonical` (011) so
  projections (080) persist it.
- **B-4 (`ClockSource`).** `trait ClockSource { fn now_ms(&self) -> u64; }`
  with `SystemClock` (the one `std::time` read in the ledger crate,
  isolated in `clock.rs`) and `FixedClock(u64)` for tests. No other module
  in `hqgit-ledger` may name `std::time`; spec 010 FR-003's source guard is
  extended by a test here to assert that `std::time` appears only in
  `clock.rs`.
- **B-5 (`HlcGenerator`).** `HlcGenerator::new(node: NodeId, source: Box<dyn
  ClockSource>) -> Self`; `fn next(&mut self, observed: Option<&Hlc>) ->
  Result<Hlc, Error>` implements the hybrid logical clock (Kulkarni,
  Demirbas, Madeppa, Avva, Leone, 2014): `wall = max(now, last.wall,
  observed.wall)`; if `wall == last.wall == observed.wall` then `logical =
  max(last.logical, observed.logical) + 1`; if `wall == last.wall` then
  `logical = last.logical + 1`; if `wall == observed.wall` then `logical =
  observed.logical + 1`; else `logical = 0`. The result is strictly greater
  than both `last` and `observed` under spec 010 B-8's `Ord`. The
  generator's `node` is fixed for its lifetime.
- **B-6 (drift bound).** `next` MUST return `Error::Validation` when
  `observed.wall_ms` exceeds `now_ms` by more than `MAX_DRIFT_MS =
  60_000`, and when `logical` would overflow `u32::MAX`; the caller
  surfaces the first as a peer clock problem rather than adopting a far
  future timestamp that would dominate the order forever.
- **B-7 (node id).** `NodeId` is derived as the first 16 bytes of
  `Hash::of(b"hqgit/v1/node" || key_id_bytes)` from the repository's local
  identity key (021 stores it; 060 formalizes identity), so two replicas of
  one identity produce comparable but distinct clocks; a test pins the
  derivation.
- **B-8 (never on a hashing path).** No function that produces canonical
  bytes or a hash calls `HlcGenerator`; the generator is invoked once per
  entry by the append path (021) and the resulting `Hlc` is data from then
  on.

## 4. Functional requirements

- **FR-001.** `order.rs` is pure over the `Dag`; `clock.rs` is pure over
  its injected source.
- **FR-002.** Tests cover: permutation invariance (the same fifty entries
  inserted in twenty random orders, seeded, yield one total order);
  tie-break vectors (equal `Hlc`, distinct hashes); a fork and merge; the
  genesis-first rule; `order_from` on a prefix cursor and on a stale
  cursor; prefix hash recomputation across replicas; the HLC state table
  of B-5 case by case with `FixedClock`; drift rejection; logical
  overflow; node id derivation vector; the `std::time` isolation guard.
- **FR-003.** A property test (`proptest`) asserts that for random DAGs the
  total order is a linear extension of the parent relation and is
  invariant under insertion permutation.
- **FR-004.** `total_order` on a DAG of 100 000 entries completes in under
  two seconds in a release build (a benchmark-style test marked
  `#[ignore]` documents the bound; CI runs the 10 000-entry variant).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-ledger --locked order` passes.
- **AC-2.** `cargo test -p hqgit-ledger --locked` passes with spec 017's
  tests unchanged.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Interpreting entry payloads as facts and folding derived state (019);
persisting cursors and rebuilding projections (080); reconciling entry
sets between replicas (110); identity-derived node ids beyond the local
key (060).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-ledger --locked order
cargo test -p hqgit-ledger --locked
```
