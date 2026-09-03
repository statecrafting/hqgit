---
id: "012-hash-stability-gate"
title: "Hash stability gate: fuzz targets, the golden-vector walk, and the cross-platform CI matrix"
status: approved
kind: "tooling"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "011-canonical-encoding"
establishes:
  - "fuzz/Cargo.toml"
  - "fuzz/fuzz_targets/codec_roundtrip.rs"
  - "fuzz/fuzz_targets/canonical_idempotent.rs"
  - "fuzz/fuzz_targets/value_ordering.rs"
  - "fuzz/corpus-seeds/"
  - "crates/hqgit-types/tests/golden.rs"
  - ".github/workflows/hash-stability.yml"
summary: >
  The gate that makes constitution VIII enforceable rather than aspirational.
  A standalone cargo-fuzz workspace with three targets over the canonical
  codec (decode-encode round trip, encode idempotence, key ordering) and a
  committed seed corpus; a golden test that walks every vector under the
  vector corpus and asserts byte and hash identity; and a CI workflow that
  runs the golden walk on Linux, macOS, and Windows, folds every vector file
  into one tree digest, asserts the digests agree across the matrix, and
  runs each fuzz target nightly with crash artifacts uploaded. A vector
  change fails the gate unless the PR carries a Schema-Major line and the
  amendment to the encoding spec: a human decision, never a regenerate.
---

# 012: Hash stability gate

## 1. Purpose

Thesis §6: hash stability of L0 and L1 is the only unrecoverable mistake,
so it is fuzzed in CI from the first commit. Spec 011 wrote the rules and
the vectors; this spec is the machinery that refuses a change to either
without a human deciding it. It sits before the object store (013) so that
no object or entry is ever encoded under a codec the gate has not held.
Spec 017 adds its entry target to this workspace and its vectors to the
walk; every later kernel spec that freezes bytes does the same.

## 2. Territory

The `fuzz/` cargo-fuzz workspace (its manifest, three targets, the seed
corpus), the golden walk `crates/hqgit-types/tests/golden.rs`, and the
workflow `.github/workflows/hash-stability.yml`. The `fuzz/` tree is its
own Cargo workspace (excluded from the root by spec 010 B-1 and discovered
by spec-spine through `standalone_rust_workspaces`). Later specs add
targets by extending `fuzz/Cargo.toml` (017 B-10 is the first).

## 3. Behavior

- **B-1 (fuzz workspace).** `fuzz/Cargo.toml` declares `[package] name =
  "hqgit-fuzz"`, `publish = false`, an empty `[workspace]` table so it is
  standalone, `[package.metadata.spec-spine] spec =
  "012-hash-stability-gate"`, `libfuzzer-sys` and a path dependency on
  `hqgit-types`, and one `[[bin]]` per target with `test = false`, `doc =
  false`. Targets MUST build with `cargo fuzz build` on the pinned nightly
  the workflow names and MUST compile as plain binaries under the stable
  toolchain with `--features no-fuzz` stubbing `fuzz_target!`, so `make
  build` never needs nightly.
- **B-2 (`codec_roundtrip`).** Input: arbitrary bytes. If `decode`
  succeeds, `encode(decode(b))` MUST equal `b` and `Hash::of` of both MUST
  agree; if `decode` fails, it MUST fail with `Error::Parse` and never
  panic. Any panic, including a stack overflow on deep nesting, is a
  finding.
- **B-3 (`canonical_idempotent`).** Input: an `Arbitrary` `Value`
  (derived through the `arbitrary` crate, floats impossible by
  construction). `decode(encode(v))` MUST equal `v` and `encode(v)` MUST be
  byte-stable across two calls.
- **B-4 (`value_ordering`).** Input: an arbitrary list of `(key, value)`
  pairs. Building a `Value::Map` in any insertion order MUST encode to one
  byte string; a decoded map with keys out of canonical order MUST be
  rejected; two maps differing only in insertion order MUST hash equal.
