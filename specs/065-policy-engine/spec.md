---
id: "065-policy-engine"
title: "Policy engine: deterministic WASM merge predicates, hash-pinned"
status: approved
kind: "kernel"
domain: "l6-policy"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 4
depends_on:
  - "027-attestation-primitive"
  - "024-change-and-revision"
establishes:
  - "crates/hqgit-policy/Cargo.toml"
  - "crates/hqgit-policy/src/lib.rs"
  - "crates/hqgit-policy/src/engine.rs"
  - "crates/hqgit-policy/src/abi.rs"
  - "crates/hqgit-policy/src/module.rs"
  - "crates/hqgit-policy/src/input.rs"
  - "crates/hqgit-policy/tests/"
  - "crates/hqgit-policy/testdata/policies/"
extends:
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The merge predicate as the thesis states it: f(change, attestation_set,
  policy_version) -> Allow | Deny(reasons), deterministic and side-effect
  free. This spec founds hqgit-policy: a policy is a WebAssembly module
  stored as a content-addressed object whose Cid is its version; the engine
  is wasmtime configured for determinism (no clocks, no randomness, no
  filesystem, no network, no threads, fuel and memory limits, canonical
  NaNs); the ABI is one exported function taking the canonical bytes of a
  PolicyInput and returning the canonical bytes of a Verdict; and the input
  is built from domain types plus the attestation summaries of a verified
  set. Same input bytes and same module hash give the same output bytes,
  which is what makes a verdict replayable years later (067). Writing
  policies is the SDK's job (066); pinning them to a repository is 068's.
---

# 065: Policy engine

## 1. Purpose

Thesis §4.6 and decision D13: "requires two approvals" must stop being UI
state and become a checkable predicate over the evidence graph, expressed
as versioned executable code. Constitution XI forbids repository settings
as mutable toggles. That requires a policy to be a thing with a hash, an
evaluator that cannot smuggle in a clock or a network call, and an input
whose bytes are reproducible from the ledger. This spec supplies all three
and nothing else: it does not decide which policy governs a repository
(068) and does not record what a policy decided (067).

## 2. Territory

`crates/hqgit-policy` as founded here: the manifest (`[package.metadata.
spec-spine] spec = "065-policy-engine"`), `lib.rs`, `engine.rs` (the
wasmtime host), `abi.rs` (the wire contract and the `Verdict` type),
`module.rs` (loading, validating, and hashing a policy module), `input.rs`
(building a `PolicyInput` from domain types), the `tests/` subtree, and
prebuilt policy modules under `testdata/policies/` with their source
recorded beside them. Additively: `wasmtime` joins the workspace
dependency table. The crate depends on `hqgit-types` and `hqgit-domain`
only; it never depends on `hqgit-trust`, because it consumes the verified
set as data (064 B-5) and the caller is responsible for having verified it.

## 3. Behavior

- **B-1 (`PolicyModule`).** A policy is a core WebAssembly module (not a
  component) compiled for `wasm32-unknown-unknown`, stored as a `Raw`
  object (013) so `PolicyId = Cid` is its version. `PolicyModule::load
  (bytes) -> Result<PolicyModule, Error>` validates the binary, refuses any
  import (`Error::Policy("policy imports are forbidden: <name>")`), and
  requires exactly the exports of B-3. The Cid is recomputed from the bytes
  on load and compared to the caller's expectation when given.
- **B-2 (engine configuration).** `Engine::new(limits: Limits) -> Engine`
  builds a `wasmtime::Config` with: `consume_fuel(true)`,
  `cranelift_nan_canonicalization(true)`, `wasm_threads(false)`,
  `wasm_simd(false)`, `wasm_relaxed_simd(false)`, `wasm_bulk_memory(true)`,
  `wasm_reference_types(false)`, `epoch_interruption(false)`, `static
  memory maximum = limits.memory_bytes`, and no WASI at all: no clock, no
  randomness, no filesystem, no network, no environment reach the module.
  `Limits { fuel: u64 (default 50_000_000), memory_bytes: u64 (default
  64 MiB), output_bytes: u32 (default 1 MiB) }`. The configuration is
  exposed as `Engine::config_digest()`, a hash of every knob, so a verdict
  records the engine it ran under.
