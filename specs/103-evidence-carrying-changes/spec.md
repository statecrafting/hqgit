---
id: "103-evidence-carrying-changes"
title: "Evidence-carrying changes: the bundle, the argument view, and the evidence_required policy"
status: approved
kind: "feature"
domain: "l6-policy"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 7
depends_on:
  - "102-agent-sandbox-and-provenance"
  - "067-policy-evaluation-attestation"
  - "051-semantic-deltas"
establishes:
  - "crates/hqgit-domain/src/evidence.rs"
  - "crates/hqgit-domain/tests/evidence.rs"
  - "crates/hqgit-domain/testdata/evidence/"
  - "crates/hqgit-policy-sdk/examples/evidence_required.rs"
  - "crates/hqgit-cli/src/cmd_evidence.rs"
  - "crates/hqgit-cli/tests/evidence.rs"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  # evidence.attached joins the vocabulary.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
  # property-test, invariant, and spec-conformance claim schemas register.
  - { spec: "027-attestation-primitive", unit: "crates/hqgit-domain/src/predicate.rs", nature: additive }
  # Query helpers the example policy uses.
  - { spec: "066-policy-sdk", unit: "crates/hqgit-policy-sdk/src/evidence.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
  # hqgit-trust and hqgit-agent join the CLI's manifest for verification.
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/Cargo.toml", nature: additive }
summary: >
  Design §1.1 point 7: as authoring cost approaches zero, trusted review
  capacity is the binding constraint, so a change should arrive carrying
  machine-checkable evidence and a human should review the argument
  rather than the diff. This spec names that argument: an EvidenceBundle
  is the set of attestations a revision carries (provenance, test and
  property-test results, invariant checks, semantic deltas, policy
  evaluations, agent actions, approvals, spec conformance), declared by
  an evidence.attached fact, each item classified by whether a machine or
  a human must check it and carrying its verification verdict. The CLI
  renders the argument with a throughput line (how much verified itself,
  how much needs a person), completeness is computed against a required
  predicate set, and the SDK example policy evidence_required denies a
  revision lacking one. Nothing here is a new noun: every item is an
  attestation (constitution IX).
---

# 103: Evidence-carrying changes

## 1. Purpose

Thesis §8 says the design optimizes verification throughput, and
constitution XII repeats it for agents. Throughput is a ratio a reviewer
can only act on if it is computed: of the claims this revision makes, how
many did the system already verify, how many failed, and how many wait on
a human. Specs 027 through 102 produced the claims; this spec assembles
them into one object with one honest count, puts the assembly on the
ledger as a fact so two reviewers see the same argument, and gives policy
a way to demand it before merge.

## 2. Territory

`evidence.rs` in `hqgit-domain` (the fact, `EvidenceBundle`,
checkability, throughput, completeness, the argument ordering),
`tests/evidence.rs` and fixtures under `testdata/evidence/`; the SDK
example `evidence_required.rs`; and `cmd_evidence.rs` with `tests/evidence.rs`
in the CLI. Additively: 023's `lib.rs` and `facts.rs`, three claim
schemas in 027's registry, helpers in 066's `evidence.rs`, and the CLI
frame and manifest. Verification itself stays in 064, 067, and 102; this
spec composes their verdicts.

## 3. Behavior

- **B-1 (predicates).** Three claim schemas register:
  `hqgit/property-test/v1 { suite: String, properties: Vec<{ name:
  String, cases: u32, passed: bool, counterexample: Option<String> }>,
  seed: Option<u64>, log: Option<Cid> }`; `hqgit/invariant/v1 { checker:
  String, invariants: Vec<{ name: String, holds: bool, detail:
  Option<String> }>, log: Option<Cid> }`; `hqgit/spec-conformance/v1 {
  specs: Vec<{ id: String, acceptance: Vec<String>, evidence:
  Vec<AttestationId> }> }` where `id` MUST match `^[0-9]{3}-[a-z0-9-]+$`
  and `acceptance` entries `^AC-[0-9]+$`. Lists are sorted by name or id.
- **B-2 (fact).** Frozen kind `evidence.attached { change: ChangeId,
  revision: RevisionId, attestations: Vec<AttestationId>, attached_by:
  Principal, extra }`: `attestations` sorted, deduplicated, non-empty, at
  most 256; every named attestation's `subject` MUST equal `revision`
  (validated by the CLI before append and by the bundle on assembly, where
  a mismatch is listed under `rejected`). Several facts for one revision
  merge by set union (constitution VII); there is no detach: a withdrawn
  claim stays visible with its verdict.
- **B-3 (checkability).** `Checkability::{Machine, Human}` by predicate:
  `provenance`, `test-result`, `property-test`, `invariant`,
  `semantic-delta`, `policy-eval`, `agent-action`, `static-finding`,
  `license`, `mirror`, and `code-index` are `Machine` (their verification
  is 064's chain plus, where one exists, a recomputation: 074
  `gating_verified`, 051's deterministic delta, 067 `replay`, 102
  `verify_agent_action`); `approval` and `spec-conformance` are `Human`;
  an unregistered predicate is `Human`. `checkability(&PredicateType) ->
  Checkability` is the one table.
- **B-4 (bundle).** `EvidenceBundle::assemble(revision: RevisionId,
  submitted_by: Principal, attached: &[EvidenceAttached], attestations:
  &BTreeMap<AttestationId, (Attestation, Value)>, registry:
  &PredicateRegistry) -> EvidenceBundle { revision, submitted_by, items:
  Vec<EvidenceItem { id, predicate, issuer, issuer_kind, checkability,
  claim_verdict: ClaimVerdict, verification: Verification, summary:
  String }>, rejected: Vec<(AttestationId, String)>, unavailable:
  Vec<AttestationId> }` is pure: `Verification` starts `Unverified` for
  every item; the composing binary calls `with_verdicts(&mut self,
  verdicts: &BTreeMap<AttestationId, Verification::{Ok, Failed(String)}>)`
  with 064's results and recomputation outcomes (081 B-3's pattern).
  `summary` is a fixed rendering per predicate (`"12 properties, 12
  passed"`, `"3 public items removed, 1 signature changed"`, `"chain
  root human:<hex8>"`), never claim text verbatim.
