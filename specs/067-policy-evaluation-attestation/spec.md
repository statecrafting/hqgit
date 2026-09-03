---
id: "067-policy-evaluation-attestation"
title: "Policy evaluation as evidence: the policy-eval attestation, replay, and hq policy"
status: approved
kind: "kernel"
domain: "l6-policy"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 4
depends_on:
  - "065-policy-engine"
  - "034-cli-attest-and-verify"
establishes:
  - "crates/hqgit-policy/src/evaluate.rs"
  - "crates/hqgit-policy/src/replay.rs"
  - "crates/hqgit-cli/src/cmd_policy.rs"
  - "crates/hqgit-cli/tests/policy.rs"
extends:
  - { spec: "065-policy-engine", unit: "crates/hqgit-policy/src/lib.rs", nature: additive }
  - { spec: "027-attestation-primitive", unit: "crates/hqgit-domain/src/predicate.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/Cargo.toml", nature: additive }
summary: >
  A merge decision is evidence, not a moment. Every engine evaluation
  (065) is recorded as an Attestation with predicate hqgit/policy-eval/v1
  whose claim names the policy Cid, the input hash, the engine
  configuration digest, and the verdict, signed by the evaluating
  principal and appended as a fact. A gate consumes that attestation,
  never a live evaluation, so the decision that let a revision merge can be
  produced years later and replayed: this spec's replay rebuilds the input
  from the ledger, re-runs the pinned policy, and reports Match, Mismatch
  with the differing bytes named, or Unavailable when an input was erased.
  The CLI grows hq policy eval, replay, and build so the whole loop runs
  offline on a laptop before anything is pushed.
---

# 067: Policy evaluation as evidence

## 1. Purpose

Constitution XI: every merge decision is replayable against the exact
policy that produced it. Thesis §4.6 makes the mechanism explicit: policy
evaluation emits an attestation. Spec 065 can evaluate; this spec makes the
evaluation durable and honest. It also closes the loop that constitution
IX promised: a policy verdict is the same primitive as a human approval or
a build's provenance, stored, verified (064), and queried through one path.
The merge queue (076), the git endpoint (092), and the API (093) gate on
the presence of a verified `policy-eval` attestation with `Allow`; none of
them evaluates anything themselves.

## 2. Territory

`evaluate.rs` (`evaluate_and_attest`, the claim schema builder) and
`replay.rs` (`replay`, `ReplayResult`) in `crates/hqgit-policy`;
`cmd_policy.rs` and `tests/policy.rs` in `crates/hqgit-cli`. Additively:
the `hqgit/policy-eval/v1` claim validator registered in 027's
`predicate.rs`, the crate re-exports, and the CLI frame (032's `main.rs`,
`cli.rs`, and manifest for the `hqgit-policy` dependency). Which policy is
active for a revision is 068's question; this spec takes a policy Cid as
input.

## 3. Behavior

- **B-1 (claim schema).** The `hqgit/policy-eval/v1` claim is the map
  `PolicyEvalClaim { policy: Cid, policy_version: u16, input_hash: Hash,
  engine_config: Hash, sdk_abi: u16, verdict: Verdict, fuel_used: u64,
  attestations_considered: Vec<AttestationId> }`, canonical (011).
  `attestations_considered` is the sorted id list of the verified set the
  input was built from, so a replay can detect a set that has since gained
  or lost members. The 027 validator for this predicate checks every field
  is present and `verdict` decodes.
- **B-2 (`evaluate_and_attest`).** `evaluate_and_attest(engine, module,
  input: PolicyInput, signer: &impl Signer, issuer: Principal, store: &mut
  impl ObjectStore) -> Result<(Attestation, Evaluation), Error>`: runs
  065 B-6, builds the claim, puts the claim object (013), and signs an
  Attestation whose `subject` is the revision id from `input.revision.id`
  (the thing being gated) and whose `issuer` is the evaluating principal
  (a `Service` on a server, the local human or agent identity on the CLI).
  The caller appends the resulting `attestation.issued` fact (023). A
  `Deny` is attested exactly like an `Allow`: refusals are evidence too.
