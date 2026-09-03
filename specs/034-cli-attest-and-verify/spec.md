---
id: "034-cli-attest-and-verify"
title: "hq attest and hq verify: issue any attestation, verify the chain and its evidence offline"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "033-cli-offline-review"
establishes:
  - "crates/hqgit-cli/src/cmd_attest.rs"
  - "crates/hqgit-cli/src/cmd_verify.rs"
  - "crates/hqgit-cli/tests/verify.rs"
extends:
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
summary: >
  Wave 1 ends when evidence produced offline verifies offline. hq attest
  issues an Attestation over any subject hash with any predicate, validating
  the claim against the registry when the predicate is known and carrying
  it verbatim when it is not; hq attest list enumerates the evidence on a
  subject. hq verify runs spec 017's chain verification against the
  repository with a resolver seeded from the keys the ledger itself
  records, reports every failure rather than the first, and exits 1 on any;
  hq verify attestation checks one attestation's signature and claim shape.
  Both verbs are pure reads apart from the fact hq attest appends, and both
  emit machine-readable reports so the orchestrator and CI can consume
  them.
---

# 034: hq attest and hq verify

## 1. Purpose

Constitution IX: all evidence is one primitive, and constitution XI: trust
is checkable, not decorative. Spec 033 issues one kind of evidence
(approval). This spec opens the primitive to every predicate from the
command line, so build results, scan findings, and mirrored facts can be
attached long before the evaluation plane (070 to 076) automates them, and
it gives the repository owner the verb that answers "is this ledger
intact?" with no server, no network, and no trust in anyone but the keys
the ledger records.

## 2. Territory

`cmd_attest.rs`, `cmd_verify.rs`, and `tests/verify.rs` in
`crates/hqgit-cli`; additively the dispatch in `main.rs` and the clap tree
in `cli.rs`. Full verification through identity rotation and transparency
inclusion is spec 064; this spec verifies what wave 1 can: signatures
against keys known to the ledger, hash links, clock rules, and claim
shapes.

## 3. Behavior

- **B-1 (`hq attest`).** `hq attest <subject> --predicate <uri> (--claim
  <file.json> | --claim -) [--note <text>]` where `<subject>` is a 64-hex
  hash or a Cid, reads the claim as JSON, converts it to the canonical
  `Value` of spec 011 (rejecting floats with exit `1` naming the key),
  validates it through spec 027's `PredicateRegistry` when the predicate is
  registered (`Error::Validation` on shape failure) and carries it verbatim
  otherwise, stores the claim as a `DagCbor` object, builds the Attestation
  with issuer the local principal and `issuer_key` the local key, signs it
  under `SignDomain("attestation")`, appends `attestation.issued`, and
  prints `{ "attestation": <AttestationId>, "subject", "predicate",
  "claim": <cid>, "known_predicate": bool }`.
- **B-2 (`hq attest list`).** `hq attest list <subject> [--predicate <uri>]`
  prints every attestation whose subject matches, in HLC order: id,
  predicate, issuer, issued-at, and `"verified": "signature" | "failed"`
  from a local signature check (B-5). `hq attest show <id>` prints one
  attestation with its decoded claim.
- **B-3 (`hq verify`).** `hq verify [--namespace <name>] [--strict]` loads
  the repository (021), builds a `StaticResolver` (017) from every public
  key the ledger records in `identity.created` and `identity.key_rotated`
  facts plus the local identity, runs spec 017 `verify` over the DAG, and
  additionally checks every `attestation.issued` fact's attestation
  signature and claim shape. It prints a `VerifyReport { "entries":
  <count>, "attestations": <count>, "failures": [ { "entry" | "attestation",
  "rule", "detail" } ], "unknown_keys": [<KeyId>] }`. Exit `0` when
  `failures` is empty, `1` otherwise. Without `--strict` an entry signed by
  a key the ledger does not know is listed under `unknown_keys` and does
  not fail; with `--strict` it does.
- **B-4 (never stops early).** Verification walks the whole DAG and every
  attestation and reports every failure; a tampered entry, a missing
  parent, a clock violation, a bad signature, and a malformed claim all
  appear in one run.
- **B-5 (`hq verify attestation`).** `hq verify attestation <id>` checks
  the signature against the issuer key (resolved as in B-3), the claim
  object's presence in the store, and the claim shape when the predicate is
  known, printing `{ "attestation", "signature": "ok" | "failed",
  "claim": "ok" | "unknown-predicate" | "failed", "detail" }`. Exit `1` on
  any `failed`.
- **B-6 (erased content).** A claim whose object was erased (020) reports
  `"claim": "erased"` and does not fail signature verification; the entry
  chain is unaffected by content erasure by construction.
- **B-7 (reports are data).** In JSON mode both verbs print exactly one
  document; in human mode `verify` prints one line per failure with the
  entry or attestation id, the rule name, and the detail, then a summary
  line.

## 4. Functional requirements

- **FR-001.** `tests/verify.rs` covers: attest with a known predicate and a
  valid claim; a claim with a float rejected; an unknown predicate carried
  verbatim and listed with `known_predicate: false`; `verify` clean on the
  spec 033 fixture ledger; `verify` after tampering one byte in a stored
  entry reports a hash failure; after deleting a parent object reports a
  missing parent; after forging an attestation with a foreign key reports a
  signature failure and, without `--strict`, an `unknown_keys` entry; after
  erasing a claim object reports `erased` and exits 0.
- **FR-002.** The command modules call spec 017 `verify` and spec 027
  `verify_signature` and never reimplement either.
- **FR-003.** `hq verify --json` output is byte-identical across two runs
  on an unchanged repository.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-cli --locked --test verify` passes.
- **AC-2.** On the spec 033 fixture session's ledger, `hq verify` exits 0
  and reports the approval attestation as verified; after `hq attest` with
  a build-result claim, `hq attest list <revision>` shows both.
- **AC-3.** Wave 1 milestone: the whole flow (`init`, `change`, `review`,
  `attest`, `verify`) runs with networking disabled in the test
  environment.

## 6. Out of scope

Rotation-aware and transparency-backed verification (060, 062, 064), policy
evaluation over the evidence (065, 067), remote attestation submission
(093), and evidence bundles (103).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-cli --locked --test verify
```
