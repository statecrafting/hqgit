---
id: "052-semantic-conflicts"
title: "Semantic conflicts: pairwise conflict detection over deltas and anchors, with text kept separate"
status: approved
kind: "feature"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 3
depends_on:
  - "051-semantic-deltas"
establishes:
  - "crates/hqgit-domain/src/conflict.rs"
  - "crates/hqgit-domain/tests/conflict.rs"
  - "crates/hqgit-domain/testdata/conflicts/"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  # Line-level hunks for the Text kind come from imara-diff, pinned exact.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Conflict detection should be semantic, not textual (design §1.1 point
  3). Given two revisions and their common base tree, this spec computes
  a deterministic ConflictReport from the 051 deltas and the 025 syntax
  trees: SameSymbolEdited when both sides edit one definition,
  SignatureChangedAndCalled when one side changes a signature the other
  side calls, DependencyVersionDiverged when both move one dependency to
  different versions or sources, and CapabilityOverlap when both gain the
  same capability in one file. Textual overlap is computed too, from
  line hunks, but reported as its own Text kind so a merge that is clean
  in git and broken in meaning, or the reverse, is never mistaken for the
  other. Two changes editing different functions in one file produce no
  conflict of either kind; changing a signature the other calls does.
---

# 052: Semantic conflicts

## 1. Purpose

Git reports conflicts where bytes overlap and stays silent where meaning
collides: one change renames a parameter, another adds a caller, and the
merge is clean until it fails to compile. Design §1.1 point 3 asks for the
inverse. With deltas (051) and anchors (025) in hand, this spec answers
"do these two revisions conflict, and in what sense" as a pure function
the CLI, the merge queue (076), and the review UI (095) all call. Keeping
the textual and semantic kinds apart is the point: each is honest about
what it can see.

## 2. Territory

`conflict.rs` in `crates/hqgit-domain` (the `Conflict` vocabulary,
severity, symbol edits, callee extraction, hunk overlap, the report and
its entry point), `tests/conflict.rs`, and the fixture subtree
`testdata/conflicts/`. Additively: `lib.rs` re-exports, `imara-diff`
pinned exact in `[workspace.dependencies]` and the crate manifest.

## 3. Behavior

- **B-1 (entry point).** `semantic_conflicts(store: &dyn ObjectStore, a:
  &Revision, b: &Revision, base: &Cid) -> Result<ConflictReport, Error>`
  refuses `a.id == b.id` (`Error::Validation`). `base` is the common base
  tree the caller determined (for stacked siblings the tree below them;
  for a merge candidate the main tree via 031); the revisions' own `base`
  fields are not consulted. It computes `tree_diff(base, a.tree)`,
  `tree_diff(base, b.tree)` (050 B-8), `compute_deltas(base, a.tree)`, and
  `compute_deltas(base, b.tree)` (051 B-1), then applies B-3 to B-7.
- **B-2 (vocabulary and severity).** `Conflict` is a closed enum:
  `SameSymbolEdited { path, symbol: SymbolKey, a: SymbolEdit, b: SymbolEdit
  }`, `SignatureChangedAndCalled { changed_by: Side, path, symbol:
  SymbolKey, call_sites: Vec<CallSite> }`, `DependencyVersionDiverged {
  manifest, name, base: Option<Dep>, a: Option<Dep>, b: Option<Dep> }`,
  `CapabilityOverlap { capability, path, a: Vec<CapabilityUse>, b:
  Vec<CapabilityUse> }`, `Text { path, kind: TextConflictKind }`. `Side`
  is `A | B`. `Severity` is `#[repr(u8)]` `Advisory = 1 | Likely = 2 |
  Blocking = 3` and `Conflict::severity()` is fixed:
  `SignatureChangedAndCalled`, `DependencyVersionDiverged`, and `Text`
  (except `ModeDivergence`, `Likely`) are `Blocking`; `SameSymbolEdited`
  is `Likely`; `CapabilityOverlap` is `Advisory`. Integer weights only.
- **B-3 (symbol edits).** `symbol_edits(before: &[Item], after: &[Item])
  -> BTreeMap<SymbolKey, SymbolEdit>` over 051 `extract_items` at every
  visibility (private symbols conflict too), with `SymbolKey { path, kind:
  ItemKind, name }` and `SymbolEdit` `Added { after: Hash } | Removed |
  Modified { signature_changed: bool, after: Hash }` where `after` is the
  item node's content hash (025). `SameSymbolEdited` fires when both
  sides carry an edit for one key and the edits are not identical; two
  sides making the same edit (equal `after`) converge and do not
  conflict.
