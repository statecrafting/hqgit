---
id: "002-platform-thesis"
title: "Platform thesis: a verifiable evidence ledger for software change"
status: approved
kind: "thesis"
domain: "governance"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: n-a
risk: critical
wave: 1
depends_on:
  - "000-hqgit-bootstrap"
constrains:
  - kind: sequencing-plan
    target_specs:
      - "010-workspace-and-core-types"
      - "011-canonical-encoding"
      - "012-hash-stability-gate"
      - "013-object-store"
      - "014-content-defined-chunking"
      - "015-verified-streaming"
      - "016-remote-object-backend"
      - "017-ledger-entry-dag"
      - "018-deterministic-total-order"
      - "019-facts-and-derived-state"
      - "020-commitments-and-tombstones"
      - "021-local-repository"
      - "023-domain-fact-vocabulary"
      - "024-change-and-revision"
      - "025-semantic-anchors"
      - "026-review-threads"
      - "027-attestation-primitive"
      - "028-issues-and-derived-state"
      - "031-git-object-bridge"
      - "032-cli-skeleton"
      - "033-cli-offline-review"
      - "034-cli-attest-and-verify"
    note: >
      Wave 1: ledger, object store, domain model, CLI. Local only, no server.
      Ends when offline review against a plain git repo works end to end
      (033) and its evidence verifies (034). Hash stability of 011 and 017 is
      the one unrecoverable decision in the whole plan, which is why they sit
      first and why 012 gates them before anything is built on top.
  - kind: sequencing-plan
    target_specs:
      - "040-github-mirror-import"
      - "041-github-mirror-export"
      - "042-mirror-sync-command"
    note: >
      Wave 2: the git bridge (031) and the bidirectional GitHub mirror.
      Value for users who migrate nothing: their issues, pull requests,
      reviews, and check results become facts they can clone.
  - kind: sequencing-plan
    target_specs:
      - "050-stacked-changes"
      - "051-semantic-deltas"
      - "052-semantic-conflicts"
    note: >
      Wave 3: stacked changes and semantic review. The first felt value
      beyond parity: force-push stops destroying review context, stacks are
      native, and the high-value views of a change (API surface, types,
      dependencies, capabilities) arrive as attestations.
  - kind: sequencing-plan
    target_specs:
      - "060-identity-and-key-rotation"
      - "061-oidc-login"
      - "062-transparency-log"
      - "063-keyless-signing"
      - "064-attestation-verification"
      - "065-policy-engine"
      - "066-policy-sdk"
      - "067-policy-evaluation-attestation"
      - "068-policy-in-repo"
    note: >
      Wave 4: the trust plane and the policy engine. Merge gates become
      checkable predicates over verified evidence; every verdict is itself an
      attestation replayable against the exact policy hash that produced it.
  - kind: sequencing-plan
    target_specs:
      - "070-reapi-types"
      - "071-action-cache"
      - "072-execution-service"
      - "073-sandbox-executor"
      - "074-execution-provenance"
      - "075-build-graph"
      - "076-merge-queue"
    note: >
      Wave 5: the evaluation plane. Highest capex, deliberately fifth because
      it depends on stable input hashing. CI results are not a separate
      system; they are evidence, and the cache is a trust boundary.
  - kind: sequencing-plan
    target_specs:
      - "080-projection-framework"
      - "081-change-and-review-views"
      - "082-search-index"
      - "083-code-graph"
      - "084-ecosystem-graph"
      - "085-attention-feeds"
      - "090-server-skeleton"
      - "091-per-repo-control-plane"
      - "092-git-endpoint"
      - "093-connect-api"
      - "094-quarantine-and-promotion"
      - "095-web-review-ui"
    note: >
      Wave 6: projections, the cross-repo code and ecosystem graph, and the
      hosted edge (server, git endpoint, API, review UI). Everything in this
      wave is disposable by construction (constitution VI); the ecosystem
      graph is the one legitimately centralized component and stays
      non-authoritative.
  - kind: sequencing-plan
    target_specs:
      - "100-agent-principals"
      - "101-delegation-chain"
      - "102-agent-sandbox-and-provenance"
      - "103-evidence-carrying-changes"
      - "104-ownership-and-sla"
    note: >
      Wave 7: agents as a distinct principal class, designed into the types
      in wave 1 (010) and shipped here: Biscuit credentials carrying the
      delegation chain, declared sandboxes, mandatory provenance, and changes
      that arrive with machine-checkable evidence so a human reviews the
      argument rather than the diff. Ownership with delegation and expiry
      rides along because it is the other half of the accountability chain.
  - kind: sequencing-plan
    target_specs:
      - "110-set-reconciliation"
      - "111-quic-transport"
      - "112-federation"
    note: >
      Wave 8: multi-host federation. Last because discovery cost is the
      structural reason centralization keeps winning; the central index
      exists by wave 6 without lock-in as its business model, and federation
      replicates the same signed history between hosts.
