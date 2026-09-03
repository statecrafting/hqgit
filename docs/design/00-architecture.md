# hqgit: architecture and analysis

Date: 2026-09-02. This is the design analysis the spec corpus is derived
from. It records conclusions and decisions; the specs under `specs/` are the
authority, and `specs/002-platform-thesis/spec.md` is the normative record of
what this document argues. Where the two differ, the thesis governs.

## 1. The problem

GitHub's real product is not Git hosting. It is three things: the identity
and social graph, the proprietary collaboration ledger (issues, pull
requests, reviews, CI results), and the compute. Git is the only portable
layer in the stack.

That asymmetry is the root defect. The repository is content-addressed,
signed, replicated, and forkable; every fact *about* the repository is a
mutable row in someone else's Postgres, reachable only through their API,
and gone the moment you leave. Most "better GitHub" proposals are feature
lists layered on top of that same shape. The interesting redesigns change
the shape.

### 1.1 Where the model actually breaks

1. **Collaboration state is not part of the data model.** Issues, reviews,
   approvals, and decisions should be signed, hash-linked, append-only
   entries replicated alongside the object graph. Clone the repo, get the
   argument that produced it. Offline review, real forkability, migration
   without an ETL project. Hosting then sells indexing, notification, and
   execution rather than captivity.
2. **The unit of change is a mutable branch pointer.** Gerrit's Change-Id,
   and later jj and Sapling, got this right: a change has stable identity
   with an ordered sequence of revisions. Force-push stops destroying review
   context, stacked changes become native rather than a tooling cottage
   industry, and "what changed since I last looked" becomes a first-class
   query. Comments anchor to semantic locations (AST node plus content
   hash), so they survive rebase.
3. **Review is anchored to text.** The line diff is the lowest-value view of
   a change. The high-value views are deltas: public API surface, type
   signatures, dependency set, capability set (new network, filesystem,
   secret, or syscall access), and observed test behavior. Conflict
   detection should be semantic, not textual.
4. **CI is untyped YAML with mutable third-party refs.** Not reproducible,
   not runnable locally, cache semantics invented per repo, and a standing
   supply-chain hole. The correct model is a hermetic, content-addressed
   build and test graph where CI is a pure function of repo state: identical
   locally and remotely, globally cached by input hash, affected-target test
   selection, and merge-queue correctness falling out as a property. Every
   result becomes an attestation over (input hash, toolchain hash, output
   hash).
5. **Trust is decorative.** Attribution is an email string; signing is
   opt-in and mostly ignored. Instead: verifiable identity with key rotation
   history, approvals as signed attestations over a specific revision hash,
   a transparency log, and in-toto/SLSA provenance linking source change to
   published artifact. "Requires two approvals" stops being UI state and
   becomes a checkable predicate over an evidence graph, with policy as
   versioned executable code rather than repository settings.
6. **There is no ecosystem graph.** A type-aware cross-repo code index
   (SCIP-class) joined to the package dependency graph unlocks downstream
   impact analysis, crater-style downstream test runs, codemods proposed as
   changes to dependents, and honest usage data.
7. **Agents authenticate as humans holding human tokens.** They need a
   distinct principal class: capability-scoped credentials, declared
   sandbox, mandatory provenance on every artifact, and an explicit
   delegation chain. The deeper economic point: as authoring cost approaches
   zero, trusted review capacity becomes the binding constraint. A forge
   designed now should optimize verification throughput, not authoring
   convenience. Changes arrive carrying machine-checkable evidence so a
   human reviews the argument rather than the diff.
8. **Secondary but real.** Attention management is an email firehose with
   no prioritization; ownership is a text file with no SLA, delegation, or
   expiry; maintainer funding is external; monorepo scale is handled by
   bolting LFS onto a model that assumes full clone.

### 1.2 Recommendation

A frontal assault fails. Radicle, Sourcehut, and Codeberg are each right
about something and marginal in adoption, because the network effect *is*
the product and migration cost is paid by the wrong party.

The viable wedge is to build the verification and review plane, not the
host. Federate over existing GitHub repos, mirror collaboration state
bidirectionally, and deliver value that requires no migration: stacked
changes, semantic review, hermetic globally-cached CI, signed provenance,
agent governance. Own the layer where value is currently moving (trust and
review), and let hosting commoditize underneath.

### 1.3 Tradeoffs accepted

- Signed, replicated, append-only collaboration data collides with erasure
  requirements and moderation. Capability-scoped encryption and content
  indirection from day one, not as a patch (spec 020).
- Hermetic builds tax developer ergonomics: everything must be declared, and
  the escape hatches are where the model leaks (spec 075).
- Semantic review requires per-language investment and degrades to plain
  text across the long tail (spec 025, 051).
- Agent capability scoping adds friction precisely where users want
  autonomy (spec 100 to 103).
- Decentralized state raises discovery cost; a central index is rebuilt
  anyway, without lock-in as its business model (spec 083, 084, 112).

## 2. The governing decision

What is canonical, and what is derived? Canonical state is a set of signed,
content-addressed objects forming a per-repository DAG covering code,
collaboration, and evidence. Every index, timeline, dashboard, search
result, and queue is a projection that must be rebuildable from zero. Hold
that invariant and portability, offline operation, federation, audit, and
schema evolution all fall out of one property. Violate it once and you have
rebuilt GitHub with extra steps.

## 3. Layer model

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

Boundaries are one-directional: L5 and above may only read from L0 to L4,
never write authoritatively.

## 4. Layer decisions

### L0: object store

