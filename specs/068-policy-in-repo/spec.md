---
id: "068-policy-in-repo"
title: "Policy in the repository: pinned by fact, resolved by clock, no settings table"
status: approved
kind: "feature"
domain: "l6-policy"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 4
depends_on:
  - "067-policy-evaluation-attestation"
  - "021-local-repository"
establishes:
  - "crates/hqgit-policy/src/pin.rs"
  - "crates/hqgit-policy/src/scope.rs"
  - "crates/hqgit-policy/tests/pin.rs"
extends:
  - { spec: "065-policy-engine", unit: "crates/hqgit-policy/src/lib.rs", nature: additive }
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
  - { spec: "020-commitments-and-tombstones", unit: "crates/hqgit-ledger/src/tombstone.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cmd_policy.rs", nature: additive }
summary: >
  Where a repository's policy lives: in the ledger, as facts. A
  policy.pinned fact names a policy module Cid, a scope (a namespace or a
  path pattern), the clock from which it applies, and who pinned it;
  policy.unpinned retires one. The PolicyPinView fold answers
  active_policy(repo, at, scope): the policy that governs a revision is the
  one active at the revision's submission clock, so a decision recorded in
  wave 4 replays identically in wave 8 against the pin that was in force.
  There is no settings table to toggle, which is constitution XI made
  structural. The same fold is what lets a policy verdict mint the erase
  capability of spec 020 and what the agent authority of spec 100 compares
  its policy version against.
---

# 068: Policy in the repository

## 1. Purpose

Thesis §4.6 ends with the anti-pattern the design makes impossible:
repository settings as mutable UI toggles. A toggle is a row somewhere
outside the log, which constitution VI forbids, and it has no history,
which makes "why was this allowed to merge" unanswerable. This spec puts
the policy binding itself into the ledger, so the active policy at any
clock is a fold over facts, changing it is a signed fact by a principal
the repository recognizes, and the question of which policy governed a
revision has exactly one deterministic answer.

## 2. Territory

`pin.rs` (the facts' semantics, `PolicyPinView`, `active_policy`) and
`scope.rs` (`PolicyScope`, precedence) in `crates/hqgit-policy`, with
`tests/pin.rs`. Additively: the two fact kinds in 023's vocabulary, the
`EraseCapability::from_verdict` implementation hook in 020's
`tombstone.rs`, `hq policy pin|unpin|show` in 067's `cmd_policy.rs`, and
the crate re-exports.

## 3. Behavior

- **B-1 (facts).** `policy.pinned { policy: Cid, scope: PolicyScope,
  effective_from: Hlc, pinned_by: Principal, note: String }` and
  `policy.unpinned { pin: PinId, unpinned_by: Principal, note: String }`
  where `PinId = Hash` of the pinning fact's canonical bytes (023's
  content-derived id rule). Kind strings are frozen. The pinning
  principal MUST hold the `pin-policy` capability (094's capability
  vocabulary; on the wave 1 CLI the repository owner holds it by
  construction, 021) and the fact's signer MUST be that principal; a
  pin by anyone else is folded as `rejected` with the reason, never
  silently dropped.
