---
id: "071-action-cache"
title: "Action cache as a trust boundary: attested entries, gating versus advisory lookups"
status: approved
kind: "kernel"
domain: "l3-evaluation"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 5
depends_on:
  - "070-reapi-types"
  - "064-attestation-verification"
establishes:
  - "crates/hqgit-eval/src/cache.rs"
  - "crates/hqgit-eval/src/executor_identity.rs"
  - "crates/hqgit-eval/tests/cache.rs"
extends:
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/src/lib.rs", nature: additive }
  # redb for the persistent cache backend, hqgit-trust for the verified set.
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/Cargo.toml", nature: additive }
  # The executor registration fact joins the domain vocabulary.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  A poisoned action cache forges provenance for arbitrary code, so the cache
  is a trust boundary (thesis D10, constitution XI). Entries are immutable
  and keyed by both the action digest and the executor that produced them,
  so two executors' results coexist instead of overwriting; every entry
  names its executor's Service identity and the provenance attestation that
  vouches for it; and a lookup declares its purpose. A gating lookup, the
  kind a merge decision consumes, treats an entry whose attestation is
  absent or fails spec 064 verification as a miss. An advisory lookup may
  serve the same entry, flagged, for developer feedback. Executors are
  registered Service identities with a trust tier, and a quorum rule can
  demand that several of them agree before an output counts.
---

# 071: Action cache as a trust boundary

## 1. Purpose

Thesis §4.4 ends with the sentence this spec implements: the cache is a
trust boundary; cache entries must carry executor identity and be
verifiable; unattested cache hits are cache misses for anything that gates
a merge. Under content addressing, a cache hit is indistinguishable from an
execution, which is what makes global caching affordable (076) and exactly
what makes a forged entry dangerous. The defense is not secrecy but
evidence: the entry itself is worthless without the provenance attestation
(074) an identified executor signed over it, verified through the trust
plane (064).

## 2. Territory

`cache.rs` (the `ActionCache` trait, the entry shape, the lookup rule, the
in-memory and redb backends) and `executor_identity.rs` (executor
registration, trust tiers, the quorum rule) inside `crates/hqgit-eval`,
plus `tests/cache.rs`. Additively: the `eval.executor_registered` fact kind
in spec 023's vocabulary, the crate manifest (redb, `hqgit-trust`), and the
crate's re-exports. The service that fronts this cache over gRPC is spec
072; the attestation an entry references is minted by spec 074.

## 3. Behavior

- **B-1 (entry).** `CacheEntry { key: ActionKey, executor: ServiceId,
  executor_key: KeyId, result: ActionResult, attestation:
  Option<AttestationId>, sandbox_tier: Option<SandboxTier>, entry_hash:
  Hash }` where `ActionResult` is the typed form of the REAPI message
  (output files, directories, symlinks as digests, exit code, stdout and
  stderr digests, `ExecutedActionMetadata`). `entry_hash` is
  `Hash::of(canonical bytes of the entry without entry_hash)`; a read
  recomputes it and a mismatch is `Error::Crypto`, never a served entry.
- **B-2 (immutability).** The store key is `(ActionKey, ServiceId)`. `put`
  with a new key stores; `put` with an existing key and identical
  `entry_hash` is a no-op `Ok`; `put` with an existing key and a different
  `entry_hash` is `Error::Validation("cache entry is immutable")`. There is
  no update and no delete; an executor that wants to supersede its result
  registers a new identity or the operator evicts through a journaled
  operator command outside this crate.
- **B-3 (purpose).** `enum Purpose { Gating, Advisory }`. `lookup(key,
  purpose, verified: &VerifiedAttestationSet) -> Lookup` returns
  `Lookup::Hit { entry, grade: Grade::{Attested, Unattested} }` or
  `Lookup::Miss(MissReason::{Absent, Unattested, VerificationFailed(String),
  QuorumUnmet})`. For `Gating`, an entry is a hit only when `attestation`
  is `Some(id)`, `verified` contains that id with `Verdict::Ok`, the
  attestation's subject equals the `ActionKey` hash, its predicate is
  `hqgit/provenance/v1`, and the claim's byproduct digests equal the
  entry's output digests; any other state is a `Miss`. For `Advisory`, an
  entry with a missing or unverified attestation is served as `Hit { grade:
  Unattested }`, and callers MUST render the grade. The verified set is an
  input, never computed here: this crate never verifies a signature.
- **B-4 (coexistence and quorum).** `lookup_all(key) -> Vec<CacheEntry>`
  returns every executor's entry for a key. `QuorumRule { required: u8,
  tiers: BTreeSet<TrustTier> }` and `quorum(key, rule, verified) -> Lookup`
  produce a gating hit only when at least `required` attested entries from
  executors of an allowed tier agree on the output digests; disagreement is
  `Miss(QuorumUnmet)` with every entry hash listed, so a divergent executor
  is visible rather than averaged away.
- **B-5 (executor identity).** `ExecutorIdentity { service: ServiceId,
  key: KeyId, tier: TrustTier::{Trusted, Untrusted}, sandbox_tiers:
  BTreeSet<SandboxTier> }` registered by an `eval.executor_registered`
  fact signed by the operator identity; `ExecutorRegistry` folds those
  facts (and `eval.executor_revoked`) and answers `executor(service, at)`.
  A `put` from a `ServiceId` the registry does not know at the entry's
  attestation time is `Error::Validation`.
- **B-6 (backends).** `MemoryActionCache` (BTreeMap) and
  `RedbActionCache` at `<data>/eval/action-cache.redb` with one table
  keyed by the 64 bytes `action hash || service id` and a secondary table
  by action hash; iteration is key-ordered; writes are fsynced.
- **B-7 (`do_not_cache`).** An `ActionResult` for an action whose
  `do_not_cache` was set is never stored; `put` returns `Ok` and records a
  counter so the refusal is observable.
- **B-8 (no ambient input).** The cache reads no clock; `stored_at` is not
  a field. Freshness is a property of the attestation's `at`, judged by the
  caller.

## 4. Functional requirements

- **FR-001.** `ActionCache` is an object-safe trait with `put`, `lookup`,
  `lookup_all`, and `quorum`; both backends implement it and share one test
  suite parameterized over the backend.
- **FR-002.** Tests cover: an unattested entry is a gating miss and an
  advisory hit flagged `Unattested`; a verified attestation over a different
  subject is a miss; byproduct digests disagreeing with the entry's outputs
  is a miss; a tampered stored entry is `Error::Crypto`; overwrite with a
  different hash is refused while an identical put is a no-op; two
  executors' entries coexist and `quorum(required: 2)` hits only when they
  agree; a revoked executor's put is refused; `do_not_cache` never stores.
- **FR-003.** The verified attestation set arrives as spec 064's
  `VerifiedAttestationSet` value; tests build it through 064's test
  constructor, never by signing inside this crate.
- **FR-004.** The redb backend survives reopen with identical lookups and
  key order.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-eval --locked cache` passes.
- **AC-2.** A fixture where the only entry for a key is unattested yields
  `Miss(Unattested)` for `Gating` and `Hit { Unattested }` for `Advisory`.

## 6. Out of scope

Minting the provenance attestation (074); serving the cache over gRPC and
authenticating executors on the wire (072); eviction policy and quotas (a
later operator spec); cross-host cache replication (rides on federation,
112).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-eval --locked cache
```