- **B-3 (`replay`).** `replay(att: &Attestation, claim: &PolicyEvalClaim,
  ledger: &impl LedgerRead, store: &impl ObjectStore, engine: &Engine) ->
  ReplayResult` where `ReplayResult` is `Match { verdict }`, `Mismatch {
  recorded: Verdict, recomputed: Verdict, input_hash_recorded: Hash,
  input_hash_recomputed: Hash, first_difference: String }`, or
  `Unavailable { missing: Vec<Cid> }`. Replay loads the policy module by
  its recorded Cid (a different module hash is `Mismatch` at once), rebuilds
  the `PolicyInput` from the ledger's state at the attestation's `at`
  (the change and revision as of that HLC, and exactly the attestations in
  `attestations_considered`, re-summarized), compares `input_hash`, and
  re-evaluates only when the hashes match. An erased claim object (020) or
  a missing policy object is `Unavailable`, never a mismatch.
- **B-4 (engine pinning).** When `claim.engine_config` differs from the
  replaying engine's `config_digest()`, replay proceeds but the result
  carries `engine_differs: true`; a `Mismatch` under a different engine is
  reported as such rather than as a policy defect. `sdk_abi` mismatch is a
  hard `Unavailable` with the reason named (the ABI is frozen at 1 in this
  wave).
- **B-5 (`hq policy eval`).** `hq policy eval <change> [--revision <n>]
  --policy <cid|file.wasm> [--strict|--offline] [--json]`: loads the
  revision, verifies the attestations on it through 064 under the chosen
  `VerifyPolicy` (offline by default on the CLI), builds the input with
  `now` = the newest entry's HLC, evaluates, attests with the local
  identity, appends the fact, and prints the verdict with its reasons.
  Exit `0` on `Allow`, `1` on `Deny` (the verdict is the result, not an
  error), `3` on I/O or a module that fails to load. `--dry-run` evaluates
  without attesting.
- **B-6 (`hq policy replay`).** `hq policy replay <attestation-id>
  [--json]` prints `match`, `mismatch` with the first difference, or
  `unavailable` with the missing Cids. Exit `0` on match, `1` on mismatch,
  `2` on unavailable.
- **B-7 (`hq policy build`).** `hq policy build <crate-dir> [--out
  <file>]` runs the 066 B-6 recipe through `cargo` for the named policy
  crate, verifies the output loads under 065 with no imports, prints the
  module's Cid, and with `--store` puts it into the repository's object
  store so `--policy <cid>` resolves. It shells out to `cargo` only; it
  never fetches.
- **B-8 (gates consume, never evaluate).** A consumer that needs a
  decision asks the ledger for a verified `hqgit/policy-eval/v1`
  attestation on the revision whose `policy` equals the active policy
  (068) and whose verdict is `Allow`; absence is a `Deny` for gating
  purposes. This rule is stated here and referenced by 076, 092, and 093;
  none of them may call `Engine::evaluate` directly.

## 4. Functional requirements

- **FR-001.** Tests cover: the claim round trip and validator; evaluate
  then replay on an unchanged ledger is `Match`; amending the verified set
  (one more approval appended after the evaluation) is a `Mismatch` naming
  `attestations_considered`; erasing the claim object is `Unavailable`; a
  substituted policy module is `Mismatch` at the module stage; a `Deny`
  is attested with its reasons intact.
- **FR-002.** CLI tests drive `hq policy eval` on the spec 033 fixture
  ledger with `two_approvals.wasm`: one approval exits `1` with the reason,
  two approvals exit `0`, and `hq attest list <revision>` then shows the
  policy-eval attestation; `hq policy replay` on it exits `0`.
- **FR-003.** `--json` output is byte-identical across two runs of the
  same command on the same ledger.
- **FR-004.** `hq policy build` is tested only when a `wasm32-unknown-
  unknown` target is installed; otherwise the test skips with the reason
  printed.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-policy --locked` and `cargo test -p
  hqgit-cli --locked --test policy` pass.
- **AC-2.** On the 033 fixture, `hq policy eval <change> --policy
  two_approvals.wasm` records a `Deny`, a second approval is issued, a
  second eval records an `Allow`, and `hq policy replay` on both
  attestations reports `match`.

## 6. Out of scope

Choosing the active policy (068); server-side evaluation triggers (093);
the merge queue's use of verdicts (076); evaluating policies inside the
web UI (095 renders verdicts it reads).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-policy --locked
cargo test -p hqgit-cli --locked --test policy
```
