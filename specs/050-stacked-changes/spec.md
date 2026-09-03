---
id: "050-stacked-changes"
title: "Stacked changes: dependency facts, a deterministic stack order, restack plans, and interdiff"
status: approved
kind: "feature"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 3
depends_on:
  - "024-change-and-revision"
establishes:
  - "crates/hqgit-domain/src/stack.rs"
  - "crates/hqgit-domain/src/interdiff.rs"
  - "crates/hqgit-domain/tests/stack.rs"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
  # The new change.dependency_dropped kind joins the frozen fact-kind listing
  # that 023 keeps in 011's golden vector directory (023 FR-002).
  - { spec: "011-canonical-encoding", unit: "crates/hqgit-types/testdata/vectors/", nature: additive }
summary: >
  Graphite exists because the branch pointer is the wrong unit of change
  (design §1.1 point 2). With Change and Revision in place (024), a stack
  is nothing more than a relation between changes: change.depends_on and
  change.dependency_dropped facts converge per edge as a last-writer-wins
  register, StackView folds them, and the stack order is a topological
  sort with ties broken on ChangeId so every replica prints the same
  stack. A restack is a pure plan (which revision goes onto which base, in
  which order) that the CLI executes through the git bridge; the domain
  never rebases. Interdiff answers "what changed since I last looked" by
  comparing what two revisions of one change each did to their base at
  the tree level, so base movement alone produces an empty interdiff.
---

# 050: Stacked changes

## 1. Purpose

Design §1.1 point 2 promises that stacked changes become native rather
than a tooling cottage industry, and that "what changed since I last
looked" becomes a first-class query. Thesis §4.3 gives the noun (a Change
with ordered Revisions); this spec adds the relation between changes and
the two queries reviewers actually run: the order of a stack, and the
difference between two revisions of one change with base movement
factored out. Everything here is a fold over facts (constitution VII) or a
pure function over trees (013), so the CLI and the server (constitution
XIII) compute identical answers offline and online.

## 2. Territory

`stack.rs` (the edge register, `StackView`, `Stack`, restack plans, the
builders) and `interdiff.rs` (`tree_diff` and `interdiff`) in
`crates/hqgit-domain`, plus `tests/stack.rs`. Additively: `lib.rs`
re-exports; `facts.rs` gains the semantics of the reserved
`change.depends_on` kind and one new kind, `change.dependency_dropped`;
the `domain/fact-kinds.json` listing gains that row.

## 3. Behavior

- **B-1 (facts).** `change.depends_on { change, on, at_revision }` (023
  B-2) declares that `change` is stacked on `on` as of `at_revision`.
  `change.dependency_dropped { change: ChangeId, on: ChangeId, extra }`
  is a new kind, `v = 1`, registered by `register_domain`. Validation
  (023 B-4 extended): `change != on`, every id 32 bytes; a violation is
  `Error::Validation` naming the field.
- **B-2 (edges converge).** Each ordered pair `(change, on)` is an `Edge {
  active: LwwRegister<bool>, at_revision: RevisionId, declared_at: Hlc }`.
  `change.depends_on` sets `active` to `true` and `change.dependency_dropped`
  sets it to `false`, each at the fact's `Hlc` with the entry's issuer key
  as the tiebreak (019 B-4), so a concurrent declare and drop converge on
  every replica. The fold rejects nothing (024 B-4).
- **B-3 (`StackView`).** Implements `DerivedState` (019 B-5) over the two
  kinds: `edges: BTreeMap<(ChangeId, ChangeId), Edge>`, `below:
  BTreeMap<ChangeId, BTreeSet<ChangeId>>` (active dependencies), `above`
  (the reverse), `warnings: Vec<StackWarning>`. `dependencies_of(change)`
  and `dependents_of(change)` return active edges only. An edge that
  closes a cycle through active edges is applied (it is a fact) and
  recorded as `StackWarning::Cycle { members: Vec<ChangeId> }` in id order.
- **B-4 (`Stack`).** `stack_of(&self, changes: &ChangeView, change:
  &ChangeId) -> Result<Stack, Error>` takes the component of active edges
  reachable from `change` in both directions, drops edges into a `Merged`
  change (a merged dependency is satisfied: it is part of the base now)
  and edges into an `Abandoned` change (recorded as
  `StackWarning::DependsOnAbandoned { change, on }`), and orders the rest
  bottom-up by Kahn's algorithm with the ready set a `BTreeSet<ChangeId>`,
  so ties break on id exactly as 018 breaks entry ties on hash. `Stack {
  entries: Vec<StackEntry>, warnings: Vec<StackWarning> }` with
  `StackEntry { change: ChangeId, depth: u16, depends_on:
  BTreeSet<ChangeId>, revision: RevisionId, base_status: BaseStatus }`;
  `depth` is the longest path from a bottom entry, `revision` is 024's
  `latest_revision`. A component containing a cycle yields
  `Err(Error::Validation)` naming the members: no order exists.
- **B-5 (`BaseStatus`).** `Current | Stale { expected: Cid, actual: Cid }
  | Unresolved`. For an entry with exactly one dependency `d`, `expected`
  is the `tree` of `d`'s latest revision and `actual` is the entry's
  latest revision `base`; `Current` when equal, `Stale` otherwise. A
  bottom entry is `Current` (nothing to compare against). An entry with
  several dependencies is `Unresolved`: its base is a merge tree the
  domain cannot compute.