- **B-2 (`PolicyScope`).** `enum PolicyScope { Namespace(Hash),
  Path(PathPattern) }` where `PathPattern` is a glob over tree paths
  (`crates/hqgit-ledger/**`) evaluated against the files a revision
  touches (024's tree delta). Precedence when several pins are active at
  one clock: the most specific path pattern wins over a less specific one
  (longest literal prefix, then fewest wildcards), and any path pin wins
  over the namespace pin; ties are broken by the later `effective_from`,
  then by `PinId`. Precedence is a pure function and its rules are a
  frozen vector.
- **B-3 (`PolicyPinView`).** A `DerivedState` (019) folding the two kinds
  in total order (018): `pins: BTreeMap<PinId, Pin>` with `Pin { policy,
  scope, effective_from, pinned_by, retired: Option<Hlc> }`. `active_policy
  (&self, at: &Hlc, scope: &ScopeQuery) -> Option<ActivePin>` returns the
  pin in force at `at` for the query (a namespace plus the touched paths),
  `None` when nothing is pinned, and `ActivePin { pin_id, policy, scope,
  effective_from }`. A pin is in force from `effective_from` until its
  retirement clock, exclusive.
- **B-4 (which clock).** The policy that governs a revision is
  `active_policy(revision.at, ...)`: the pin in force when the revision was
  submitted, not when the evaluation runs. Re-pinning a policy therefore
  never changes the verdict a shipped revision replays to (067 B-3), and a
  newly pinned policy applies to the next revision, never retroactively.
  Tests pin this with a revision submitted between two pins.
- **B-5 (no pin, no allow).** With `None` from `active_policy`, a gate
  (076, 092, 093) treats the revision as `Deny { reasons: ["no policy
  pinned for this scope"] }`. An unpinned repository cannot merge through a
  gate; the wave 1 CLI (`hq init`, 032) pins `allow_all.wasm` by default
  so local review is unaffected, and `hq status` shows the active pin.
- **B-6 (erase by verdict).** `EraseCapability::from_verdict(att:
  &AttestationId, view: &PolicyPinView, verified: &VerifiedAttestationSet)
  -> Result<EraseCapability, Error>` succeeds only when the attestation is
  a verified `hqgit/policy-eval/v1` with verdict `Allow`, whose policy Cid
  is the active pin for scope `Namespace(target namespace)` at the
  attestation's clock, and whose claim's `attestations_considered`
  includes an `hqgit/erasure-request/v1` attestation naming the target
  Cid. This is the second and last constructor of the capability (020
  B-6): erasure is either the owner's act or a policy's verdict.
- **B-7 (CLI).** `hq policy pin <cid|file.wasm> [--scope <ns|glob>]
  [--from <hlc>] [--note]` appends the fact (storing the module when given
  as a file); `hq policy unpin <pin-id>`; `hq policy show [--at <hlc>]
  [--json]` prints the active pin for the default namespace and every pin
  with its state. Exit codes per 032.
- **B-8 (determinism and honesty).** The fold is a pure function of the
  ordered facts; `active_policy` reads no clock. A rejected pin (B-1) is
  visible in `hq policy show` as `rejected: <reason>` so an operator sees
  the attempt, never a silent no-op.

## 4. Functional requirements

- **FR-001.** Tests cover: pin, unpin, and the in-force window; precedence
  vectors for path over namespace and specificity ordering; a revision
  between two pins governed by the earlier one; a pin by a principal
  without the capability folded as rejected; `from_verdict` succeeding on
  a matching verified verdict and failing on an unverified one, on a
  `Deny`, and on a policy that is not the active pin; fold-order
  independence (permuted facts, one state).
- **FR-002.** The default pin at `hq init` is a fact like any other,
  visible in `hq log` and replaceable by `hq policy pin`.
- **FR-003.** `hq policy show --json` is byte-identical across two runs.
- **FR-004.** The crate still depends only on `hqgit-types`,
  `hqgit-domain`, `hqgit-ledger`, and `hqgit-object` within the workspace
  (the `hqgit-ledger` dependency is new here, for the fold and the
  capability hook, and stays below `hqgit-trust`).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-policy --locked --test pin` passes.
- **AC-2.** On the 033 fixture, `hq policy pin two_approvals.wasm` then
  `hq policy eval <change>` records a `Deny`, `hq policy show` names the
  pin, and after `hq policy unpin` a new eval is refused with `no policy
  pinned`.

## 6. Out of scope

Server-side capability checks for `pin-policy` (094); agent-scoped policy
versions in tokens (100, 101); policy inheritance across federated peers
(112); a UI for pins (095 shows the active pin on a change).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-policy --locked
```