- **B-5 (throughput and completeness).** `Throughput { total: u32,
  machine_verified: u32, machine_failed: u32, needs_human: u32,
  unverified: u32 }` where `machine_verified` counts `Machine` items with
  `Ok`, `machine_failed` counts any `Failed`, `needs_human` counts
  `Human` items, and `unverified` the rest; the five sum to `total`.
  `Requirement { predicates: BTreeSet<PredicateType>, min_approvals:
  u32, agent_action_if_agent: bool }` with `Requirement::default_for(
  submitted_by)` = `{ provenance, semantic-delta, one of test-result or
  property-test }`, `min_approvals = 1`, and `agent_action_if_agent =
  true`. `completeness(&self, req) -> Completeness { satisfied:
  Vec<PredicateType>, missing: Vec<PredicateType>, approvals: u32,
  failed: Vec<AttestationId> }`; `complete()` is `missing` empty, enough
  approvals, and `failed` empty. Integers only.
- **B-6 (the argument).** `argument(&self) -> Vec<&EvidenceItem>` orders
  items by predicate rank (`provenance`, `agent-action`,
  `semantic-delta`, `property-test`, `invariant`, `test-result`,
  `policy-eval`, `static-finding`, `license`, `spec-conformance`,
  `approval`, then others alphabetically), then issuer, then id, so the
  deltas precede the line diff (design §1.1 point 3) and human claims
  come last.
