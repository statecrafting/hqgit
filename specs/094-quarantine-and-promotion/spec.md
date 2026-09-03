---
id: "094-quarantine-and-promotion"
title: "Quarantine and promotion: untrusted writes land quarantined, capabilities are attestations, promotion is a fact"
status: approved
kind: "kernel"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 6
depends_on:
  - "091-per-repo-control-plane"
  - "064-attestation-verification"
establishes:
  - "crates/hqgit-server/src/quarantine.rs"
  - "crates/hqgit-server/src/capability.rs"
  - "crates/hqgit-server/tests/quarantine.rs"
  - "crates/hqgit-server/testdata/capabilities/"
extends:
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/lib.rs", nature: additive }
  # The capability router replaces TrustRouter in the app state.
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/app.rs", nature: additive }
  # hqgit-trust joins the server's dependencies.
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/Cargo.toml", nature: additive }
  # The namespace.promoted variant joins the domain vocabulary.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  Constitution XV in code. Every write reaching the server from a
  principal that is not verified and not capable (anonymous pushers, fork
  contributors, the mirror's Service principal, any agent) is appended to
  the repository's quarantine namespace, never to main. A capability is an
  attestation with predicate hqgit/capability/v1 over a principal, rooted
  at the repository's genesis identity, verified end to end by spec 064,
  and evaluated by pure functions over the verified set at the Hlc of the
  write in question. Promotion is a namespace.promoted fact signed by a
  holder of the promote capability; main's fold is main's facts plus what
  main has promoted, so a promoted fact keeps its original issuer and
  signature. Per-principal rate and size limits bound abuse of the
  append-only store, and quarantine content is served only to holders of
  read-quarantine.
---

# 094: Quarantine and promotion

## 1. Purpose

Thesis §8 names abuse in an append-only replicated store as a standing
risk, and constitution XV answers it: untrusted by default, promoted by
capability. Spec 021 created the quarantine namespace and tagged its
entries; 090 routed unverified writes there provisionally; 040 put every
mirrored fact there. This spec supplies what those relied on: a definition
of "capable" that is evidence rather than a settings table (constitution
IX, XI), a promotion path that is itself a signed fact, and the limits
that keep an open endpoint from being filled. Because the checks are pure
over verified attestations, any replica reaches the same answer.

## 2. Territory

`capability.rs` (the predicate, its claim schema and validator, the pure
`CapabilitySet` and its checks), `quarantine.rs` (the router, the
promotion path, the promotion-aware fact source, limits, the object
visibility index, the purge subcommand), `tests/quarantine.rs`, and
frozen vectors under `testdata/capabilities/`. Additively: `app.rs`,
`lib.rs`, and the manifest (090) and the `namespace.promoted` variant in
023's `facts.rs`. Delegation chains for agents are 101; federation peers
holding `promote` are 112.

## 3. Behavior

- **B-1 (capabilities are attestations).** `Capability` is a closed enum
  `WriteMain | Promote | ReadQuarantine | Grant`. A grant is an
  `Attestation` (027) with predicate `hqgit/capability/v1`, subject the
  grantee's `IdentityId` (060), issuer the grantor, and claim `{
  namespace: Hash, action: Grant { capabilities: Vec<Capability>, expires:
  Option<Hlc>, delegable: bool } | Revoke { grant: AttestationId } }`.
  `capability.rs` registers the predicate and a `ClaimValidator` with the
  027 registry at server start (`register_capability(&mut registry)`);
  the kind string and claim schema are frozen by a vector.
- **B-2 (root of authority).** The principal recorded in the repository's
  `RepoGenesis` (013 B-2, `created_by`) holds every capability on every
  namespace of that repository, implicitly and irrevocably. Everyone else
  holds exactly what a chain of grants proves: each link is a
  `VerifiedAttestation` (064; an unverified or failed one contributes
  nothing), its issuer is the root or holds `Grant` with `delegable` at
  the link's `at`, it is not expired at the check `Hlc`, and no verified
  `Revoke` names it. Only the root and holders of `Grant` may issue a
  `Revoke`, and only for a grant they issued or one beneath them in the
  chain.
- **B-3 (pure checks).** `CapabilitySet::build(root: &Principal,
  verified: &VerifiedAttestationSet, at: &Hlc) -> CapabilitySet` and
  `fn check(&self, principal: &Principal, namespace: &Hash, cap:
  Capability) -> CapabilityCheck` where `CapabilityCheck` is `Granted {
  via: Vec<AttestationId> } | Denied(DenyReason)` and `DenyReason` is
  `NoGrant | Expired { at: Hlc } | Revoked { by: AttestationId } |
  IssuerLackedGrant { issuer: Principal } | NotDelegable`. No I/O, no
  clock: `at` is the `Hlc` of the write being judged, so replaying the
  decision years later yields the same answer. Permuting the verified set
  never changes a result (a test proves it).
- **B-4 (the router).** `QuarantineRouter` implements 090 B-6 and replaces
  `TrustRouter` in `AppState`. `target_for` returns `main` only when the
  caller is `CallerTrust::Verified`, its principal kind is `Human` or
  `Org`, and `check(principal, main, WriteMain)` is `Granted`; a `Service`
  principal that is the server identity itself qualifies for the facts it
  issues on its own behalf, but a fact carrying `on_behalf_of` (090 B-4)
  is judged by the behalf principal; the mirror principal (040 B-2) and
  every `Agent` principal are quarantined regardless of grants (101 and
  102 extend this rule with the delegation chain); everything else is
  quarantined. Quarantined entries carry 021 B-6's `extra["namespace"]`
  plus `extra["submitted_by"]` and `extra["trust"]` (`anonymous`,
  `unbound`, `no-capability`, `agent`, `mirror`).
- **B-5 (promotion).** `namespace.promoted` (023, frozen here) body `{
  from: Hash, to: Hash, entries: Vec<EntryHash> (sorted, deduplicated),
  promoted_by: Principal, reason: Option<String>, extra }`, appended to
  `to`. A promotion MUST arrive signed by the promoter's own key (through
  093 `Repos.Append` or the CLI); the server refuses to mint one on a
  caller's behalf. Before `propose` (091) the server checks: every entry
  exists in `from`, `from` is a quarantine namespace and `to` is not, and
  `check(promoted_by, to, Promote)` is `Granted` at the fact's `Hlc`;
  otherwise `Error::Policy` naming the reason. Facts never move (021
  B-6): the promoted entries keep their issuer, signature, and hash.
- **B-6 (main's fold).** `PromotedView` is a `DerivedState` (019) over
  `namespace.promoted` answering `promoted(entry) -> Option<EntryHash>`
  and recording a `PromotionDefect { entry, reason }` for any promotion
  whose promoter lacked `Promote` at its `Hlc` (mirroring 060 B-6: a
  defect alters nothing, so a rogue node cannot inject through the store).
  `PromotionAwareFactSource` wraps 021's `FactSource`: the fact set of
  main is main's entries plus every entry a non-defective promotion names,
  ordered by 018 over the union. Every server-side fold, the 080 runner
  when driven by the server, and the 093 read models MUST read main
  through it; a rebuild from zero reproduces the same set.
- **B-7 (reading quarantine).** Listing or fetching quarantine entries
  (093 with `namespace = quarantine`, 092 change refs from quarantine)
  requires `check(caller, quarantine, ReadQuarantine)` or the caller being
  the entry's own `submitted_by`; otherwise `Error::Policy`. An object is
  served by cid only when the visibility index says a main-visible entry
  references it or the caller may read quarantine; the index lives in
  `<repo>/.hq/quarantine.redb`, is rebuilt by `hqgit-server quarantine
  reindex`, and is never authority.
- **B-8 (limits).** Per principal, or per `token_hash`, or per hashed
  remote address for `Anonymous`: `[quarantine] writes_per_hour = 60`,
  `bytes_per_day = 268435456`, `max_payload_bytes = 4194304`,
  `max_objects_per_write = 1000`, enforced by a token bucket persisted in
  `quarantine.redb`; exceeding one is `Error::Policy` with kind
  `rate-limited` (093 maps it to `resource_exhausted`). Holders of
  `WriteMain` are exempt from per-principal buckets but bound by 090's
  body limit.
- **B-9 (purge).** `hqgit-server quarantine purge <ns> <cid> --reason
  <Moderation|Legal>` tombstones through 021 `erase` with the server
  identity's owner capability (021 B-7) when the server identity is the
  repository root, and refuses otherwise.

## 4. Functional requirements

- **FR-001.** `testdata/capabilities/` holds frozen vectors: `grant-direct
  .json`, `grant-delegated.json`, `grant-non-delegable.json`, `revoked
  .json`, `expired.json`, `forged-issuer.json`, each with seeds, the
  claims, canonical bytes, attestation ids, and expected `CapabilityCheck`
  answers at named `Hlc` probes.
- **FR-002.** `tests/quarantine.rs` covers, against 090's `TestServer` with
  `LocalControlPlane`: an anonymous write lands in quarantine with the
  `extra` tags; a `Verified` human without a grant lands in quarantine
  with `trust = no-capability`; with a root-issued `WriteMain` grant the
  write lands in main; the mirror principal and an agent land in
  quarantine despite grants; a promotion by a principal without `Promote`
  is `Error::Policy`; with an expired or revoked grant likewise; a
  delegated chain root to A (`delegable`) to B succeeds and a non-
  delegable chain fails with `NotDelegable`; a promotion naming an entry
  absent from quarantine is refused; after a valid promotion the promoted
  change appears in the 024 fold over `PromotionAwareFactSource` and in
  the 081 `changes` view after rebuild, with its original issuer; a
  promotion injected at the store level by a promoter lacking capability
  is a `PromotionDefect` and folds nothing; quarantine listing without
  `ReadQuarantine` is refused and with it succeeds; the sixty-first write
  in an hour is `rate-limited`; a payload over the cap is refused; the
  same `CapabilitySet` answers identically for two permutations of the
  verified set; `purge` tombstones and the chain still verifies (020 B-7).
- **FR-003.** `capability.rs` contains no I/O and reads no clock; a source
  guard test asserts it (010 FR-003 pattern).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-server --locked quarantine` passes,
  vectors included.
- **AC-2.** On a repository imported through 040, `hq log --namespace
  quarantine` lists the mirrored facts, and after a root-signed promotion
  submitted with `hq --remote`, `hq change list --remote` shows the
  promoted change without any fact having been re-signed.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Delegation chains that let an agent's writes reach main (101, 102),
federation peers holding `promote` (112), OIDC binding that produces
`Verified` callers (061), erasure granted by a policy verdict (068), and
any moderation UI.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-server --locked quarantine
cargo test -p hqgit-server --locked
```
