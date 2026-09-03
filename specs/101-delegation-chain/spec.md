---
id: "101-delegation-chain"
title: "Delegation chain: delegation facts, chain resolution to a human root, and authorize"
status: approved
kind: "kernel"
domain: "l4-trust"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 7
depends_on:
  - "100-agent-principals"
establishes:
  - "crates/hqgit-agent/src/delegation.rs"
  - "crates/hqgit-agent/src/authorize.rs"
  - "crates/hqgit-agent/tests/delegation.rs"
  - "crates/hqgit-agent/testdata/delegation/"
extends:
  - { spec: "100-agent-principals", unit: "crates/hqgit-agent/src/lib.rs", nature: additive }
  # agent.delegated, agent.delegation_revoked, agent.action_denied join the vocabulary.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  The accountability chain as a cryptographic object. Every token an
  agent holds is mirrored by an agent.delegated fact naming who delegated,
  to which agent, under which pinned policy, with which caveats, expiring
  when, so the chain is queryable long after the bearer token is gone. A
  sub-delegation is a new token rooted in the delegating agent's identity
  key with a caveat set at least as strict as its parent's. This spec
  fixes the facts, the DelegationView fold, delegation_chain resolving an
  agent to its human or org root within a bounded depth, and authorize:
  a pure function combining Biscuit verification (100) with the ledger's
  registrations, revocations, and policy pin (068), returning Allow with
  the chain hash or Deny with a closed reason that the caller journals as
  an agent.action_denied fact.
---

# 101: Delegation chain

## 1. Purpose

Constitution XII: an agent's credential carries its delegation chain,
which human, under which policy version, expiring when. A Biscuit token
carries that chain to whoever holds it, but tokens expire, are lost, and
are never appended to a ledger. Audit needs the chain to survive the
token, and revocation needs a place a holder cannot suppress. This spec
puts both in facts, and it makes the authorization decision one function
with one fixed order of checks, so every replica and every test reaches
the same verdict from the same ledger.

## 2. Territory

`delegation.rs` (the facts, `DelegationId`, `DelegationView`,
`delegation_chain`, `Chain::hash`) and `authorize.rs` (`ActionRequest`,
`AuthzContext`, `authorize`, `DenyReason`, the journal fact) in
`crates/hqgit-agent`, `tests/delegation.rs`, and chain fixtures under
`testdata/delegation/`. Additively: the crate's `lib.rs` and three fact
variants in 023's `facts.rs`. Sandbox validation and the server seam are
102.

## 3. Behavior

- **B-1 (facts).** Frozen kinds: `agent.delegated { from: Principal, to:
  AgentId, policy: Cid, scope: Vec<Caveat>, expires: Option<Hlc>,
  revocation_id: Hash, nonce: Nonce, extra }` whose `DelegationId =
  Hash::of(canonical body bytes)` (023 B-3 style); `agent.delegation_revoked
  { delegation: DelegationId, by: Principal, reason: String, extra }`;
  `agent.action_denied { agent: Option<AgentId>, operation: String,
  namespace: Hash, reason: String, detail: String, request_hash: Hash,
  extra }`. `from.kind()` MUST be `Human`, `Org`, or `Agent`, never
  `Service`; `to` MUST be registered (100 B-2). `agent.delegated` MUST be
  signed by `from`'s active key at the entry `hlc`; a revocation by
  `from`, by any principal above it in the chain, or by `to`'s operator;
  `agent.action_denied` by the authorizing service. `revocation_id` is the
  authority block's id (100 B-6) of the token this fact mirrors, so a
  `delegation_revoked` also revokes that token.
