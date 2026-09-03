---
id: "066-policy-sdk"
title: "Policy SDK: typed Rust policies compiled to WASM, testable natively"
status: approved
kind: "feature"
domain: "l6-policy"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 4
depends_on:
  - "065-policy-engine"
establishes:
  - "crates/hqgit-policy-sdk/Cargo.toml"
  - "crates/hqgit-policy-sdk/src/lib.rs"
  - "crates/hqgit-policy-sdk/src/prelude.rs"
  - "crates/hqgit-policy-sdk/src/evidence.rs"
  - "crates/hqgit-policy-sdk/src/export.rs"
  - "crates/hqgit-policy-sdk/src/testing.rs"
  - "crates/hqgit-policy-sdk/examples/allow_all.rs"
  - "crates/hqgit-policy-sdk/examples/two_approvals.rs"
  - "crates/hqgit-policy-sdk/examples/provenance_required.rs"
  - "crates/hqgit-policy-sdk/examples/no_self_approval.rs"
  - "crates/hqgit-policy-sdk/tests/"
extends:
  # The sample binaries under 065's testdata are rebuilt from these examples.
  - { spec: "065-policy-engine", unit: "crates/hqgit-policy/testdata/policies/", nature: additive }
summary: >
  Policies must be unit-testable code, not settings, and a policy author
  should never touch the WASM ABI by hand. This spec founds
  hqgit-policy-sdk: a no_std-capable library that a policy crate depends on
  to write `fn evaluate(&PolicyInput) -> Verdict` in plain Rust, an
  `hqgit_policy!` macro that emits spec 065's exports around it, typed
  query helpers over the attestation summaries (approvals by distinct
  humans, provenance present, issuer kinds, predicate presence) with no
  floating point anywhere, and a native test harness so the same function
  runs under `cargo test` on the host and under wasmtime in the engine with
  identical verdicts. Four example policies are the fixtures the engine
  tests and later specs (103) reuse.
---

# 066: Policy SDK

## 1. Purpose

Thesis §4.6: compile policies to WASM with a typed SDK so they are
unit-testable, hash-pinned, and evaluable locally before push. Spec 065
fixed the engine and the ABI; without an SDK every policy would hand-roll
memory allocation, canonical decoding, and result packing, and the first
subtle divergence between two policies' decoders would make verdicts
depend on which policy was asked. The SDK makes the decoder one shared
implementation, makes the policy body a pure Rust function, and makes
testing it a matter of calling that function.

## 2. Territory

`crates/hqgit-policy-sdk` as founded here: the manifest (`[package.
metadata.spec-spine] spec = "066-policy-sdk"`, `crate-type = ["rlib"]`,
no default features that require std so a policy crate can target
`wasm32-unknown-unknown`), `lib.rs`, `prelude.rs` (the re-exports a policy
imports with one `use`), `evidence.rs` (query helpers), `export.rs` (the
`hqgit_policy!` macro and the allocator shim), `testing.rs` (the native
harness), the four examples, and the `tests/` subtree. Additively, the
rebuilt sample binaries in 065's `testdata/policies/`. The engine's types
(`PolicyInput`, `Verdict`, `AttestationSummary`) are re-exported from
`hqgit-policy` behind its `types-only` feature so the SDK never links
wasmtime.

## 3. Behavior

- **B-1 (the policy function).** A policy crate declares
  `hqgit_policy!(evaluate);` where `fn evaluate(input: &PolicyInput) ->
  Verdict` is a plain function. The macro emits `#[no_mangle] extern "C"
  fn alloc(len: i32) -> i32`, `#[no_mangle] extern "C" fn evaluate(ptr:
  i32, len: i32) -> i64`, and the `memory` export, exactly the surface 065
  B-3 requires and nothing else. The generated `evaluate` decodes the
  input with the shared canonical decoder, calls the user function, encodes
  the verdict canonically, and packs the pointer and length. A decode
  failure returns `Verdict::Deny { reasons: ["sdk: input did not decode:
  <cause>"] }`.
- **B-2 (no ambient input).** The SDK exposes no clock, no randomness, and
  no I/O to a policy; the only time is `input.now` (065 B-4). A policy that
  needs entropy or the wall clock cannot be written with this SDK, on
  purpose. `#![forbid(unsafe_code)]` applies except for the single
  allocator shim in `export.rs`, which is the one audited `unsafe` block in
  the workspace and is documented as such in `Cargo.toml` lints overrides
  (010 B-1's `forbid` becomes `deny` for this crate only, with the
  exception named).
