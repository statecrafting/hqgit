---
id: "104-ownership-and-sla"
title: "Ownership with delegation, expiry, and SLA: facts that replace CODEOWNERS"
status: approved
kind: "feature"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 7
depends_on:
  - "028-issues-and-derived-state"
  - "060-identity-and-key-rotation"
  - "025-semantic-anchors"
establishes:
  - "crates/hqgit-domain/src/ownership.rs"
  - "crates/hqgit-domain/tests/ownership.rs"
  - "crates/hqgit-domain/testdata/ownership/"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  # The reserved ownership.declared and ownership.revoked bodies get their shape here.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  Ownership today is a text file with no SLA, delegation, or expiry
  (design §1.1 point 8). Here it is a set of facts: ownership.declared
  names a scope (a path pattern, a semantic anchor, or a crate), an
  owner, an optional delegator, an optional expiry, and an optional
  review SLA; ownership.revoked ends a declaration. OwnershipView folds
  them and answers owners_of(path, at) with expiry honored, revocations
  applied, delegation chains resolved to an accountable Human or Org
  root, and the most specific scope winning by an integer weight. Agents
  and services may hold delegated ownership but never a root, which is
  the other half of the accountability chain wave 7 builds. A CODEOWNERS
  import is a helper that emits facts; feeds (085) and policy (065) read
  the view, never the file.
---

# 104: Ownership and SLA

## 1. Purpose

Constitution XII makes an agent a distinct principal whose credential
carries its delegation chain; ownership is where that chain meets the
tree. Who must review a change to `crates/hqgit-trust/` is today a line
in CODEOWNERS with no notion of "until when", "on whose authority", or
"how fast". This spec makes ownership a fold over facts (constitution
VII) so that a delegation to an agent expires, a revoked human takes
every delegate down with them, and an SLA is data a feed can rank on.
Thesis §4.5 fixes identity as a keypair with a chain (060); this spec
consumes that identity model without importing the trust crate
(constitution XIII: `hqgit-domain` sits below `hqgit-trust`).

## 2. Territory

`ownership.rs` in `crates/hqgit-domain` (scopes and patterns, the
declaration and view, delegation and SLA resolution, the builders, the
CODEOWNERS import), `tests/ownership.rs`, and fixtures under
`testdata/ownership/`. Additively: `lib.rs` re-exports and the typed
bodies of `ownership.declared` and `ownership.revoked` in `facts.rs`,
replacing the opaque `Value` 023 reserved.

## 3. Behavior

- **B-1 (facts).** `ownership.declared { scope: OwnershipScope, owner:
  Principal, delegated_by: Option<Principal>, expires: Option<Hlc>, sla:
  Option<Sla>, nonce: Nonce, extra }` mints `DeclarationId =
  Hash::of(canonical body)` (023 B-3, a new newtype in `ownership.rs`).
  `ownership.revoked { declaration: DeclarationId, reason: String, extra
  }`. `Sla { review_within_hours: u32, extra }`. Validation (023 B-4
  extended): a `Path` pattern non-empty, free of NUL and `[`, and at most
  1024 bytes; a `Crate` name matching `^[A-Za-z0-9_-]+$`;
  `review_within_hours` in `1..=8760`; `delegated_by != owner`.
- **B-2 (scopes and patterns).** `OwnershipScope` is `Path(PathPattern) |
  Anchor(Anchor) | Crate(String)`. `PathPattern(String)` uses CODEOWNERS
  syntax over repo-relative POSIX paths: `/` splits segments, `**` matches
  zero or more segments, `*` any run within a segment, `?` one character;
  a pattern with no `/` matches in any directory (`*.rs` is `**/*.rs`); a
  trailing `/` means the directory and everything under it; a leading `/`
  anchors at the root and is stripped. `matches(&self, path: &str) ->
  bool` is a hand-written matcher (no regex crate). `Crate(name)` resolves
  through a caller-supplied `CrateIndex(BTreeMap<String, String>)` (crate
  name to directory) to the pattern `<dir>/**`; the index is content
  derived from a tree, so the caller builds it (033 or 090 through 051's
  manifest parser) and the view never reads a tree.
