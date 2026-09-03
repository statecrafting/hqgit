---
id: "003-chassis-alignment"
title: "Chassis alignment: what the hosted edge consumes from rahi, and what stays hqgit's"
status: approved
kind: "governance"
domain: "governance"
created: "2026-09-03"
authors: ["Bartek Kus"]
implementation: n-a
risk: critical
wave: 1
depends_on:
  - "002-platform-thesis"
constrains:
  - kind: family-boundary
    target_specs:
      - "010-workspace-and-core-types"
      - "017-ledger-entry-dag"
      - "060-identity-and-key-rotation"
      - "061-oidc-login"
      - "090-server-skeleton"
      - "091-per-repo-control-plane"
      - "093-connect-api"
      - "094-quarantine-and-promotion"
      - "095-web-review-ui"
      - "100-agent-principals"
      - "101-delegation-chain"
summary: >
  A Rust chassis named rahi now exists in this family and owns identity,
  replicated operational state, a decision chain, a capability kernel, an
  axum edge, and single-container packaging. Without a decision on record,
  the wave 6 server specs would found all of that a second time, and a
  deployment would contain two things called a ledger. This spec draws the
  boundary: waves 1 through 5 stay chassis-free so the CLI works with no
  server, the wave 6 server composes rahi as a Cell, the evidence DAG never
  moves into the chassis store, hqgit's cryptographic identity stays
  authoritative with the IdP as an authentication subject bound to it, and
  the word ledger keeps one meaning in this repository.
---

# 003: Chassis alignment

## 1. Purpose

The thesis was written before the family had a chassis. It now has one:
`rahi`, an Apache-2.0 Rust chassis whose seven responsibilities are
identity through a co-deployed rauthy, replicated state through in-process
hiqlite, a hash-chained decision ledger, a deny-by-default capability
kernel, an axum edge with probes, metrics, and streaming, single-container
packaging, and the operational verbs.

Spec 090 currently founds `hqgit-server` with its own configuration,
router, authentication, telemetry, health endpoints, and shutdown, and 061
brings an OIDC client. Every one of those is a rahi responsibility. Left
alone, the two implementations diverge, and the divergence is invisible
until a security fix lands in one of them.

The second reason for this spec is vocabulary. rahi's decision chain is
called a ledger by its own corpus, and hqgit's central object is also called
a ledger. In a hosted deployment both are present and they are entirely
different things. One word, two meanings, in one process is a defect that
gets written into code and never comes out.

## 2. What this spec settles

- **B-1 (waves 1 to 5 are chassis-free).** `hqgit-types`, `hqgit-ledger`,
  `hqgit-objects`, the domain crates, `hqgit-trust`, `hqgit-policy`, and
  `hqgit-cli` take no dependency on any rahi crate, on hiqlite, or on
  rauthy. The local product must work on a laptop with no server, no
  database, and no network, which is thesis §6 wave 1 and the reason the
  mirror-first strategy is credible. This is frozen: a rahi dependency
  appearing below wave 6 is a defect, not a design choice.
- **B-2 (the wave 6 server is a Cell).** `hqgit-server` implements rahi's
  `Cell` trait: a manifest, migrations, routes, operator routes, and a
  one-line `main` that hands control to rahi's runner. It composes
  `rahi-edge` for the HTTP frame, `rahi-idp` for browser sessions and for
  bearer-token authorization of non-browser clients, `rahi-kernel` for the
  declared capability ceiling, `rahi-store` for operational state, and
  `rahi-ops` for the verbs and packaging. Spec 090's `config.rs`,
  `auth.rs`, `telemetry.rs`, `health.rs`, and its shutdown handling shrink
  to adapters over the chassis, and its `establishes` list is reduced
  accordingly when it is built.
- **B-3 (the transport question is open and named).** rahi's edge is axum
  over HTTP; 090 currently multiplexes HTTP/1.1 and gRPC on one port with
  tonic. The preferred resolution is the Connect protocol over plain HTTP,
  which axum serves natively and which 093 already names, so no
  multiplexing is required and rahi is unchanged. The fallback is a spec
  in rahi that mounts a tonic service into its router. This must be
  resolved before 090 is implemented; whichever is chosen is recorded as a
  D-n entry in 090 and, if the fallback is taken, as a spec in rahi.
- **B-4 (the evidence DAG never moves into the chassis store).** hqgit's
  ledger is content-addressed, hash-linked, per repository, and portable
  by construction. rahi's store is a replicated SQLite group for
  operational state. The server may keep session state, the repository
  registry, quarantine queues, and job state in the chassis store; it puts
  no ledger entry, no object, and no fact there. Frozen.
