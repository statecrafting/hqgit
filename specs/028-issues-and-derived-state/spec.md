---
id: "028-issues-and-derived-state"
title: "Issues as facts with converging derived state: registers and an add-wins label set"
status: approved
kind: "feature"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 1
depends_on:
  - "023-domain-fact-vocabulary"
establishes:
  - "crates/hqgit-domain/src/issue.rs"
  - "crates/hqgit-domain/tests/issue.rs"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  The worked example of constitution VII. An issue is a sequence of
  immutable facts (opened, field set, closed, link added) and its visible
  state is derived: title, state, assignee, and milestone are last-writer-
  wins registers over the hybrid logical clock, and labels are an add-wins
  observed-remove set whose removals name the additions they observed.
  Nothing is a counter, nothing is a row, and the IssueView rebuilds from
  zero on every replica to the same answer. This is the shape every later
  mutable noun copies, and it is what makes the GitHub mirror (040) a
  fact importer rather than a schema migration.
---

# 028: Issues and derived state

## 1. Purpose

Thesis §4.2: only derived state needs convergence, and a hybrid logical
clock with last-writer-wins is sufficient for nearly all of it. Issues are
the noun with the most mutable fields, so they are the proving ground:
if issues fold cleanly from facts with registers and one small set CRDT,
the CRDT surface stays near five percent of the domain (constitution VII)
and product pressure to reach for a sequence CRDT is refused with a
working counterexample.

## 2. Territory

`issue.rs` in `crates/hqgit-domain`: the `Issue` type, `IssueState`, the
typed `IssueField` values, the `LabelSet`, the `IssueView` fold, and the
builders; plus `tests/issue.rs`. Additively: `lib.rs` re-exports and the
typed decoding of `issue.field_set` values in `facts.rs` (from the opaque
`Value` spec 023 reserved).

## 3. Behavior

- **B-1 (`Issue`).** `Issue { id: IssueId, opened_by: Principal, opened_at:
  Hlc, title: LwwRegister<String>, state: LwwRegister<IssueState>,
  assignee: LwwRegister<Option<Principal>>, milestone:
  LwwRegister<Option<String>>, labels: LabelSet, links:
  BTreeSet<LinkTarget>, threads: Vec<ThreadId>, warnings:
  Vec<IssueWarning> }`. `IssueState` is `Open | Closed`.
- **B-2 (typed fields).** `issue.field_set` values decode per field:
  `Title(String)`, `State(IssueState)`, `Assignee(Option<Principal>)`,
  `Milestone(Option<String>)`, `LabelAdd(String)`, `LabelRemove { label:
  String, observed: Vec<Hlc> }`. A value of the wrong shape for its field
  is `Error::Validation` at decode (023 B-4 extended). `issue.closed` is
  the same as `State(Closed)` at the fact's `Hlc` and additionally records
  `reason`; reopening is `State(Open)`.
- **B-3 (registers).** Every scalar field is a spec 019 `LwwRegister`
  keyed by the fact's `Hlc` and the entry's issuer key as the tiebreak;
  concurrent edits converge to the greater `(hlc, key)` on every replica.
- **B-4 (`LabelSet`).** An observed-remove set specialized to labels:
  `LabelAdd` at `hlc` inserts the tag `(label, hlc)`; `LabelRemove` removes
  exactly the tags whose `hlc` is in `observed`; a label is present iff it
  has at least one surviving tag. An add concurrent with a remove that did
  not observe it survives (add-wins). `LabelSet::labels() ->
  BTreeSet<&str>` and `tags_for(label) -> &[Hlc]` (what a client must send
  as `observed` to remove the label as it currently sees it). The set is
  local to `issue.rs`; promoting it to spec 019's `crdt/` module is a later
  refinement noted in Out of scope.
- **B-5 (links and threads).** `issue.link_added` inserts into `links`
  (a set; duplicates are no-ops). Comments on an issue are spec 026
  threads whose `change` is absent: this spec extends nothing in 026;
  instead `review.thread_opened` on an issue carries the issue id in
  `extra["issue"]` until a later spec promotes it, and `IssueView`
  collects such threads into `threads`. The fold records a link to an
  unknown target with `IssueWarning::DanglingLink`.
- **B-6 (builders).** `open_issue(opened_by, title, nonce) -> (IssueId,
  DomainFact)`, `set_field(issue, value: IssueFieldValue) -> DomainFact`,
  `close(issue, reason) -> DomainFact`, `add_link(issue, target) ->
  DomainFact`, and `remove_label(view, issue, label) ->
  Option<DomainFact>` which reads `tags_for` to fill `observed` and returns
  `None` when the label is absent. Pure; nothing is stored here.
- **B-7 (queries).** `IssueView::get(id)`, `issues()` in id order,
  `open_issues()`, `by_label(label)`, `by_assignee(principal)`.

## 4. Functional requirements

- **FR-001.** Tests: concurrent title edits converge to the higher `Hlc`
  and, at equal `Hlc`, to the higher key; add then remove; remove
  concurrent with an unobserved add keeps the label; two adds and one
  remove observing both clears it; close then reopen; every warning
  variant; `remove_label` on an absent label returns `None`; links
  deduplicate.
- **FR-002.** A property test folds a random issue history through two
  permutations agreeing on total order and asserts equal views, and a
  second asserts the label set equals a reference OR-set model.
- **FR-003.** No function in `issue.rs` reads a clock or performs I/O.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked issue` passes.
- **AC-2.** A fixture of two replicas editing the same issue (title,
  labels, assignee) in interleaved orders folds to one identical view on
  both, recorded as a golden view in `tests/issue.rs`.

## 6. Out of scope

Milestones as a noun of their own, issue templates, and cross-issue
dependencies (later feature specs); moving `LabelSet` into spec 019's
`crdt/` module as a general OR-set (a later amendment to 019); mirrored
GitHub issues (040); search (082); feeds (085).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked issue
```