- **B-3 (specificity weight).** `weight(scope, crates) -> Option<u32>`:
  `Path`: `1_000 * literal_segments + min(literal_bytes, 999)` where a
  literal segment contains no wildcard; `Crate`: the weight of its
  resolved pattern minus 1 (an explicit path declaration beats the crate
  declaration for the same directory), `None` when unresolved; `Anchor`:
  `10_000_000 + node_path.len()`. Integer arithmetic only.
- **B-4 (`OwnershipView`).** Implements `DerivedState` (019 B-5):
  `declarations: BTreeMap<DeclarationId, Declaration>`, `by_owner:
  BTreeMap<Principal, BTreeSet<DeclarationId>>`, `warnings:
  Vec<OwnershipWarning>`. `Declaration { id, scope, owner, delegated_by,
  declared_at: Hlc, declared_by_key: KeyId, expires, sla, revoked:
  Option<(Hlc, String)> }`; `declared_by_key` is the fact's issuer (019
  B-1), recorded so policy and the UI can show who declared, while the
  authority of that key over `owner` or `delegated_by` remains the trust
  plane's check (023 B-6). A revocation of an unknown declaration is
  `OwnershipWarning::RevokeUnknown`; a second revocation is ignored and
  the first in total order stands; `expires <= declared_at` is
  `OwnershipWarning::ExpiresBeforeDeclared` and the declaration is never
  active. The fold rejects nothing.
- **B-5 (activity and delegation).** A declaration is active at `at`
  iff `declared_at <= at`, `at < expires` when set, `at < revoked.0` when
  revoked, and its chain is valid at `at`. A root declaration
  (`delegated_by: None`) MUST have a `Human` or `Org` owner (010 B-6);
  otherwise `OwnershipWarning::RootNotAccountable` and never active. A
  delegated declaration is valid iff its delegator held, at
  `declared_at`, an active declaration whose scope covers the delegated
  scope (`covers(outer, inner)`: identical, or `outer` ends in `**` and
  `inner`'s literal prefix matches it, or `inner` is an `Anchor` whose
  `path` `outer` matches; conservative, `false` when unsure); that
  declaration is the parent link, chosen by greatest weight then lowest
  id among candidates; the chain is re-checked at every query `at`, so
  revoking or expiring a parent deactivates the subtree from that `Hlc`.
  Depth is capped at `MAX_DELEGATION_DEPTH = 8`
  (`OwnershipWarning::DelegationTooDeep`). `Agent` and `Service` owners
  may only appear as delegates.
- **B-6 (`PrincipalStatus` seam).** `trait PrincipalStatus { fn
  active_at(&self, principal: &Principal, at: &Hlc) -> bool; }` with
  `AlwaysActive` provided. The trust plane's `IdentityView` (060 B-5)
  satisfies it through an adapter that lives with the wiring in the CLI
  (034) and the server (090), so a frozen or unknown identity is skipped
  without inverting the crate direction. An inactive principal anywhere
  in a chain deactivates the chain at `at`.
- **B-7 (queries).** `owners_of(&self, path: &str, at: &Hlc, crates:
  &CrateIndex, status: &dyn PrincipalStatus) -> Vec<Owner>` returns every
  active matching declaration as `Owner { principal, declaration:
  DeclarationId, root: Principal, chain: Vec<DeclarationId>, weight: u32,
  expires: Option<Hlc>, sla: Option<Sla> }` sorted by `(weight desc,
  principal)`; `expires` is the minimum over the chain and `sla` is the
  owner's own or the nearest ancestor's. `primary_owners` keeps the
  maximum weight only (most specific scope wins). `owners_of_anchor(anchor,
  ..)` ranks `Anchor` scopes whose `path` equals and whose `node_path` is
  a prefix of the anchor's above every path scope, else falls back to
  `owners_of(anchor.path)`. `explain(path, at, crates, status) ->
  Vec<(DeclarationId, Disposition)>` lists every declaration with
  `Disposition` `Applied(u32) | NoMatch | NotYet | Expired | Revoked |
  DelegationInvalid(String) | CrateUnresolved | PrincipalInactive`, so no
  answer is silent. `sla_deadline(owner: &Owner, requested_at: &Hlc) ->
  Option<Hlc>` is `wall_ms + hours * 3_600_000` (saturating), `logical
  0`, the request's node.