BLAKE3 over SHA-256, primarily for verified streaming: the BAO tree gives
chunk-level verification and range proofs, so partial and lazy fetch are
verifiable by construction rather than trusted. Content-defined chunking
(FastCDC) plus a Merkle tree means LFS is just the general path with
different chunk statistics. Git compatibility is a hard requirement, so a
bidirectional object mapping is maintained through `gix` rather than libgit2
bindings. Local index in redb; remote in any S3-compatible store.
Immutability makes every cache layer trivially correct.

### L1: ledger

Entry shape: `{ parents: [Hash], issuer: KeyId, hlc: HybridLogicalClock,
payload: Cid, sig: Signature }`. A hash-linked DAG, not a linear log.

Facts versus derived state: facts are immutable events ("revision R
submitted", "attestation A issued", "comment C anchored at X") and never
conflict; concurrent facts merge by set union with a deterministic total
order (topological, tiebreak on hash). Derived state (issue open or closed,
labels, assignee, title) is the mutable projection; a hybrid logical clock
with last-writer-wins is sufficient for most of it. Sequence CRDTs are
reserved for genuinely collaborative text. The CRDT surface stays near five
percent of the domain.

Erasure, decided at entry one: the signed log contains commitments (CIDs),
never user content. Content lives in the blob store, encrypted per namespace
where it must be. Deletion removes the blob; the log keeps a tombstoned
commitment. Not retrofittable.

Serialization is canonical and deterministic (DAG-CBOR) with
forward-compatible unknown-field preservation. Signed history cannot be
rewritten, so schema evolution is a permanent constraint, and any
nondeterminism in canonicalization silently invalidates every signature
downstream. Hash stability is fuzzed in CI from the first commit.

Replication: range-based set reconciliation over QUIC for DAG head exchange
(`iroh`, `quinn`; Willow is the prior art to study). Server-side, per-repo
Raft groups over an embedded Raft-replicated SQLite (Hiqlite) let repos
shard across nodes without a separate database tier.

### L2: domain model

Every form of evidence is one primitive: `Attestation { subject: Hash,
predicate: PredicateType, issuer: Principal, claim: Cid, sig }`. Human
approval, build provenance, test result, SAST finding, license scan, policy
evaluation, and agent action are all the same shape (in-toto's statement
model, generalized). One storage path, one verification path, one policy
input, one audit trail.

Other nouns: `Change` (stable identity) with ordered `Revision`s, each a tree
hash plus base; `Anchor { path, tree_sitter_node_path, node_content_hash }`;
`Principal = Human | Agent | Service | Org` at the type level; `Policy` as
versioned, hash-pinned, executable.

### L3: evaluation plane

`eval(repo_state_hash, target, toolchain_hash) -> output_hash`, cached
globally on input hash. Implement the Bazel Remote Execution API. Two
sandbox tiers: namespaces plus seccomp with no network for trusted work;
microVMs (Firecracker or Cloud Hypervisor) for fork contributions and agent
execution. Every execution emits a signed provenance attestation. Merge
queues are speculative evaluation over candidate merge states. The cache is a
trust boundary: entries carry executor identity and are verifiable;
unattested cache hits are cache misses for anything that gates a merge.

### L4: trust plane

OIDC (Rauthy) for login and workforce federation. Durable identity is a
keypair with a rotation chain in the ledger. Keyless signing in the Sigstore
shape with transparency-log inclusion proofs, self-hosted when sovereignty
matters. Agents carry Biscuit tokens: delegation chain in the token,
monotonic offline-verifiable attenuation, datalog caveats.

### L6: policy

Merge predicate `f(change, attestation_set, policy_version) -> Allow |
Deny(reasons)`, deterministic and side-effect free, compiled to WASM with a
typed SDK, hash-pinned to repo state, evaluable locally before push, emitting
an attestation per evaluation.

## 5. Language

Rust for the entire trusted core (L0 through L2, L4, L6): type-encodable
invariants, mature libraries, no GC pauses on the content-addressed hot
path, and single-binary embedding so the CLI and the server run the same
ledger implementation. Go for the executor that orchestrates existing
container runtimes. One language boundary, at the REAPI seam; the domain
model stays on the Rust side.

## 6. Build order

1. Ledger, object store, domain model, CLI. Local only, no server. Prove
   offline review against a plain git repo.
2. Git bridge and bidirectional GitHub mirror. Users without migration.
3. Change/Revision, semantic anchors, stacked changes. First felt value.
4. Attestation model and policy engine. Merge gates become verifiable.
5. Evaluation plane. Highest capex, depends on stable input hashing.
6. Cross-repo code and ecosystem graph.
7. Agent principals and delegation. Designed into the types at step 1.
8. Multi-host federation.

The corpus encodes this as spec ordinals; see `01-build-order.md` for the
rendered DAG.

## 7. Standing risks

- Schema evolution against signed history: version everything, preserve
  unknown fields, never reorder.
- CRDT surface creep: hold the facts versus derived-state line under product
  pressure.
- Cross-repo indexes are the one legitimately centralized component; isolate
  them and keep them non-authoritative.
- Abuse in an append-only replicated store: untrusted contributions land in
  a quarantine namespace and are promoted by capability, not accepted by
  default.

The system this becomes is not a forge. It is a verifiable evidence ledger
for software change, where hosting, CI, and review UI are interchangeable
implementations over the same signed history.

## 8. How this corpus is built

The corpus is authored in full before any code (thesis D17). Every ordinary
spec is `status: approved`, `implementation: pending`, and bounded to one
driven session's territory. claude-observatory registers this repository as
a project, schedules the lowest-numbered ready spec, drives one fresh Claude
Code session through the `## Working the backlog` protocol in `AGENTS.md`,
ships through the repo's own `/ship` skill and hooks, shepherds the PR
through the CI this corpus wires, and runs the spec's `## Verification`
block after merge. Done is never self-authored: completion is adjudicated by
`spec-spine`'s gate over a corpus the session may not amend in its own
favor.