references:
  - { unit: { kind: file, path: "docs/design/00-architecture.md" }, role: context }
  - { unit: { kind: file, path: "docs/design/01-build-order.md" }, role: context }
summary: >
  hqgit is a verifiable evidence ledger for software change. Canonical state
  is a set of signed, content-addressed objects forming a per-repository DAG
  that covers code, collaboration, and evidence; every index, timeline,
  queue, and dashboard is a projection rebuildable from zero. The forge is
  one client of that ledger, the CI system is another, and the agent runtime
  is a third. This spec fixes the layer model (L0 objects through L7 edge),
  the governing invariant (canonical versus derived), the nouns (Change,
  Revision, Anchor, Attestation, Principal, Policy), the language split (Rust
  core, Go only at the executor seam), the crate topology, the eight-wave
  build order that every later spec's number reflects, and the standing
  risks. It owns no code.
---

# 002: Platform thesis

## 1. Purpose

GitHub's product is not Git hosting. It is the identity and social graph, the
proprietary collaboration ledger (issues, pull requests, reviews, CI results),
and the compute. Git is the only portable layer in the stack. The repository
is content-addressed, signed, replicated, and forkable; every fact *about* the
repository is a mutable row in someone else's database, reachable only
through their API, and gone the moment you leave. Most "better GitHub"
proposals layer features on that same shape. hqgit changes the shape.

The analysis behind this thesis (`docs/design/00-architecture.md` §1) names
seven breaks in the incumbent model: collaboration state outside the data
model; the mutable branch pointer as the unit of change; review anchored to
text; CI as untyped YAML with mutable third-party refs; decorative trust; no
ecosystem graph; and agents authenticating as humans. The recommendation is
not a frontal assault on hosting. It is to build the verification and review
plane, federate over existing repositories, mirror collaboration state
bidirectionally, and let hosting commoditize underneath. Absorption beats
replacement.

This spec is the record of the decisions that follow from that analysis. It
is `implementation: n-a`: it constrains every ordinary spec and owns no code.

## 2. Layer model

```
L7  Edge:        git-compat endpoint, gRPC/Connect API, sync protocol, UI, agents
L6  Policy:      merge predicates as versioned WASM modules
L5  Projection:  code graph, search, ecosystem graph, feeds   [disposable]
L4  Trust:       identities, key rotation, attestation verify, transparency log
L3  Evaluation:  hermetic build/test graph, remote execution, action cache
L2  Domain:      Change, Revision, Anchor, Review, Attestation, Policy
L1  Ledger:      per-repo signed hash-linked event DAG + convergent state
L0  Objects:     content-addressed blob/tree store (BLAKE3), chunked
```

Boundaries are one-directional: L5 and above may only read from L0 through
L4, never write authoritatively (constitution XIII, bootstrap anchor
`layer-direction`). Every ordinary spec declares its layer as its `domain`.

## 3. The governing decision: canonical versus derived

One decision governs everything else: what is canonical, and what is derived.
Canonical state is a set of signed, content-addressed objects forming a
per-repository DAG covering code, collaboration, and evidence. Every index,
timeline, dashboard, search result, and queue is a projection that must be
rebuildable from zero. Hold that invariant and portability, offline
operation, federation, audit, and schema evolution fall out of one property.
Violate it once (one authoritative row that is not in the log) and the
project has rebuilt GitHub with extra steps. This is frozen at tier 1
(bootstrap anchor `canonical-derived-boundary`).