- **B-5 (golden walk).** `tests/golden.rs` walks
  `crates/hqgit-types/testdata/vectors/**/*.json` in sorted path order,
  applies spec 011 FR-003's check to each, prints the count of vectors
  checked, and fails on zero vectors (a missing corpus is a failure, not a
  pass). Every kernel spec that adds an area (017 `ledger/`, 027
  `attestation/`) is covered by this one walk without changes here.
- **B-6 (the freeze rule).** A pull request that modifies or deletes any
  file under `testdata/vectors/` MUST fail the workflow unless its body
  contains a line `Schema-Major: <spec-id> <old> -> <new>` naming the
  encoding spec amended and the MAJOR bump, and the diff touches that
  spec's `spec.md`. Adding a new vector file is allowed without the line.
  The check is a workflow step over `git diff --name-status` against the PR
  base and the PR body; it is a human decision made visible, never a
  regenerate.
- **B-7 (cross-platform matrix).** `hash-stability.yml` runs on
  `pull_request` and `push` to `main`: a job matrix over
  `ubuntu-latest`, `macos-latest`, `windows-latest` that runs `cargo test
  -p hqgit-types --locked golden`, then computes one tree digest
  (`sha256` over the sorted list of `<path>\0<bytes>` for every vector
  file, with CRLF folded to LF, mirroring spec-spine's own determinism
  gate) and uploads it as an artifact; a final job downloads the three
  digests and fails unless they are identical. The B-6 check runs in the
  Linux leg.
- **B-8 (nightly fuzzing).** A `schedule` trigger (daily) and
  `workflow_dispatch` run every target listed by `cargo fuzz list` for
  `FUZZ_MINUTES` (default 10) each, seeded from `fuzz/corpus-seeds/
  <target>/`, on the nightly toolchain the workflow pins; any artifact
  under `fuzz/artifacts/` is uploaded and the job fails. The seed corpus
  is committed and small (under 200 files, each under 4 KiB); the mutated
  corpus under `fuzz/corpus/` is gitignored.
- **B-9 (local smoke).** `make fuzz` (spec 001) runs each target for
  `FUZZ_SECONDS` when `cargo-fuzz` is installed and reports a skip
  otherwise; this spec's targets MUST pass that smoke.

## 4. Functional requirements

- **FR-001.** Each target is a single file that imports only `hqgit_types`
  and the fuzzing crates; no target reads the filesystem or the network.
- **FR-002.** The seed corpus contains, per target, at least: every
  vector's canonical bytes (for `codec_roundtrip`), one deeply nested
  value, one map with many keys of equal length, one value with a link, and
  one empty input.
- **FR-003.** The tree digest computation is a shell step small enough to
  read in one screen and is identical in every matrix leg; it uses no
  tool absent from a default runner image.
- **FR-004.** The workflow pins every third-party action by version and
  the nightly toolchain by date; a `dependabot` bump of either self-waives
  spec-spine's coupling gate (spec 001 B-3) but not this gate's semantics.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-types --locked golden` passes and prints a
  vector count of at least twenty.
- **AC-2.** With `cargo-fuzz` on the pinned nightly, `cargo fuzz run
  codec_roundtrip -- -max_total_time=20`, the same for
  `canonical_idempotent` and `value_ordering`, find no failure.
- **AC-3.** A fixture PR that edits one vector's `canonical_hex` without a
  `Schema-Major:` line fails the B-6 step; the same PR with the line and
  an edit to `specs/011-canonical-encoding/spec.md` passes it.

## 6. Out of scope

The codec rules themselves (011); entry-level fuzzing (017 B-10 extends
this workspace); the general CI gate (`govern.yml`, spec 001); fuzzing
above the codec (a future spec per crate as its bytes freeze).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-types --locked golden
sh -c 'command -v cargo-fuzz >/dev/null 2>&1 && cargo fuzz list | grep -q codec_roundtrip || echo "cargo-fuzz absent: target listing skipped"'
```
