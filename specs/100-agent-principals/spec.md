---
id: "100-agent-principals"
title: "Agent principals: registration facts, Biscuit tokens, and the caveat vocabulary"
status: approved
kind: "kernel"
domain: "l4-trust"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 7
depends_on:
  - "060-identity-and-key-rotation"
  - "068-policy-in-repo"
establishes:
  - "crates/hqgit-agent/Cargo.toml"
  - "crates/hqgit-agent/src/lib.rs"
  - "crates/hqgit-agent/src/token.rs"
  - "crates/hqgit-agent/src/principal.rs"
  - "crates/hqgit-agent/src/caveats.rs"
  - "crates/hqgit-agent/tests/"
  - "crates/hqgit-agent/testdata/tokens/"
extends:
  # biscuit-auth (pinned exact) joins the shared dependency table.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
  # agent.registered, agent.deregistered, agent.token_revoked join the vocabulary.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  Constitution XII and thesis D12: an agent is a distinct principal class
  and never authenticates as a human. This spec founds hqgit-agent and
  fixes how an agent becomes one: an identity of kind Agent (060) that an
  operator, a human or an org, registers with a fact naming the runtime
  and the declared sandbox; a Biscuit token whose authority block is
  signed by the operator's identity key and names the agent, the
  registration entry, the pinned policy (068), the namespaces, the
  capabilities, and an expiry; attenuation that can only add caveats,
  from a frozen datalog vocabulary over namespace, path, predicate,
  revision size, operation, and time window; offline verification against
  the operator's key as the 060 fold knew it at issuance; and revocation
  by fact. The chain of delegations and the authorize function are 101.
---

# 100: Agent principals

## 1. Purpose

Design §1.1 point 7: agents authenticate as humans holding human tokens,
so nothing about their scope, sandbox, or accountability is recorded.
Thesis §4.5 answers with Biscuit: the delegation chain lives in the
token, attenuation is monotonic and verifiable offline, and caveats are
datalog. The `Principal::Agent` variant has existed since 010 B-6 so the
type system could refuse a human token on an agent path from the first
line of code; this spec supplies the credential and the registration
that variant was waiting for. Tokens are bearer secrets and never enter
the ledger; the facts that make them meaningful do.

## 2. Territory

`crates/hqgit-agent` as founded here: the manifest (workspace deps
`hqgit-types`, `hqgit-object`, `hqgit-ledger`, `hqgit-domain`,
`hqgit-trust`, `hqgit-policy`, and `biscuit-auth`), `lib.rs`,
`token.rs` (issue, attenuate, parse, check), `principal.rs` (the
registration facts, `AgentView`, credential resolution), `caveats.rs`
(the vocabulary and its datalog), the `tests/` subtree, and frozen datalog
vectors under `testdata/tokens/`. Additively: the fact variants in 023's
`facts.rs` and the dependency table. Delegation facts and `authorize` are
101; the sandbox type and provenance are 102.

## 3. Behavior

- **B-1 (facts).** Frozen kinds: `agent.registered { agent: AgentId,
  operator: Principal, runtime: String, sandbox: Value, extra }`,
  `agent.deregistered { agent: AgentId, operator: Principal, reason:
  String, extra }`, `agent.token_revoked { agent: AgentId, revocation_id:
  Hash, reason: String, extra }`. `operator.kind()` MUST be `Human` or
  `Org`. The agent MUST already exist as an `identity.created` of kind
  `Agent` (060 B-2) in the same ledger. `agent.registered` and
  `agent.deregistered` MUST be signed by the operator's active key at the
  entry's `hlc` (060 B-5); `agent.token_revoked` by the operator's or the
  agent's. `sandbox` is an opaque canonical `Value` here; 102 gives it a
  type and a rule.
- **B-2 (`AgentView`).** A `DerivedState` (019) folding B-1 in total
  order: `registration(agent) -> Option<Registration { agent, operator,
  runtime, sandbox: Value, entry: EntryHash, at: Hlc }>` (the latest by
  `Hlc` wins, an LWW register), `is_active(agent, at) -> bool` (registered
  and not deregistered at `at`), `revoked(agent) -> BTreeSet<Hash>` of
  revocation ids, and `defects() -> &[ChainDefect]` in 060 B-6's shape: a
  fact violating B-1 is recorded and never applied.