- **B-3 (`evidence.rs`).** Pure helpers over `&PolicyInput`, all integer
  arithmetic: `approvals(&PolicyInput) -> impl Iterator<Item =
  &AttestationSummary>` (predicate `hqgit/approval/v1`, subject the
  revision id, `claim_checked` true); `approvals_by_distinct_humans(&
  PolicyInput) -> u32`; `has_provenance_for_tree(&PolicyInput) -> bool`
  (predicate `hqgit/provenance/v1`, subject the revision tree); `issued_by
  (&PolicyInput, kind: PrincipalKind) -> impl Iterator`;
  `predicates_present(&PolicyInput) -> BTreeSet<PredicateType>`;
  `missing(&PolicyInput, required: &[&str]) -> Vec<String>` (the required
  predicates not present, in the given order); `submitted_by_agent(&
  PolicyInput) -> bool`; `self_approved(&PolicyInput) -> bool` (an approval
  whose issuer equals `revision.submitted_by`); `logged_only(&PolicyInput)
  -> impl Iterator` (attestations with `logged` true). Every helper ignores
  attestations whose `claim_checked` is false unless named `_unchecked`.
- **B-4 (`testing.rs`).** `evaluate_native(policy: fn(&PolicyInput) ->
  Verdict, input: &PolicyInput) -> Verdict` runs the function on the host;
  `input_fixture()` builders (`InputBuilder::new(change, revision)
  .approval_by(principal).provenance().build()`) produce inputs without a
  ledger; `assert_same_verdict(policy_fn, wasm_bytes, input)` runs both the
  native function and the compiled module through 065's engine and asserts
  byte-identical verdicts, which is the test every example ships with.
- **B-5 (examples).** `allow_all` (always `Allow`); `two_approvals`
  (`Allow` iff `approvals_by_distinct_humans >= 2`, else `Deny` naming the
  count); `provenance_required` (`Deny` unless `has_provenance_for_tree`);
  `no_self_approval` (`Deny` when `self_approved`, else the two-approvals
  rule). Each example is a policy crate in miniature: `hqgit_policy!` plus
  a `#[cfg(test)]` module using B-4.
- **B-6 (build recipe).** `cargo build -p hqgit-policy-sdk --examples
  --target wasm32-unknown-unknown --release --locked` produces
  `target/wasm32-unknown-unknown/release/examples/<name>.wasm`; the
  release profile for the wasm target sets `opt-level = "z"`, `lto = true`,
  `panic = "abort"`, and `strip = true` so the module has no imports and
  loads under 065 B-1. A `scripts/`-free rule: the recipe lives in this
  spec and in `hq policy build` (067), never in an ad-hoc script.
- **B-7 (reproducible modules).** Given the pinned toolchain (010 B-2) the
  compiled bytes of each example are reproducible; their sha256 values are
  recorded in 065's `testdata/policies/MANIFEST.txt`, and rebuilding them
  is how that manifest changes.

## 4. Functional requirements

- **FR-001.** Each example passes `assert_same_verdict` on at least two
  inputs (one `Allow`, one `Deny`).
- **FR-002.** Helper tests cover: approvals counted per distinct human,
  not per attestation; an agent-issued approval never counts as a human;
  `claim_checked = false` ignored; `missing` preserves order;
  `self_approved` true only on issuer equality.
- **FR-003.** A test builds the examples for `wasm32-unknown-unknown` when
  the target is installed and skips with a named reason otherwise; CI
  installs the target.
- **FR-004.** `cargo tree -p hqgit-policy-sdk --target
  wasm32-unknown-unknown` contains no `wasmtime` and no `std`-only crate.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-policy-sdk --locked` passes.
- **AC-2.** `cargo build -p hqgit-policy-sdk --examples --target
  wasm32-unknown-unknown --release --locked` succeeds and the four modules
  load under 065's `PolicyModule::load` with no imports.

## 6. Out of scope

Evaluating and recording verdicts (067); policy pinning (068); a policy
language other than Rust (a datalog or Rego front end would compile to the
same ABI as a later spec); the evidence-required example (103).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-policy-sdk --locked
cargo build -p hqgit-policy-sdk --examples --target wasm32-unknown-unknown --release --locked
```