- **B-2 (`DelegationView`).** A `DerivedState` fold: `links_to(agent) ->
  Vec<Link>` sorted by `at` descending, `link(id) -> Option<Link>`,
  `is_revoked(id) -> bool`, `revoked_ids() -> BTreeSet<Hash>` (union of
  every revoked delegation's `revocation_id`), and `defects()`. `Link {
  id: DelegationId, from, to, policy, scope: Vec<Caveat>, expires, at:
  Hlc, entry: EntryHash }`. A malformed or mis-signed fact is a defect,
  never applied (060 B-6).
- **B-3 (chain).** `delegation_chain(view, agents: &AgentView, agent,
  at: &Hlc) -> Result<Chain, ChainError>` picks, for `agent`, the newest
  link valid at `at` (not revoked, not expired, issued at or before
  `at`) and, while `from` is an `Agent`, repeats for it; `MAX_DEPTH = 8`.
  `Chain { links: Vec<Link> (leaf first), root: Principal }`; `root` is
  the last link's `from`. `ChainError` is `NoDelegation(AgentId) |
  Revoked(DelegationId) | Expired(DelegationId) | TooDeep(u8) |
  NoHumanRoot | ScopeWidened { link: DelegationId } | NotRegistered(AgentId)`.
  Monotonicity: every caveat of a parent link MUST appear, structurally
  equal, in its child link's `scope`, else `ScopeWidened`. `Chain::hash()
  = Hash::of(canonical bytes of the Vec<DelegationId> leaf first)`, the
  value 102's claim carries. Chain resolution is pure and deterministic.
- **B-4 (`authorize`).** `pub fn authorize(req: &ActionRequest, cred:
  &AgentCredential, ctx: &AuthzContext<'_>) -> Decision` with
  `ActionRequest { operation: Operation, namespace: Hash, paths:
  Vec<String>, predicate: Option<PredicateType>, revision_bytes:
  Option<u64>, fact_kind: Option<String> }` (sorted, deduplicated paths),
  `AuthzContext { now: Hlc, identities: &IdentityView, agents:
  &AgentView, delegations: &DelegationView, active_policy: Cid, sandbox:
  &dyn SandboxCheck, service: Principal }` where `trait SandboxCheck { fn
  check(&self, registration: &Registration) -> Result<(), String>; }`
  (102 supplies the real one; `AcceptAll` ships here for tests), and
  `Decision::{Allow(Grant { agent, chain: Chain, chain_hash: Hash, root:
  Principal, operation, namespace }), Deny(Denial { agent:
  Option<AgentId>, reason: DenyReason, request_hash: Hash })}` with
  `request_hash = Hash::of(canonical ActionRequest)`. Checks run in this
  order and the first failure is the reason:
  1. `resolve_agent` (100 B-7): `NotAgentToken`, `IssuerKeyUnknown`,
     `IssuerKeyInvalid(KeyValidity)`, `TokenInvalid`, `NotRegistered`,
     `Deregistered`, `OperatorMismatch`;
  2. `ctx.sandbox.check(registration)`: `SandboxUndeclared(String)`;
  3. the leaf link: a link `to = agent` whose `from` is the identity of
     `cred.issuer_key`, valid at `now`: `NoDelegation`;
  4. `delegation_chain`: `DelegationRevoked`, `DelegationExpired`,
     `ChainTooDeep`, `NoHumanRoot`, `ScopeWidened`;
  5. `authority.policy` versus `ctx.active_policy` and every link's
     `policy`: `PolicyMismatch { token: Cid, active: Cid }`;
  6. `req.namespace` in the authority's namespaces: `NamespaceNotGranted`;
  7. the token's revocation ids against `agents.revoked(agent)` and
     `delegations.revoked_ids()`: `TokenRevoked(Hash)`;
  8. `token.check` with the B-5 (100) facts built from `req` and `now`:
     `Expired`, `NotYetValid`, `CaveatFailed(String)`,
     `CapabilityMissing(Operation)`.
  `DenyReason` is that closed enum plus `HumanSessionPresented` (raised by
  102 when a human session reaches an agent path) with `wire_name() ->
  &'static str` in kebab-case (`policy-mismatch`, `chain-too-deep`).
- **B-5 (journal).** `Denial::to_fact(&self, req: &ActionRequest) ->
  DomainFact` builds the `agent.action_denied` fact with `reason =
  wire_name()` and `detail` the human text. Every caller of `authorize`
  that holds a ledger (the server, 102) MUST append it for every `Deny`;
  `authorize` itself appends nothing and reads no clock.
- **B-6 (allow is narrow).** A `Grant` names exactly one operation and
  one namespace; a request spanning namespaces is two requests. The grant
  carries the chain so 094 can tag the write and 102 can check provenance
  against `chain_hash` without a second resolution.

## 4. Functional requirements

- **FR-001.** Fixtures under `testdata/delegation/`: `chains.json` with
  seeds, fixture `Hlc`s, the fact bodies for a three-link chain (human
  to agent A to agent B to agent C), and the expected `DelegationId`s
  and `Chain::hash` (frozen, constitution VIII); `deny-table.json`
  listing every `DenyReason` wire name.
- **FR-002.** Tests cover: a depth-8 chain resolves and depth 9 is
  `ChainTooDeep`; revoking the middle link denies the leaf and leaves the
  middle agent's own chain intact; an expired link; a link whose `scope`
  drops a parent caveat is `ScopeWidened`; a chain rooted in a `Service`
  is `NoHumanRoot`; `PolicyMismatch` when 068's active pin moves; a
  namespace outside the grant; a revoked delegation also revokes its
  token; each ordered check in B-4 is reached by a fixture that passes
  every earlier one; every `DenyReason` produces a journal fact whose
  `reason` equals its wire name; permutation of fact arrival yields the
  same view; the allow path returns the frozen `chain_hash`.
- **FR-003.** `authorize` is a pure function of its arguments; a test
  calls it twice on the same inputs and asserts equal `Decision`s.
- **FR-004.** `register_agent_facts` (100 FR-003) registers B-1's three
  kinds as well; the fact-kinds vector gains them.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-agent --locked delegation` passes,
  fixtures included.
- **AC-2.** For the fixture chain, `authorize` of an `Append` under agent
  C's token returns `Allow` whose `root` is the fixture human and whose
  `chain_hash` equals `chains.json`; after `agent.delegation_revoked` on
  A's link it returns `Deny(DelegationRevoked)`.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The sandbox check implementation and the agent-action claim (102); the
server's credential extraction, route classes, and the actual journaling
append (102); quarantine tagging of agent writes (094); ownership-based
delegation of review duty (104, a different chain).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-agent --locked delegation
```