- **B-3 (root key).** The operator's identity key is the Biscuit root
  key: `token.rs` converts a 010 `Ed25519Signer` seed to a
  `biscuit_auth::KeyPair` and a 010 `PublicKey` to a
  `biscuit_auth::PublicKey`, 32 bytes each way, with no second key
  material. A token is verified against `IdentityView::key_valid_at(
  issuer_key, issued_at)` (060): a rotation after issuance keeps the
  token valid until it expires; a revocation whose `since` precedes
  `issued_at` invalidates it.
- **B-4 (authority block, frozen).** `Authority { agent: AgentId,
  operator: Principal, issuer_key: KeyId, registration: EntryHash,
  policy: Cid, namespaces: BTreeSet<Hash>, capabilities:
  BTreeSet<Operation>, issued_at_ms: u64, expires_ms: u64 }` renders as
  block 0, one fact per line in this order:
  `hq_version(1); agent("<hex>"); operator("<kind>:<hex>");
  issuer_key("<hex>"); registration("<hex>"); policy("<cid>");
  namespace("<hex>");` (one per namespace, sorted), `capability("<op>");`
  (one per operation, sorted), `issued_at(<ms>); expires(<ms>);
  check if now($t), $t >= <issued_at>, $t < <expires>;`.
  `Operation` is a closed enum `Read | Append | Attest | ReadQuarantine`
  with wire strings `read`, `append`, `attest`, `read-quarantine`.
  `expires_ms - issued_at_ms` MUST be at most 30 days (`Error::Validation`
  on issue). The authorizer's policies are `allow if operation($o),
  capability($o);` then `deny if true;`; because Biscuit scopes rules to
  the authority and authorizer facts, a `capability` fact added in a
  later block is invisible: attenuation cannot widen.
- **B-5 (caveats, frozen).** `Caveat` is a closed enum whose
  `to_datalog()` is one check each, over the authorizer facts `now(ms)`,
  `operation(str)`, `namespace(hex)`, `path(str)` (one per file touched;
  `path("")` when none), `predicate(str)` (`""` when none),
  `revision_bytes(u64)` (`0` when none), and `fact_kind(str)` (`""` when
  none), every fact always supplied so no caveat fails vacuously:
  `Namespace(h)` is `check if namespace("<h>");`; `PathPrefix(p)` is
  `check all path($p), $p == "" || $p.starts_with("<p>");`;
  `PathPattern(re)` is `check all path($p), $p == "" || $p.matches("<re>");`;
  `PredicateIn(list)` is `check if predicate($p), $p == "" || [<list>].contains($p);`;
  `MaxRevisionBytes(n)` is `check if revision_bytes($s), $s <= <n>;`;
  `TimeWindow { from_ms, until_ms }` is `check if now($t), $t >= <from>, $t < <until>;`;
  `OperationIn(list)` is `check if operation($o), [<list>].contains($o);`;
  `FactKindIn(list)` is `check if fact_kind($k), $k == "" || [<list>].contains($k);`.
  Strings are escaped as Biscuit requires; lists are sorted. `Caveat`
  derives `Canonical` (011) so a caveat set can live in a fact (101).
- **B-6 (token API).** `AgentToken(Biscuit)` with `issue(root:
  &KeyPair, authority: &Authority) -> Result<AgentToken, Error>`,
  `attenuate(&self, caveats: &[Caveat]) -> Result<AgentToken, Error>`
  (one new block whose checks are B-5's, in order), `parse(bytes, root:
  &PublicKey) -> Result<AgentToken, Error::Crypto>`, `authority(&self) ->
  Result<Authority, Error>` (decoded from block 0; a missing fact is
  `Error::Validation` naming it; a token without `agent` is
  `TokenDeny::NotAgentToken`), `revocation_ids(&self) -> Vec<Hash>` (each
  `Hash::of` of a block's Biscuit revocation identifier, authority first),
  and `check(&self, facts: &AuthorizerFacts, revoked: &BTreeSet<Hash>)
  -> Result<(), TokenDeny>`. `TokenDeny` is `NotAgentToken | Signature |
  Expired { expires_ms, now_ms } | NotYetValid { issued_at_ms, now_ms } |
  Revoked(Hash) | CaveatFailed(String) | CapabilityMissing(Operation)`.
  `AgentCredential { token: Vec<u8>, issuer_key: KeyId }` has the text
  form `hqa1.<base64url of its canonical bytes>`; `AgentCredential::parse`
  rejects any other prefix with `NotAgentToken`.
- **B-7 (resolution).** `resolve_agent(cred, identities: &IdentityView,
  agents: &AgentView, at: &Hlc) -> Result<ResolvedAgent { agent,
  operator, registration, token }, ResolveError>` in a fixed order:
  `issuer_key` known to an identity (`UnknownIssuerKey`); valid at
  `issued_at` (`IssuerKeyInvalid(KeyValidity)`); token signature
  (`Signature`); authority decodes; `agent` registered and active at `at`
  (`NotRegistered`, `Deregistered`); `registration` equals the view's
  entry hash and `operator` equals the registration's operator and the
  issuer key's identity (`OperatorMismatch`). The function never returns
  a `Principal::Human`; a 061 session is not an `AgentCredential` and
  fails at B-6's prefix check (102 enforces the converse on routes).
- **B-8 (policy pin).** `authority.policy` is compared with 068's
  `active_policy(repo, at, scope)` by 101; here `Authority::policy_matches(
  &self, active: &Cid) -> bool` is the one comparison both use.
- **B-9 (no ambient input).** `now` is an `Hlc` the caller supplies (the
  server's 018 generator); the crate reads no clock and no environment;
  seeds are never `Debug`-printed; `BTreeMap` and `BTreeSet` only.

## 4. Functional requirements

- **FR-001.** Vectors under `testdata/tokens/`: `authority.datalog` (the
  rendered block 0 for a fixture `Authority`), `caveats.json` (every
  `Caveat` variant and its frozen datalog), `seeds.json` (operator and
  agent seeds, fixture `Hlc`s). Token bytes are not frozen (Biscuit
  block signatures are randomized); the rendered datalog is.
- **FR-002.** Tests cover: issue then parse under the operator key;
  parse under another key fails; an attenuation adding `capability(
  "append")` to a read-only token still denies `append`; each caveat
  admits its fixture and rejects its counterexample; expiry and
  not-yet-valid; a revocation id recorded by `agent.token_revoked` denies
  the token and its attenuations; rotation after issuance still
  resolves; revocation with `since` before issuance does not; a
  deregistered agent does not resolve; `OperatorMismatch`; a registration
  signed by a non-operator key is a defect; a 30-day-plus lifetime is
  refused; permutation of fact arrival yields the same `AgentView`.
- **FR-003.** `register_agent_facts(registry)` registers exactly the
  three B-1 kinds; 023's `domain/fact-kinds.json` gains them (a visible
  vector change, 023 FR-002).
- **FR-004.** The manifest carries `[package.metadata.spec-spine] spec =
  "100-agent-principals"` and depends on no crate above L6.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-agent --locked` passes, vectors included.
- **AC-2.** `spec-spine index` discovers `hqgit-agent` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.
- **AC-3.** A token issued for `Read` and attenuated to `PathPrefix(
  "crates/hqgit-agent/")` passes `check` for a read of that path and fails
  for a read of `crates/hqgit-trust/` and for any `Append`.

## 6. Out of scope

Delegation facts, chain resolution, and `authorize` (101); the sandbox
type, agent-action provenance, and the server's credential handling
(102); evidence bundles (103); OIDC sessions for humans (061); third-party
Biscuit blocks signed by external keys (not used: a sub-delegation is a
new token rooted in the delegator's key, 101).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-agent --locked
cargo clippy -p hqgit-agent --all-targets --locked -- -D warnings
```