- **B-3 (ABI).** The module MUST export `memory`, `alloc(len: i32) ->
  i32`, and `evaluate(ptr: i32, len: i32) -> i64`. The host writes the
  canonical bytes (011) of `PolicyInput` into memory obtained from
  `alloc`, calls `evaluate`, and reads the result as a packed
  `(ptr: u32 << 32) | len: u32` pointing at the canonical bytes of a
  `Verdict`. An `evaluate` that traps, exhausts fuel, exceeds
  `output_bytes`, or returns bytes that do not decode as a `Verdict` yields
  `Verdict::Deny { reasons: ["engine: <cause>"] }`, never an error to the
  caller: a policy that cannot run cannot allow.
- **B-4 (`PolicyInput`).** `PolicyInput { v: u16, change: ChangeSummary,
  revision: RevisionSummary, attestations: Vec<AttestationSummary>,
  policy: Cid, policy_version: u16, now: Hlc }` where
  `ChangeSummary { id, opened_by, state, stack_depth }`, `RevisionSummary {
  id, number, tree, base, submitted_by, at }`, and `AttestationSummary {
  id, subject, predicate, issuer, issuer_kind: PrincipalKind, at,
  claim: Value, claim_checked: bool, logged: bool, keyless: bool }`.
  `now` is the HLC of the fact that triggers the evaluation, never a clock
  read. `input.rs` builds it: `build_input(change: &Change, revision:
  &Revision, verified: &VerifiedAttestationSetView, policy: Cid, now: Hlc)
  -> PolicyInput`, where `VerifiedAttestationSetView` is the plain-data
  projection of 064's set (its `ok` half only) that `hqgit-domain` can
  express without depending on `hqgit-trust`. `attestations` MUST be
  sorted by id; `input_hash(&PolicyInput) -> Hash` is the hash of its
  canonical bytes.
- **B-5 (`Verdict`).** `enum Verdict { Allow, Deny { reasons: Vec<String>
  } }` with canonical encoding as the map `{ "verdict": "allow" }` or `{
  "verdict": "deny", "reasons": [...] }`; `reasons` non-empty and each
  reason at most 512 bytes (longer reasons are truncated by the host with a
  trailing marker, never dropped). An empty `reasons` on `Deny` decodes as
  `Deny { reasons: ["policy gave no reason"] }`.
- **B-6 (`evaluate`).** `Engine::evaluate(&self, module: &PolicyModule,
  input: &PolicyInput) -> Evaluation { verdict: Verdict, fuel_used: u64,
  input_hash: Hash, policy: Cid, engine_config: Hash }`. Each call
  instantiates a fresh store: no state survives between evaluations, and
  the same `(module, input)` pair yields byte-identical verdict bytes.
- **B-7 (sample policies).** `testdata/policies/` holds prebuilt modules
  with their SDK source beside them (066 builds them; this spec commits the
  binaries and their sha256 so the engine tests need no wasm toolchain):
  `allow_all.wasm`, `deny_all.wasm`, `two_approvals.wasm` (Allow iff at
  least two `hqgit/approval/v1` attestations from distinct `Human` issuers
  whose subject is the revision), `deny_unattested.wasm` (Deny unless a
  `hqgit/provenance/v1` attestation covers the revision tree), and
  `burn_fuel.wasm` (loops forever, for the fuel test).
- **B-8 (no ambient input).** The crate reads no clock and no environment;
  `now` comes from the caller as data. The source guard of 010 FR-003
  applies.

## 4. Functional requirements

- **FR-001.** Tests cover: determinism (two evaluations of one input give
  identical bytes and identical `input_hash`); the ABI round trip with
  each sample policy; a module with an import refused at load; fuel
  exhaustion yielding `Deny` with an `engine:` reason; an oversized output
  yielding `Deny`; a trapping module yielding `Deny`; `attestations`
  ordering independence (permuted input yields the same `input_hash`
  because the builder sorts); `Verdict` canonical encoding vectors.
- **FR-002.** `Engine::config_digest()` is stable across runs and changes
  when a limit changes (golden fixture).
- **FR-003.** The sample module binaries carry recorded sha256 values in
  `testdata/policies/MANIFEST.txt` and a test verifies them, so a rebuilt
  module that differs is noticed.
- **FR-004.** The crate depends on `hqgit-types` and `hqgit-domain` only
  within the workspace; a test asserts `hqgit-trust` is not in `cargo
  metadata`'s resolve for this package.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-policy --locked` passes.
- **AC-2.** `two_approvals.wasm` evaluated over a fixture input with one
  approval yields `Deny` naming the shortfall, and with two approvals from
  distinct humans yields `Allow`; the two verdict byte strings match the
  recorded fixtures.

## 6. Out of scope

Authoring policies (066); recording a verdict as an attestation and
replaying it (067); which policy is active for a repository or path
(068); capability-based authorization for agents (101); any WASI surface.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-policy --locked
```
