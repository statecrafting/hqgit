---
id: "076-merge-queue"
title: "Merge queue: speculative evaluation over candidate merge states, batching, and bisection"
status: approved
kind: "feature"
domain: "l3-evaluation"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 5
depends_on:
  - "075-build-graph"
  - "074-execution-provenance"
  - "067-policy-evaluation-attestation"
establishes:
  - "crates/hqgit-eval/src/queue.rs"
  - "crates/hqgit-eval/src/speculate.rs"
  - "crates/hqgit-eval/tests/queue.rs"
extends:
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/src/lib.rs", nature: additive }
  # The queue's own facts (enqueued, dequeued, merged) join the vocabulary.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  Thesis §4.4: merge queues become speculative evaluation over candidate
  merge states. A candidate is a change whose latest revision carries a
  verified policy-eval attestation (067) with verdict Allow; the queue
  never runs a policy live (constitution XI). The speculator builds the
  merge tree of trunk plus the candidates in order, computes the affected
  targets (075), and evaluates every gating target through the execution
  service with gating cache lookups (071), so a target whose key is
  unchanged since trunk costs a verified cache hit and nothing else. A
  green batch merges by appending facts; a red batch bisects until each
  failure is pinned on one candidate, which is dequeued with the evidence.
  Queue state is facts, so the queue is a fold any replica can rebuild.
---

# 076: Merge queue

## 1. Purpose

Design doc §1.1 point 4 promises merge-queue correctness falling out as a
property, not as a feature. It does, once three things hold: the trunk's
gating results are attested cache entries keyed by target keys (075 B-5),
a candidate's merge tree yields the same key for every target it does not
touch, and a gating lookup refuses anything unattested (071 B-3, thesis
D10). Then evaluating a batch is exactly the cost of what the batch
changed, and merging on green is sound because every result consumed was
either produced under provenance (074) or verified as identical input.
This spec is the driver that composes those parts and the facts that
record what it did.

## 2. Territory

`queue.rs` (the queue facts, the `QueueView` fold, candidate admission,
the trunk view) and `speculate.rs` (merge trees, batch planning,
evaluation through the seams, bisection) in `crates/hqgit-eval`, plus
`tests/queue.rs`. Additively: three fact kinds in spec 023's vocabulary
and the crate's re-exports. Running the driver on a schedule and exposing
it over the API is the server's (a later edge spec over 093); the CLI
verb that enqueues is a later CLI spec.

## 3. Behavior

- **B-1 (facts).** Three kinds join 023 B-2: `queue.enqueued { change:
  ChangeId, revision: RevisionId, policy_eval: AttestationId, enqueued_by:
  Principal }`; `queue.dequeued { change, revision, reason: Dequeue }` with
  `Dequeue` a closed enum `Withdrawn | Superseded(RevisionId) |
  Conflict(Vec<String>) | Failed(Vec<TargetId>) | PolicyRevoked`; and
  `queue.merged { batch: Hash, base: Cid, trunk: Cid, merged: Vec<(ChangeId,
  RevisionId)>, evidence: Vec<AttestationId> }` where `evidence` lists
  the provenance attestation of every gating target's consumed entry. A
  `queue.merged` fact is accompanied, in the same append sequence, by one
  `change.merged` (023) per merged change so the change view (024) agrees.