- **B-5 (identity: two layers, one binding).** hqgit's durable identity
  stays the keypair whose rotation history is a sequence of signed facts
  (060), and it remains authoritative for every signature and every
  attestation. rauthy's `sub` is an authentication subject, not an
  identity: it binds to an `IdentityId` through 061's
  `identity.binding_added` fact, which is exactly the shape 061 already
  specifies with Rauthy named as the self-hosted reference. At the hosted
  edge, therefore, a request is authenticated by the chassis and authorized
  against an hqgit identity the ledger already knows. The CLI keeps its own
  OIDC client for the device authorization grant, because the CLI is
  chassis-free by B-1.
- **B-6 (agents stay hqgit's).** `Principal::Agent` (010 B-6) and the
  delegation chain (100, 101) are hqgit's and are not replaced by anything
  in the chassis. An agent acting through the hosted edge presents a
  chassis-issued bearer token whose subject binds to the agent's
  `IdentityId` by B-5, and its authority within a repository comes from the
  delegation chain, never from the token's scopes alone. The token says who
  is calling; the chain says what they may do.
- **B-7 (vocabulary).** In this repository, *ledger* means the per-repository
  evidence DAG of spec 017 and nothing else. rahi's hash-linked record of
  governed operational choices is called *the chassis decision chain*, in
  prose, in code, and in configuration. The server emits operational
  decisions (a denied capability, an operator action, a quarantine
  admission) to the chassis decision chain, and repository facts to the
  evidence DAG. A type, module, or document that could be read as either is
  renamed.
- **B-8 (licences).** hqgit is AGPL-3.0 and rahi is Apache-2.0.
  Apache-2.0 into AGPL-3.0 is the sanctioned direction, so hqgit may
  consume rahi and may contribute changes upstream under Apache-2.0. No
  hqgit code moves into rahi without that relicensing being explicit in the
  contributing change.
- **B-9 (memory is aicortex's).** The family's memory product is
  `aicortex`. hqgit builds no memory store, no embedding pipeline, and no
  recall surface. Decisions made inside driven sessions are posted to
  aicortex's machine-intake contract by the orchestrator, not by this
  repository.

## 3. Affected specs

010 (Principal is unchanged, and B-6 records why), 017 and 002 (the
vocabulary of B-7), 060 and 061 (the binding of B-5, which 061 already
anticipates), 090, 091, 093, 094, and 095 (composition per B-2 and B-3),
100 and 101 (B-6). Each carries the change into its own Behavior section
when it is implemented, citing this spec.

## 4. Functional requirements

- **FR-001.** A test in the workspace, once wave 6 exists, asserts that no
  crate below `hqgit-server` names a rahi crate, hiqlite, or rauthy in its
  manifest.
- **FR-002.** A grep test asserts the identifier `ledger` never refers to
  the chassis decision chain in this repository's code or documents, and
  that the chassis decision chain is always named as such.
- **FR-003.** `hqgit-server`'s manifest declares its capability ceiling and
  `hqgit-server` contains no axum `Router::new` outside its `Cell`
  implementation.
- **FR-004.** The transport decision of B-3 is recorded as a D-n entry in
  090 before 090 is flipped to `implementation: in-progress`.

## 5. Acceptance criteria

- **AC-1.** `make spine` passes with this spec in the corpus.
- **AC-2.** Specs 090, 091, 093, 094, and 095 each cite this spec when
  they are implemented, and their `establishes` lists no longer claim the
  chassis responsibilities named in B-2.

## 6. Out of scope

The chassis's own design, which is rahi's corpus. Any change to waves 1
through 5, which this spec deliberately leaves untouched. The hosting
business, which is a separate concern from the boundary drawn here.

## 7. Resolved decisions

- **D-1 (2026-09-03, this spec).** The chassis enters at wave 6 rather
  than at wave 1. Adopting it earlier would make the local CLI depend on a
  server chassis, destroying the property that makes adoption possible: an
  hqgit user with a laptop and a GitHub repository needs nothing else.
- **D-2 (2026-09-03, this spec).** hqgit's cryptographic identity remains
  authoritative rather than being replaced by the IdP subject. Attestations
  must verify offline, years later, by someone who has never contacted this
  deployment's IdP, and an OIDC subject cannot carry that. This corrects an
  earlier suggestion in the family that the agent principal should wrap the
  IdP subject: the binding is the correct relationship, not containment.

## Verification

```verify:cli
make spine
```
