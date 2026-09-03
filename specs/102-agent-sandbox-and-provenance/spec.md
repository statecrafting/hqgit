---
id: "102-agent-sandbox-and-provenance"
title: "Agent sandbox and provenance: declared sandboxes, the agent-action attestation, and the server seam"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 7
depends_on:
  - "101-delegation-chain"
  - "074-execution-provenance"
  - "090-server-skeleton"
establishes:
  - "crates/hqgit-agent/src/sandbox.rs"
  - "crates/hqgit-agent/src/provenance.rs"
  - "crates/hqgit-agent/tests/provenance.rs"
  - "crates/hqgit-server/src/agent_auth.rs"
  - "crates/hqgit-server/tests/agent_auth.rs"
extends:
  - { spec: "100-agent-principals", unit: "crates/hqgit-agent/src/lib.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/lib.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/app.rs", nature: additive }
  # hqgit-agent joins the server's manifest.
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/Cargo.toml", nature: additive }
  # The agent-action claim schema fills the slot 027 reserved.
  - { spec: "027-attestation-primitive", unit: "crates/hqgit-domain/src/predicate.rs", nature: additive }
summary: >
  Constitution XII's last two clauses: an agent's sandbox is declared and
  every artifact it produces carries provenance. This spec types the
  sandbox an agent registration names (always the Untrusted tier of 073
  for execution, with declared tools and network), fills the
  hqgit/agent-action/v1 claim slot 027 reserved with a schema binding the
  agent, its delegation chain hash (101), its sandbox, its inputs, a
  summary of its tool calls, and the execution provenance (074) of
  anything it ran, signed by the agent's own key; fixes the rule that an
  agent-submitted revision without such an attestation is refused; and
  builds the server seam that accepts Biscuit credentials, refuses a
  human session on an agent route and the reverse, journals every denial
  (101), and tags every agent write so quarantine (094) applies.
---

# 102: Agent sandbox and provenance

## 1. Purpose

Design §1.1 point 7 asks for a declared sandbox, mandatory provenance on
every artifact, and an explicit delegation chain; 100 and 101 delivered
the credential and the chain, and this spec attaches the other two to
the artifacts themselves. Thesis §4.4 fixes that agent execution gets the
microVM tier; 073 B-2 encodes that rule on the Rust side. Here the
registration cannot claim otherwise, the claim an agent signs over its
work names the chain and sandbox the ledger can recompute, and the server
is the one place a bearer credential is turned into a principal.

## 2. Territory

In `crates/hqgit-agent`: `sandbox.rs` (`DeclaredSandbox`, validation, the
101 `SandboxCheck` implementation), `provenance.rs` (the claim, issuing,
claim-level verification, the mandatory-provenance rule), and
`tests/provenance.rs`. In `crates/hqgit-server`: `agent_auth.rs` (the
credential layer, route classes, write tagging, journaling) and
`tests/agent_auth.rs`. Additively: both crates' `lib.rs`, the server's
`app.rs` (the layer is installed) and manifest, and the claim validator
in 027's registry. The API routes themselves are 093's; quarantine is
094's.

## 3. Behavior