## 4. The layers, decided

### 4.1 L0: object store (specs 013 to 016, 031)

BLAKE3 over SHA-256, primarily for verified streaming: the BAO tree gives
chunk-level verification and range proofs, so partial and lazy fetch are
verifiable by construction. Content-defined chunking (FastCDC) plus a Merkle
tree means large files are the general path with different chunk statistics,
not a special case. Git compatibility is a hard requirement given the wedge,
so a bidirectional object mapping is maintained through `gix` (gitoxide),
never libgit2 bindings. Local index in redb; remote in any S3-compatible
store. Immutability makes every cache layer trivially correct.

### 4.2 L1: ledger (specs 011, 012, 017 to 021, 110, 111)

Entry shape: `{ parents: [Hash], issuer: KeyId, hlc: HybridLogicalClock,
payload: Cid, sig: Signature }`. A hash-linked DAG, not a linear log, because
concurrent authors are the normal case.

The critical separation is facts versus derived state. Facts are immutable
events and never conflict; concurrent facts merge by set union under a
deterministic total order (topological, tiebreak on hash). Derived state
(open or closed, labels, assignee, title) is the only thing that needs
convergence, and a hybrid logical clock with last-writer-wins is sufficient
for almost all of it. Sequence CRDTs are reserved for genuinely collaborative
text. That split keeps the CRDT surface near five percent of the domain
instead of all of it (constitution VII).

Erasure is decided at entry one: the signed log contains commitments, never
user content; content lives in the blob store, encrypted per namespace where
it must be; deletion removes the blob and appends a tombstoned commitment
(constitution X). Serialization is canonical DAG-CBOR with forward-compatible
unknown-field preservation; hash stability is fuzzed in CI from the first
commit (spec 012), because any nondeterminism in canonicalization silently
invalidates every signature downstream (constitution VIII).

Replication is range-based set reconciliation over QUIC (spec 110, 111);
`iroh` and `quinn` are the building blocks and the Willow protocol is the
prior art to study first. Server-side, repositories are independent
consistency domains, so per-repo Raft groups are the natural partitioning,
and an embedded Raft-replicated SQLite (Hiqlite) fits better than a shared
cluster (spec 091).

### 4.3 L2: domain model (specs 023 to 028, 050 to 052, 104)

The single most valuable simplification in the design: every form of
evidence is one primitive, `Attestation { subject: Hash, predicate:
PredicateType, issuer: Principal, claim: Cid, sig }` (spec 027, constitution
IX). Human approval, build provenance, test result, static finding, license
scan, policy evaluation, mirrored external state, and agent action are all
the same shape. Resist every request to special-case one of them.

The other nouns that must be right: `Change` (stable identity) with ordered
`Revision`s, each a tree hash plus base (spec 024); `Anchor { path,
tree_sitter_node_path, node_content_hash }` so comments survive rebase by
re-resolving against content, falling back to text position only when
resolution fails (spec 025); `Principal = Human | Agent | Service | Org`,
distinct at the type level (spec 010); `Policy` as versioned, hash-pinned,
executable (spec 068).

### 4.4 L3: evaluation plane (specs 070 to 076)

`eval(repo_state_hash, target, toolchain_hash) -> output_hash`, cached
globally on input hash. The protocol is not invented: the Bazel Remote
Execution API is implemented so existing executors, clients, and caches
interoperate on day one. Two sandbox tiers: namespaces plus seccomp with no
network for trusted work, microVMs for fork contributions and agent
execution. Every execution emits a signed provenance attestation, closing the
loop into L2. Merge queues become speculative evaluation over candidate merge
states. The cache is a trust boundary: entries carry executor identity, and
unattested cache hits are misses for anything that gates a merge
(constitution XI).

### 4.5 L4: trust plane (specs 060 to 064, 100 to 102)

