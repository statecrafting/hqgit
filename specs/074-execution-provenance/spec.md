---
id: "074-execution-provenance"
title: "Execution provenance: every completed action emits a signed SLSA attestation"
status: approved
kind: "kernel"
domain: "l3-evaluation"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 5
depends_on:
  - "072-execution-service"
  - "064-attestation-verification"
establishes:
  - "crates/hqgit-eval/src/provenance.rs"
  - "crates/hqgit-eval/tests/provenance.rs"
  - "crates/hqgit-eval/testdata/slsa/"
extends:
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/src/lib.rs", nature: additive }
  # The provenance claim schema is SLSA Provenance v1, registered as a predicate.
  - { spec: "027-attestation-primitive", unit: "crates/hqgit-domain/src/predicate.rs", nature: additive }
summary: >
  CI results are not a separate system; they are evidence (thesis §4.4).
  This spec closes that loop: every completed execution emits an
  Attestation with predicate hqgit/provenance/v1 whose claim is a SLSA
  Provenance v1 predicate (builder = the executor's Service identity,
  buildType = the REAPI action, resolved dependencies = the input tree,
  command, and toolchain hashes, byproducts = the output digests, plus the
  sandbox report), signed by the executor and appended to the repository
  ledger as an attestation.issued fact. The cache entry (071) references
  that attestation, and verifying it through the trust plane (064) is
  exactly what turns a cache hit into a gating-grade hit. An execution
  whose sandbox report is missing gets no attestation and no cache entry.
---

# 074: Execution provenance

## 1. Purpose

Constitution IX: there is one evidence primitive, and a build result is
not exempt. Design §1.1 point 4 asks for every result to become an
attestation over (input hash, toolchain hash, output hash), and point 5
asks for in-toto/SLSA provenance linking source to artifact. Both are the
same object once the claim is SLSA Provenance v1 and the subject is the
action key. This spec is the hook (072 B-8) that mints it, and the reason
the action cache (071) can be a trust boundary rather than a hope.

## 2. Territory

`provenance.rs` in `crates/hqgit-eval` (the claim builder, the
`ProvenanceHook`, and the ledger append) and `tests/provenance.rs`, with
the SLSA v1 schema and expected statements vendored under
`testdata/slsa/`. Additively: the `hqgit/provenance/v1` claim validator in
spec 027's predicate registry and the crate's re-exports. The executor's
report is spec 073; the verification this attestation passes through is
spec 064.

## 3. Behavior

- **B-1 (predicate).** `PredicateType("hqgit/provenance/v1")` is
  registered with a claim validator; the claim object is the SLSA
  Provenance v1 predicate body, so `Attestation::to_in_toto()` (027)
  yields a statement any SLSA verifier reads with `predicateType =
  "https://slsa.dev/provenance/v1"`. The in-toto subject is the
  `ActionKey` hash under the name `hqgit:action`.
- **B-2 (claim mapping).** `build_claim(ctx: &CompletionContext, result:
  &ActionResult, report: &SandboxReport) -> ProvenanceClaim` fills:
  `buildDefinition.buildType = "https://hqgit.dev/buildtype/reapi-action/v1"`;
  `externalParameters = { action: <action digest>, target: <TargetId>,
  toolchain: <toolchain hash>, platform: <sorted properties> }`;
  `internalParameters = { sandbox_tier, isolation, rootfs, network,
  executor_version }` from the report; `resolvedDependencies = [ { name:
  "input-root", digest: { blake3: <tree cid hash> } }, { name: "command",
  digest }, { name: "toolchain", digest } ]` sorted by name;
  `runDetails.builder.id = "hqgit:service:<ServiceId hex>"` with
  `builder.version = { "hq-executor": <executor_version> }`;
  `runDetails.metadata.invocationId = <operation id>`, `startedOn` and
  `finishedOn` copied from `ExecutedActionMetadata.worker_start_timestamp`
  and `worker_completed_timestamp` (executor-supplied evidence, never a
  clock read in this crate); `runDetails.byproducts = [ every output file,
  directory, and symlink digest, then stdout and stderr digests ]` sorted
  by name; and `exit_code` as a top-level extension field. All digests are
  `{ "blake3": <hex> }`.
- **B-3 (signing and issuing).** `ProvenanceHook { signer: Box<dyn
  Signer>, executor: ExecutorIdentity, ledger: Box<dyn LedgerAppend> }`
  implements 072's `CompletionHook`: it validates the report (073 B-3),
  builds the claim, stores the claim as a DagCbor object in the repository
  object store, signs the `Attestation { subject: action key hash,
  predicate, issuer: Principal::Service(executor.service), issuer_key:
  executor.key, claim: Cid, at: <the completion Hlc from the ledger clock>,
  sig }` under `SignDomain("attestation")`, appends an
  `attestation.issued` fact through the `LedgerAppend` seam (which 021's
  `Repository::append_fact` implements, taking the namespace from the
  action's `hqgit.namespace` platform property), and returns the 071
  `CacheEntry` with `attestation: Some(id)` and `sandbox_tier` set.
- **B-4 (refusals).** A missing or under-tier sandbox report, an executor
  not present in the registry at completion time, a claim the predicate
  validator rejects, or a ledger append failure each return `Err` from the
  hook; the operation fails with the reason (072 B-8) and no cache entry is
  written. There is no unattested fallback in this hook: an operator who
  wants advisory-only results configures 072's `UnattestedHook` instead,
  visibly.
- **B-5 (gating grade).** The attestation's subject is the action key and
  its byproduct digests equal the entry's outputs, which is precisely what
  071 B-3 checks for a `Gating` hit once 064 has verified the executor's
  signature and identity. `gating_verified(entry, verified) -> bool` is
  provided here as the single implementation both the cache and the merge
  queue (076) call.
- **B-6 (determinism).** `build_claim` is a pure function of its
  arguments; two calls with the same inputs produce byte-identical claim
  objects and therefore one Cid. The only non-reproducible fields are the
  timestamps and operation id, which are inputs.

## 4. Functional requirements

- **FR-001.** `testdata/slsa/` holds the SLSA Provenance v1 JSON schema
  and an expected in-toto statement for a fixture completion; a test
  validates the emitted statement against the schema and compares it to
  the expectation field by field.
- **FR-002.** Tests cover: the hook mints, signs, appends, and returns an
  attested entry through a fake `LedgerAppend`; the attestation verifies
  through 064's verifier with a static resolver; `gating_verified` is true
  for the fixture and false when an output digest is altered; each B-4
  refusal fails the completion with no ledger append and no entry; claim
  determinism across two builds.
- **FR-003.** The `LedgerAppend` seam is a one-method trait (`fn
  append(&self, namespace: &Hash, fact: DomainFact) -> Result<EntryHash,
  Error>`) so tests never open a repository.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-eval --locked provenance` passes.
- **AC-2.** In the 072 fixture flow with the `ProvenanceHook` installed, a
  completed action yields a cache entry whose attestation verifies and
  whose `Gating` lookup is a hit; removing the report from the completion
  yields a failed operation and no entry.

## 6. Out of scope

Verification itself (064); transparency-log submission of the attestation
(062's client is wired by the server in 090 and later); provenance for
artifacts published outside the repository (release provenance is a later
spec); agent-action provenance (102).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-eval --locked provenance
```