- **B-1 (declared sandbox).** `DeclaredSandbox { tier: DeclaredTier,
  runtime: String, tools: BTreeSet<String>, network: NetworkAllowance,
  rootfs: Option<Hash>, extra }` with `DeclaredTier` a closed enum whose
  only variant is `Untrusted` (wire string `untrusted`, equal to 073's
  spelling; the crate does not depend on `hqgit-eval`, and the server
  maps the wire string to 073's `SandboxTier` at the seam) and
  `NetworkAllowance::{None, Hosts(BTreeSet<String>)}`. `from_value` and
  `to_value` type the opaque `sandbox` of 100 B-1. `validate(reg:
  &Registration) -> Result<DeclaredSandbox, SandboxError::{Malformed(String),
  TierNotUntrusted(String), EmptyRuntime}>`; `RegisteredSandbox`
  implements 101's `SandboxCheck` by calling it, so a registration that
  names any other tier denies every action with `SandboxUndeclared`.
- **B-2 (claim schema).** `PredicateType("hqgit/agent-action/v1")` gains
  the validator for `AgentActionClaim { agent: AgentId, chain_hash: Hash,
  root: Principal, policy: Cid, sandbox: DeclaredSandbox, inputs:
  Vec<InputRef { kind: InputKind::{Tree, Revision, Attestation, Object,
  Prompt}, hash: Hash }>, tool_calls: ToolCallSummary { count: u32,
  by_tool: BTreeMap<String, u32>, transcript: Option<Cid>,
  transcript_hash: Hash }, executions: Vec<AttestationId>, runtime:
  String, model: Option<String>, extra }`. `inputs` and `executions` MUST
  be sorted and deduplicated; `executions` name 074 provenance
  attestations for every action the agent ran; `transcript` is an
  erasable object (constitution X) and `transcript_hash` is its cid hash,
  so erasure leaves the commitment; `by_tool` values MUST sum to `count`.
  The attestation's `subject` is the revision id (or other subject hash)
  the agent submits and its `issuer` MUST be `Principal::Agent(agent)`.
- **B-3 (issue).** `issue_agent_action(signer: &impl Signer, input:
  &AgentActionInput, at: Hlc) -> Result<(Attestation, Value), Error>`
  builds the claim, validates it through the registry, and signs through
  027 B-3 with `issuer = Principal::Agent(input.agent)`; the caller stores
  the claim object and appends `attestation.issued`. `issuer_key` MUST be
  the agent identity's active key (060) at `at`.
- **B-4 (verify).** `verify_agent_action(att: &Attestation, claim: &Value,
  ctx: &ProvenanceContext { chain: &Chain, registration: &Registration,
  active_policy: &Cid }) -> Result<(), ProvenanceError>` runs after 064's
  signature and identity chain: `NotAgentIssuer`, `AgentMismatch`
  (claim agent, issuer, and registration disagree), `ChainHashMismatch {
  claimed, computed }` (`ctx.chain.hash()` recomputed by 101 at `att.at`),
  `SandboxMismatch` (claim sandbox differs from the registration's
  validated one), `PolicyMismatch`, `ClaimInvalid(String)`, in that order.
- **B-5 (mandatory provenance).** `require_provenance(subject: &Hash,
  submitted_by: &Principal, attestations: &[Attestation]) -> Result<(),
  MissingProvenance>`: when `submitted_by.kind() == Agent`, an
  `hqgit/agent-action/v1` attestation over `subject` issued by that agent
  MUST be present. It applies to `change.revision_submitted` (subject the
  revision id) and to every attestation an agent issues under another
  predicate (subject the same). A human or service submitter passes
  without one.
- **B-6 (server credential layer).** `AgentAuthLayer { state:
  AgentAuthState { identities, agents, delegations, policy: Box<dyn
  ActivePolicy>, journal: Box<dyn LedgerAppend>, service: Principal, clock:
  HlcGenerator } }` is a tower layer installed in `app.rs`. `Authorization:
  Bearer hqa1.<...>` is an `AgentCredential`; any other bearer or a 061
  session cookie is a human credential; both present is `400
  mixed-credentials`. `trait RouteClassifier { fn classify(&self, method:
  &Method, path: &str) -> RouteClass::{Human, Agent, Either}; }` with
  `PrefixClassifier` (`/api/agent/` Agent, `/login` and `/session` Human,
  everything else Either) as the default 093 replaces with its route
  table. A human credential on an `Agent` route is `403
  human-session-on-agent-route` and is journaled with reason
  `human-session-presented`; an agent credential on a `Human` route is
  `403 agent-on-human-route`.
- **B-7 (authorize and tag).** For an agent credential the layer builds
  the 101 `ActionRequest` (operation from the method and route, namespace
  from the repository, paths and sizes from the body when the handler
  declares them through `RequestFacts`), calls `authorize`, appends
  `Denial::to_fact` through `journal` on every `Deny` (101 B-5), and
  answers `403 { "error": "agent-denied", "reason": <wire name>,
  "request_hash": <hex> }`. On `Allow` it inserts `WritePrincipal::Agent
  { agent, chain_hash, root }` into the request extensions; every write
  handler MUST read `WritePrincipal` and pass it to 094's quarantine
  path, and a handler that appends without one is a defect the fixture
  handler in FR-003 asserts against.
- **B-8 (provenance at the write seam).** For an agent write carrying a
  revision or an attestation, the layer's `check_agent_write` runs B-5
  and B-4 on the attestations in the same request: absence is `422
  agent-provenance-required`; a claim failing B-4 is `403
  agent-provenance-invalid` with the `ProvenanceError` name; both are
  journaled. The write never reaches the ledger.
- **B-9 (no ambient input in the crate).** `hqgit-agent` reads no clock;
  the server supplies `now` from its 018 generator. Rate limits and size
  caps are 094's and are not duplicated here.

## 4. Functional requirements

- **FR-001.** Agent-crate tests cover: the validator accepts the fixture
  claim and rejects one missing `chain_hash`, one with unsorted `inputs`,
  and one whose `by_tool` does not sum; `validate` refuses a `trusted`
  tier and an empty runtime; issue then `verify_agent_action` on a 101
  fixture chain passes; each `ProvenanceError` in B-4 order; `require_provenance`
  fails for an agent without the attestation, passes with it, and passes
  for a human; erasing the transcript object leaves verification intact.
- **FR-002.** Server tests boot the 090 skeleton on an ephemeral port
  with a fixture router of three routes (one per `RouteClass`) and a fake
  `LedgerAppend`: an agent credential on the `Agent` route reaches the
  handler with `WritePrincipal::Agent`; the same on the `Human` route is
  403; a human session on the `Agent` route is 403 and journaled; a
  denied agent yields 403 with the wire reason and one journaled fact;
  mixed credentials 400; a revision write without provenance 422; one
  with a wrong chain hash 403 `agent-provenance-invalid`.
- **FR-003.** The fixture write handler panics if `WritePrincipal` is
  absent, so the layer's tagging is exercised, not assumed.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-agent --locked provenance` and `cargo
  test -p hqgit-server --locked agent_auth` pass.
- **AC-2.** Against the ephemeral server, a scripted agent with the 101
  fixture chain submits a revision with a valid agent-action attestation
  and receives 200 with the write tagged; the same submission without the
  attestation receives 422 and appends nothing.

## 6. Out of scope

Quarantine placement, rate limits, and promotion of agent writes (094);
the API routes and their classifier table (093); the evidence bundle an
agent-authored change carries (103); running agents (the runtime is an
external client of the API); executing agent-requested actions (072,
073; the tier rule is theirs).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-agent --locked provenance
cargo test -p hqgit-server --locked agent_auth
```