Authentication and identity are different problems. OIDC (Rauthy as the
self-hosted reference) handles login and workforce federation. Durable
identity is a keypair with a rotation chain recorded in the ledger, so
historical signatures remain verifiable across key changes. Signing defaults
to the Sigstore shape: short-lived certificates bound to an OIDC identity,
with transparency-log inclusion proofs, run in-house when sovereignty
matters. Agents hold Biscuit tokens, not scoped personal access tokens: the
delegation chain lives in the token, attenuation is monotonic and offline
verifiable, and caveats are datalog (constitution XII).

### 4.6 L6: policy (specs 065 to 068, 103)

The merge predicate is `f(change, attestation_set, policy_version) -> Allow |
Deny(reasons)`, deterministic and side-effect free, compiled to WASM with a
typed SDK so policies are unit-testable, hash-pinned to repo state, and
evaluable locally before push. Policy evaluation emits an attestation, so
every merge decision is replayable years later against the exact policy that
produced it. Repository settings as mutable toggles are made impossible.

### 4.7 L5 and L7 (specs 080 to 095, 112)

Projections are disposable read models rebuilt from the total order
(spec 080). The cross-repo code index (SCIP-class, spec 083) joined to the
package dependency graph (spec 084) is the one legitimately centralized
component; it is isolated and non-authoritative. The edge is the git
endpoint, the Connect API, the review UI, the federation protocol, and the
agent runtime: interchangeable clients over the same signed history.

## 5. Language and crate topology

Split by ecosystem gap, not by preference. Rust for the entire trusted core:
the invariants are type-encodable, the libraries exist (`gix`, `blake3`,
`bao`, `redb`, `ciborium`, `ed25519-dalek`, `tantivy`, `sigstore`,
`biscuit-auth`, `iroh`, `quinn`, `wasmtime`, `tonic`), there are no GC pauses
on the content-addressed hot path, and single-binary embedding means the CLI
and the server run the same ledger implementation, which is the only way to
get genuine offline-first without two divergent implementations. Go is
stronger in the execution plane (containerd, Firecracker SDKs, cloud SDKs),
so the executor that orchestrates container runtimes is Go (spec 073). That
is the one language boundary, and the domain model stays on the Rust side
of it.

| Crate | Layer | Founding spec | Depends on (workspace) |
|---|---|---|---|
| `hqgit-types` | L2 data, L1 codec | 010, 011 | none |
| `hqgit-object` | L0 | 013 | types |
| `hqgit-ledger` | L1 | 017 | types, object |
| `hqgit-domain` | L2 | 023 | types, object, ledger |
| `hqgit-git` | L0/L7 bridge | 031 | types, object |
| `hqgit-cli` (`hq`) | L7 | 032 | every library crate |
| `hqgit-mirror` | L7 | 040 | types, ledger, domain, git |
| `hqgit-trust` | L4 | 060 | types, ledger |
| `hqgit-policy` | L6 | 065 | types, domain |
| `hqgit-policy-sdk` | L6 | 066 | types (wasm32 target) |
| `hqgit-eval` | L3 | 070 | types, object, ledger, domain, trust |
| `hqgit-projection` | L5 | 080 | types, ledger, domain |
| `hqgit-server` | L7 | 090 | every library crate |
| `hqgit-agent` | L4/L7 | 100 | types, ledger, trust, policy |
| `hqgit-sync` | L1 | 110 | types, object, ledger, trust |
| `executor/` (Go) | L3 | 073 | REAPI wire contract only |
| `fuzz/` | tooling | 012 | types, ledger |
| `web/` (TS) | L7 | 095 | Connect API only |

Dependencies point downward only; `hqgit-cli` and `hqgit-server` never
depend on each other.

## 6. Build order

Sequencing is dominated by one fact: hash stability of L0 and L1 is the only
unrecoverable mistake. Everything above it is replaceable. The eight waves
are the `sequencing-plan` constraints in this spec's frontmatter, and every
spec's ordinal encodes its wave (`010` to `034` wave 1, `040`s wave 2, `050`s
wave 3, `060`s wave 4, `070`s wave 5, `080`s and `090`s wave 6, `100`s wave 7,
`110`s wave 8). Each spec also carries `wave` in frontmatter. The
orchestrator's "lowest-numbered ready spec" rule therefore reproduces this
order without a second table, and `docs/design/01-build-order.md` renders the
resulting DAG for humans.