- **B-7 (SDK).** 066's `evidence.rs` gains `predicates_present(&PolicyInput)
  -> BTreeSet<PredicateType>`, `missing(&PolicyInput, required: &[&str])
  -> Vec<String>`, and `submitted_by_agent(&PolicyInput) -> bool`. The
  example `evidence_required` requires `hqgit/provenance/v1`,
  `hqgit/semantic-delta/v1`, one of `hqgit/test-result/v1` or
  `hqgit/property-test/v1`, and `hqgit/agent-action/v1` when the revision
  was submitted by an agent, returning `Deny` with one reason per missing
  predicate (`missing evidence: <predicate>`) and `Allow` otherwise. It
  builds natively and to wasm32 per 066.
- **B-8 (CLI).** `hq evidence attach <change> [--revision N]
  <attestation-id>...` checks every id resolves and its subject is the
  revision (`Error::Validation` naming the id), then appends B-2 signed by
  the local identity and prints the fact's entry hash. `hq evidence show
  <change> [--revision N] [--require <pred>[,<pred>...]] [--json]`
  assembles the bundle from the ledger and object store, verifies every
  item through 064 with the `RotationAwareResolver` (060 B-7), recomputes
  the agent-action chain hash through 101 when the submitter is an agent,
  applies `with_verdicts`, and renders the argument one line per item
  (`<status> <predicate> <issuer-kind>:<hex8> <summary>`) followed by
  `evidence: <total> attached; machine-verified <n>, failed <n>, needs
  human <n>, unverified <n>; missing: <list or none>`. `--require`
  replaces the default requirement. Exit `0` when `complete()`, else
  `Error::Policy` (exit `1`); `--json` per 032 B-3.
- **B-9 (discipline).** `evidence.rs` reads no clock and performs no
  I/O; claim objects are passed in. No `HashMap`, no float.

## 4. Functional requirements

- **FR-001.** Fixtures under `testdata/evidence/`: a revision with eight
  attestations across the B-3 table (one agent-action with a fixture
  chain hash, one approval, one spec-conformance), two `evidence.attached`
  facts overlapping in ids, one attestation over another subject, and
  `expected-bundle.json`, `expected-argument.json`, `expected-throughput.json`.
- **FR-002.** Domain tests cover: union and deduplication across the two
  facts; the foreign-subject attestation lands in `rejected`; a missing
  claim object lands in `unavailable`; throughput sums to `total` before
  and after `with_verdicts`; `default_for` differs for an agent submitter
  and `completeness` reports `agent-action` missing; argument order
  equals the fixture; each B-1 validator accepts its fixture and rejects
  a malformed one (bad spec id, unsorted list, `passed` absent).
- **FR-003.** SDK tests run `evidence_required` natively and as wasm
  against fixtures: complete human revision allows; agent revision without
  agent-action denies with exactly that reason; one missing predicate per
  reason line.
- **FR-004.** CLI tests with `assert_cmd` on the 033 fixture: `attach`
  refuses a foreign-subject id; `attach` then `show` lists the items and
  exits 1 with `missing:` naming `hqgit/provenance/v1`; `show --require
  hqgit/approval/v1` exits 0 after `hq review approve`; `--json` output is
  byte-identical across two runs.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked evidence`, `cargo test -p
  hqgit-policy-sdk --locked evidence_required`, and `cargo test -p
  hqgit-cli --locked evidence` pass.
- **AC-2.** On the fixture, `hq evidence show --json` reports `{
  "machine_verified": 5, "machine_failed": 0, "needs_human": 2,
  "unverified": 0, "total": 7 }` after every machine item verifies.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Producing the evidence (051, 067, 074, 102, and the test runners that
issue test-result and property-test attestations from 075 targets, a
later feature spec); rendering the argument in the review UI (095
consumes the bundle through 093); pinning `evidence_required` as a
repository policy (068's fact, an operator act); ownership-based
requirements (104 with 065).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked evidence
cargo test -p hqgit-cli --locked evidence
```