- **B-8 (builders and write-path checks).** `declare(scope, owner,
  delegated_by, expires, sla, nonce) -> (DeclarationId, DomainFact)` and
  `revoke(declaration, reason) -> DomainFact` are pure. `check_declaration
  (view, at, scope, owner, delegated_by, crates, status) -> Result<(),
  Error>` runs B-5 ahead of appending so the CLI refuses an unaccountable
  root, a delegation outside scope, or excess depth with
  `Error::Validation`; the fold still accepts whatever arrives.
- **B-9 (CODEOWNERS import).** `import_codeowners(text: &str, resolve:
  &dyn Fn(&str) -> Option<Principal>, nonces: &mut dyn FnMut() -> Nonce)
  -> ImportReport { facts: Vec<DomainFact>, unresolved: Vec<(u32, String)>
  }` parses comments, blank lines, one pattern per line followed by
  handles (`@user`, `@org/team`, an email), emits one root declaration per
  `(pattern, owner)` with no expiry and no SLA, and lists every handle
  `resolve` returned `None` for by line, never guessing. Precedence
  differs from GitHub's last-match rule (B-3 is most-specific); the
  report's `precedence_note: String` says so verbatim.
- **B-10 (no ambient input).** No clock, environment, randomness,
  `HashMap`, or float; the caller supplies `at`, `nonce`, and the crate
  index (010 B-11, 023 B-7).

## 4. Functional requirements

- **FR-001.** Tests: `at == expires` is inactive and `at == expires - 1
  logical` is active; a delegation chain of depth 8 resolves and depth 9
  warns; `primary_owners` picks `crates/x/src/**` over `crates/**` over
  `Crate("x")`; an `Anchor` scope beats every path scope for its node and
  not for a sibling; delegation outside the delegator's scope is
  `DelegationInvalid`; a root owned by an `Agent` is `RootNotAccountable`;
  effective `expires` is the chain minimum and SLA inherits; revoking the
  root deactivates delegates from the revocation `Hlc` and not before;
  `PrincipalInactive` through a stub `PrincipalStatus`; `sla_deadline`
  arithmetic and saturation; `explain` names a disposition for every
  declaration; CODEOWNERS fixtures under `testdata/ownership/codeowners/`
  produce golden facts and unresolved lines.
- **FR-002.** `PathPattern` matcher vectors in
  `testdata/ownership/patterns.json` (pattern, path, expected) covering
  each rule of B-2.
- **FR-003.** A property test (`proptest`) folds a random declaration
  and revocation history through two total-order-preserving permutations
  and asserts equal views and equal `owners_of` answers at random probes.
- **FR-004.** `lib.rs` re-exports `OwnershipView`, `OwnershipScope`,
  `PathPattern`, `CrateIndex`, `Owner`, `Sla`, `PrincipalStatus`,
  `AlwaysActive`, `Disposition`, the builders, and `import_codeowners`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked ownership` passes,
  fixtures and vectors included.
- **AC-2.** The golden ownership fixture in `tests/ownership.rs` (two
  roots, one agent delegate, one expiry, one revocation) answers the
  recorded `owners_of` table at four probe `Hlc`s from every tested
  permutation.

## 6. Out of scope

Enforcing ownership at merge (a policy, 065 and 066); ranking owned
work in feeds (085); binding the declaring key to the owner identity
(064); agent registration and the token-side delegation chain (100,
101); mirroring GitHub CODEOWNERS on sync (040 may call B-9 later);
team membership as a noun (an `Org` is opaque here).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked
```