1. Ledger, object store, domain model, CLI. Local only. Prove offline review
   against a plain git repo.
2. Git bridge and bidirectional GitHub mirror. Users without migration.
3. Stacked changes, semantic deltas, semantic conflicts. First felt value.
4. Trust plane and policy engine. Merge gates become verifiable.
5. Evaluation plane. Highest capex, depends on stable input hashing.
6. Projections, cross-repo code and ecosystem graph, hosted edge and UI.
7. Agent principals and delegation. Designed into the types in wave 1.
8. Multi-host federation.

## 7. Amendment and invalidation

A shipped spec is pinned at the hash of its `spec.md`. Amending it (a dated
`## Amendments received` entry, or any change to its contract) invalidates
every transitive dependent, which must re-verify before it counts as shipped
again. This spec is depended on by every ordinary spec through 010, so an
amendment here re-verifies the whole corpus. That is the intended cost of
changing the thesis.

## 8. Standing risks

- **Schema evolution against signed history.** Version everything, preserve
  unknown fields, never reorder. Frozen (bootstrap anchor `hash-stability`).
- **CRDT surface creep.** Hold the facts versus derived-state line under
  product pressure; a spec moving a noun to the CRDT side must argue it.
- **Cross-repo indexes** are the one legitimately centralized component;
  isolate them and keep them non-authoritative (spec 083, 084).
- **Abuse in an append-only replicated store.** Untrusted contributions land
  in a quarantine namespace and are promoted by capability (spec 094).
- **Erasure versus append-only.** Commitments and tombstones from entry one
  (spec 020); not retrofittable.
- **Hermetic builds tax ergonomics.** Everything must be declared; the escape
  hatches (spec 075) are where the model leaks, so they are attested too.
- **Semantic review is per-language.** Rust and TypeScript first (spec 025,
  051); everything else degrades to text, visibly.
- **Agent capability scoping adds friction** exactly where users want
  autonomy. The design optimizes verification throughput (spec 103), and a
  spec that loosens agent scoping must argue against constitution XII.
- **Decentralized state raises discovery cost.** The central index exists
  (wave 6); federation (wave 8) replicates signed history, not authority.

## 9. Out of scope

Hosting as a business, billing, maintainer funding, and a GitHub-parity
issue tracker UI. A UI beyond the review surface (spec 095) is a later
client of the API. Non-GitHub mirrors (GitLab, Gerrit) follow spec 040's
shape as later specs.

## 10. Resolved decisions

Carried from `docs/design/00-architecture.md` and fixed here:

- **D1 (canonical versus derived).** As §3. Frozen at tier 1.
- **D2 (BLAKE3 and BAO).** Verified streaming is the reason, not speed.
- **D3 (gix, not libgit2).** Pure Rust, no C boundary in the trusted core.
- **D4 (DAG, not log).** Concurrent authors are the normal case.
- **D5 (facts versus derived state).** LWW over HLC for derived state;
  sequence CRDTs only for collaborative text.
- **D6 (commitments in the log).** Erasure by tombstone from entry one.
- **D7 (DAG-CBOR canonical encoding).** Unknown fields preserved; fuzzed.
- **D8 (one attestation primitive).** in-toto's statement model, generalized.
- **D9 (REAPI, not a new protocol).** Interoperate on day one.
- **D10 (cache is a trust boundary).** Unattested hits are misses for gates.
- **D11 (identity is a keypair with a rotation chain; login is OIDC).**
- **D12 (Biscuit for agents).** Delegation chain in the token.
- **D13 (policy is WASM, hash-pinned, and emits an attestation).**
- **D14 (Rust core, Go executor).** One language boundary, at the REAPI seam.
- **D15 (build order).** As §6; hash stability first.
- **D16 (absorption over replacement).** Mirror over existing repositories;
  no migration required for value.
- **D17 (specify first).** The entire corpus is authored before any code,
  every spec is a bounded session's territory, and the orchestrator builds
  it in ordinal order. This spec and 000 and 001 are the only
  non-`pending` specs at authoring time.