- **B-2 (trunk).** `TrunkView` is a `DerivedState` (019) folding
  `queue.merged` into `Trunk { tree: Cid, since: EntryHash }`, the tree of
  the latest merge in total order (018). A repository with no merge yet
  has trunk `= QueueConfig.initial_trunk` (a tree cid the operator names;
  for a git-backed repository, 031's mapping of the default branch tree).
  The first batch evaluates every gating target because nothing is
  cached; every later batch pays only for what changed.
- **B-3 (candidates).** `QueueView` folds `queue.enqueued` and
  `queue.dequeued` into an ordered `Vec<Queued>` by the enqueue fact's
  `(hlc, hash)`. `admit(queued, changes: &ChangeView, verified:
  &VerifiedAttestationSet, config) -> Result<Candidate, Dequeue>` requires:
  the change is `Open` and `revision` is its latest (else `Superseded`);
  `policy_eval` is in `verified` with `Verdict::Ok`, subject equal to the
  revision id, predicate `hqgit/policy-eval/v1`, claim `verdict = Allow`,
  and claim `policy` equal to `config.policy` (else `PolicyRevoked`). The
  verified set is an input built by 064; this crate never evaluates a
  policy and never verifies a signature (constitution XI: the gate consumes
  the attestation).
- **B-4 (merge tree).** `merge_tree(store, base: &Cid, ours: &Cid, theirs:
  &Cid) -> Result<Merged, Error>` is a path-level three-way merge of spec
  013 trees: an entry changed on one side only takes that side; changed
  identically on both is taken; changed differently on both, or changed on
  one side and removed on the other, is a conflict. `Merged::Clean(Cid)`
  stores the result; `Merged::Conflict(Vec<String>)` lists the paths. There
  is no textual or semantic merge here (052 owns that); a file-level
  conflict rejects the candidate with `Dequeue::Conflict`.
- **B-5 (batch).** `plan_batch(trunk: &Trunk, candidates: &[Candidate],
  config, store) -> Batch` folds candidates in queue order, up to
  `config.max_batch` (default 8): each candidate's revision tree is merged
  onto the running tree with `base = revision.base`; a conflicting
  candidate is set aside with its paths and the fold continues. `Batch {
  id: Hash, base: Cid, members: Vec<Candidate>, tree: Cid, rejected:
  Vec<(Candidate, Dequeue)> }` with `id = Hash::of(b"hqgit/v1/batch" ||
  base || member revision ids in order)`.
- **B-6 (evaluation).** `speculate(batch, graph: &BuildGraph, seams:
  &Seams) -> Result<BatchResult, Error>` where `Seams { evaluator: &dyn
  Evaluator, cache: &dyn ActionCache, verifier: &dyn GateVerifier, store }`
  and `trait Evaluator { fn evaluate(&self, input: &ActionInput) ->
  Result<ActionKey, Error>; }` (072's Execute, blocking until complete;
  results reach the cache through 074's hook), `trait GateVerifier { fn
  verify(&self, ids: &[AttestationId]) -> VerifiedAttestationSet; }`
  (064). For every target with `gate = true` in dependency order (075
  B-2): build the `ActionInput` (075 B-7) with dependency outputs taken
  from earlier results; `lookup(key, Gating, verified)`; on `Hit` record
  `Reused`; on any `Miss` call `evaluate`, refresh `verified` for the new
  entry's attestation, and look up again; a second miss is
  `TargetOutcome::Unattested` and counts as red. A hit whose result has
  `exit_code != 0` is `Red`. `BatchResult { batch, targets:
  BTreeMap<TargetId, TargetOutcome::{Green { key, reused: bool,
  attestation }, Red { key, attestation }, Unattested { key }}>, reused:
  u32, executed: u32 }`. `affected(trunk.tree, batch.tree)` (075 B-6) is
  computed first and recorded on the result; a test asserts that no target
  in `unchanged` is ever executed, which is the content-addressing
  guarantee made observable.
- **B-7 (bisection).** `resolve(batch, result, ...) -> Resolution`: an
  all-green batch is `Resolution::Merge(batch)`. A red batch of one member
  is `Resolution::Reject(member, Dequeue::Failed(red targets))`. A red
  batch of `n > 1` members splits into the prefix `[0, n/2)` and the
  suffix `[n/2, n)`, re-plans each as a batch on the same base in the same
  order (the prefix's tree is a prefix of the fold, the suffix is re-merged
  onto trunk), evaluates the prefix first, merges it if green, then
  evaluates the suffix on the new trunk; recursion continues until every
  member is merged or rejected. Total evaluations are `O(k log n)` for
  `k` failing members; a test pins the count for the fixtures.
- **B-8 (commit).** `Driver::step(&mut self) -> Result<StepReport, Error>`
  performs one plan, speculate, resolve cycle and appends, through the
  074 `LedgerAppend` seam in this order: `queue.dequeued` for every
  rejected candidate, then for a merge `change.merged` per member
  (024 `mark_merged`) followed by one `queue.merged`. A merge appends only
  when every gating target is `Green`; `evidence` lists their attestation
  ids so the merge is replayable evidence, not a log line. A concurrent
  `queue.merged` observed after planning (the trunk moved) discards the
  plan and the next step re-plans; nothing is appended twice.
- **B-9 (no ambient input).** The driver reads no clock; ordering comes
  from entry `Hlc`s and all time-dependent judgment (attestation
  freshness) lives in the verifier seam.

## 4. Functional requirements

- **FR-001.** Every function in `speculate.rs` is pure over its arguments
  and the seams; `tests/queue.rs` implements `Evaluator` with a
  `FakeExecution` that maps action keys to scripted outcomes, counts
  calls, and writes attested entries through an in-memory 071 cache using
  064's test constructor for the verified set.
- **FR-002.** Tests cover: the three facts round-trip canonically and
  `QueueView` orders by `(hlc, hash)`; admission refuses a superseded
  revision, a `Deny` verdict, a policy cid mismatch, and an unverified
  attestation; `merge_tree` for one-sided, identical, conflicting, and
  removed-versus-modified entries; a clean batch of three merges with one
  `queue.merged` and three `change.merged`; a batch with one failing
  member of eight bisects to exactly that member with the pinned
  evaluation count; a nondeterministic target executes on every step; an
  unattested execution never merges; reuse counts equal the `unchanged`
  set size on a second step with no new candidates; a moved trunk discards
  the plan.
- **FR-003.** `Driver` holds no state beyond what `QueueView` and
  `TrunkView` fold; a test rebuilds both from zero mid-run and continues
  with identical results.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-eval --locked queue` passes.
- **AC-2.** In the fixture with two candidates touching disjoint targets,
  the second step executes zero targets from `unchanged` and its
  `queue.merged.evidence` verifies through the 064 verifier.

## 6. Out of scope

Semantic or textual conflict resolution (052); ordering by stack
dependencies (050's `StackView` is consulted by a later amendment);
scheduling the driver and exposing queue status over the API (a server
spec over 093); the `hq queue` verbs (a later CLI spec); cross-host queue
coordination (a queue runs on the repository's control-plane leader, 091).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-eval --locked queue
```