- **B-6 (builders are pure).** `declare_dependency(view: &StackView,
  changes: &ChangeView, change, on, at_revision) -> Result<DomainFact,
  Error>` refuses `change == on`, an `on` the `ChangeView` does not know,
  an `at_revision` that is not a revision of `change`, an `on` that is
  `Abandoned`, and any `on` that already reaches `change` through active
  edges (cycle refusal, the error names the path). `drop_dependency(view,
  change, on) -> Result<DomainFact, Error>` refuses an edge that is not
  active. Both return facts for the caller to append (021).
- **B-7 (restack plans).** `restack(stack: &Stack, changes: &ChangeView,
  new_base: Option<Cid>) -> RestackPlan` with `RestackPlan { steps:
  Vec<RestackStep> }` and `RestackStep { change: ChangeId, revision:
  RevisionId, current_base: Cid, onto: Onto }`, `Onto` being `Tree(Cid) |
  ResultOf(ChangeId) | MergeOf(Vec<ChangeId>)`. With `Some(b)` every entry
  is a step: bottom entries go onto `Tree(b)` (skipped when their base
  already equals `b`), others onto `ResultOf` their single dependency or
  `MergeOf` their several. With `None` only `Stale` and `Unresolved`
  entries and everything above them are steps. Steps follow the stack
  order. The plan is a description: executing it (rebasing the tree,
  submitting the new revision through 024 `submit_revision`) belongs to
  the CLI and the git bridge (031).
- **B-8 (`tree_diff`).** `tree_diff(store: &dyn ObjectStore, before: &Cid,
  after: &Cid) -> Result<TreeDiff, Error>` walks two 013 `Tree`s in entry
  name order, descending into a subtree only when the two sides' cids
  differ, and returns `TreeDiff { entries: BTreeMap<String, PathChange> }`
  keyed by repo-relative POSIX path with `PathChange { before:
  Option<(EntryMode, Cid)>, after: Option<(EntryMode, Cid)> }` and
  `PathChange::kind() -> ChangeKind { Added | Removed | Modified }`. Only
  leaf entries appear; no entry has `before == after`; a missing tree
  object is `Error::NotFound`; a tree whose `get` fails verification
  propagates `Error::Crypto`.
- **B-9 (`interdiff`).** `interdiff(store: &dyn ObjectStore, from:
  &Revision, to: &Revision) -> Result<Interdiff, Error>` requires
  `from.change == to.change` (`Error::Validation`). Let `F =
  tree_diff(from.base, from.tree)` and `T = tree_diff(to.base, to.tree)`.
  For every path in either: identical `PathChange`s are dropped; a path
  only in `T` is `Introduced`; only in `F` is `Dropped`; in both with equal
  `after` is dropped (the same result, however the base moved); in both
  with different `after` is `Reworked { from: Option<(EntryMode, Cid)>,
  to: Option<(EntryMode, Cid)>, base_moved: bool }` where `base_moved` is
  `F.before != T.before`. `Interdiff { change: ChangeId, from:
  RevisionId, to: RevisionId, base_moved: bool, entries: BTreeMap<String,
  InterdiffEntry> }` with `base_moved = from.base != to.base` and
  `is_empty()`. A path neither revision touched never appears, so pure
  base movement yields an empty interdiff. `interdiff_since(store,
  changes: &ChangeView, change, seen: &RevisionId)` is the reviewer's
  form: `from = seen`, `to = latest_revision`.
- **B-10 (no ambient input).** Every function is a pure function of its
  arguments plus reads through the `ObjectStore` seam; no clock,
  environment, `HashMap`, or float appears (010 B-11).

## 4. Functional requirements

- **FR-001.** Tests in `tests/stack.rs`: `declare_dependency` refuses
  self, unknown, abandoned, wrong revision, and a two-hop cycle with the
  path named; a cycle arriving through concurrent declarations folds to a
  `Cycle` warning and `stack_of` returns `Err`; concurrent declare and drop
  converge to the greater `(hlc, key)`; `stack_of` over a diamond (one
  bottom, two middles, one top) gives the same order under three arrival
  permutations and breaks the middle tie on id; a merged dependency drops
  out and an abandoned one warns; `BaseStatus` flips to `Stale` when the
  lower change gains a revision; `restack` with `Some` and with `None`
  produce the expected step lists; `tree_diff` on a fixture skips an
  identical subtree (asserted through a counting `ObjectStore` wrapper)
  and lists leaves only; `interdiff` on the same edit replayed over a
  moved base is empty with `base_moved == true`, and detects `Introduced`,
  `Dropped`, and `Reworked`.
- **FR-002.** A property test (`proptest`) folds a random valid dependency
  history through two total-order-preserving permutations and asserts
  equal views and equal stack orders.
- **FR-003.** `domain/fact-kinds.json` gains `change.dependency_dropped`
  and 023 FR-002's exact-match test still passes.
- **FR-004.** `lib.rs` re-exports `StackView`, `Stack`, `StackEntry`,
  `BaseStatus`, `RestackPlan`, `TreeDiff`, `Interdiff`, and the builders.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked stack` passes.
- **AC-2.** The golden stack fixture in `tests/stack.rs` (a four-change
  diamond with one drop and one merge) folds to the recorded `Stack`,
  warnings included, from every tested permutation.

## 6. Out of scope

Executing a restack (the git bridge, 031, and a later CLI feature spec
for `hq stack`); a line-level three-way interdiff (the tree-level result
here is what a later refinement and the review UI, 095, render);
semantic content of an interdiff (051); stack rows in SQL (081); merge
ordering of a stack (076).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked
```