- **B-4 (`SignatureChangedAndCalled`).** For every symbol one side
  `Modified { signature_changed: true }` or `Removed`, the other side's
  added or modified items are scanned for calls to it. `callees_in(tree:
  &Tree, range: ByteRange) -> Vec<CallSite { callee: String, range:
  ByteRange }>` collects, in Rust, `call_expression` targets (the last
  segment of a scoped identifier), `method_call_expression` names, and
  `macro_invocation` names; in TypeScript, `call_expression` identifiers
  and member properties and `new_expression` constructors. Matching is by
  the symbol's short name; no cross-file resolution (083), so the kind
  over-reports by design. Fires only when the calling item is itself an
  edit of the other side; an untouched pre-existing caller is the
  compiler's job, not a conflict between these two revisions.
- **B-5 (`DependencyVersionDiverged`).** From the two `DependencyDelta`s:
  one key `(ecosystem, manifest, name)` added, version-changed, or
  source-changed on both sides with different `(version, source,
  locked)`; or removed on one side and changed on the other. Identical
  results on both sides converge.
- **B-6 (`CapabilityOverlap`).** Both sides gain the same `Capability` in
  the same `path` (051 B-6). Advisory: each side's reviewer approved one
  introduction and the merged tree carries both.
- **B-7 (`Text`).** `TextConflictKind` is `BothModified { a: LineRange,
  b: LineRange } | ModifyDelete { deleted_by: Side } | BothAdded |
  ModeDivergence | Binary` with `LineRange { start: u32, end: u32 }`
  (1-based, half-open, in base line coordinates). For a path both sides
  modified, `line_hunks(before: &[u8], after: &[u8]) -> Vec<Hunk>` runs
  `imara-diff` with `Algorithm::Myers` over lines split on `\n` (a `\r`
  stays in its line); two hunks conflict when their base ranges intersect
  or are adjacent (git's rule), and every such pair is one `BothModified`.
  `BothAdded` requires different content; identical additions or identical
  modifications converge. A NUL in the first 8 KiB of either side makes
  the path `Binary` when both modified it. `ModifyDelete` and
  `ModeDivergence` come from the two `TreeDiff`s alone. This kind is
  computed at file and line granularity and says nothing about meaning;
  B-3 to B-6 say nothing about bytes.
- **B-8 (report).** `ConflictReport { a: RevisionId, b: RevisionId, base:
  Cid, conflicts: Vec<Conflict>, unsupported: Vec<Unsupported>, extra }`
  derives `Canonical` (011) so a later spec can attest it under its own
  predicate; `conflicts` is sorted by `(severity desc, path, kind
  ordinal, symbol)`, `unsupported` is the union of the two `DeltaSet`s'
  lists (051 B-2), and the report offers `is_clean()`, `max_severity() ->
  Option<Severity>`, and `by_kind()`. `semantic_conflicts(a, b)` and
  `semantic_conflicts(b, a)` produce reports equal up to swapping `Side`.
- **B-9 (determinism).** A pure function of `(store contents, a, b,
  base)`; no clock, environment, `HashMap`, or float; every list sorted.

## 4. Functional requirements

- **FR-001.** Fixtures under `testdata/conflicts/<case>/` hold `base/`,
  `a/`, `b/` file trees and an `expected.json` report; `tests/conflict.rs`
  loads each into a `MemoryStore` (013) and compares. Cases, for both
  Rust and TypeScript where a language applies: different functions in
  one file (no conflict of any kind); same function edited differently
  (`SameSymbolEdited` and `BothModified`); same function edited
  identically (clean); signature changed by A and a new caller added by B
  (`SignatureChangedAndCalled`, no `Text`); signature changed with an
  untouched pre-existing caller (clean); a private helper edited by both
  (`SameSymbolEdited`); dependency moved to two versions
  (`DependencyVersionDiverged`) and to one version (clean); both gain
  `Network` in one file (`CapabilityOverlap`); adjacent hunks
  (`BothModified`); one side deletes a file the other edits
  (`ModifyDelete`); both add one path with different bytes (`BothAdded`);
  a binary both touched (`Binary`); an unknown extension edited by both
  (`Text` only, listed in `unsupported`).
- **FR-002.** Tests: symmetry of B-8 on every fixture; double evaluation
  yields identical canonical bytes; `line_hunks` on a golden pair matches
  recorded hunks so an `imara-diff` bump is visible; the sort order of
  B-8 on a synthetic report with every kind.
- **FR-003.** A test pins the exact `imara-diff` version against
  `Cargo.lock`, mirroring 025 FR-002.
- **FR-004.** `lib.rs` re-exports `semantic_conflicts`, `ConflictReport`,
  `Conflict`, `Severity`, `Side`, and `TextConflictKind`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked conflict` passes with
  every fixture in FR-001.
- **AC-2.** The two named cases of the plan hold: different functions in
  one file report nothing; a changed signature the other side calls
  reports `SignatureChangedAndCalled` at `Blocking`.

## 6. Out of scope

Performing or resolving a merge (031; 076 for the queue); attesting a
report (076, or a later spec registering a predicate); cross-file and
cross-repo symbol resolution (083, 084); conflicts among more than two
revisions (076 evaluates candidates pairwise and in batches); rendering
(095); languages beyond Rust and TypeScript (a later spec per language).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked
```
