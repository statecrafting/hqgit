---
id: "061-oidc-login"
title: "OIDC login: authorization code with PKCE, device flow, and subject binding"
status: approved
kind: "feature"
domain: "l4-trust"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 4
depends_on:
  - "060-identity-and-key-rotation"
establishes:
  - "crates/hqgit-trust/src/oidc.rs"
  - "crates/hqgit-trust/src/session.rs"
  - "crates/hqgit-trust/tests/oidc.rs"
  - "crates/hqgit-trust/testdata/oidc/"
extends:
  - { spec: "060-identity-and-key-rotation", unit: "crates/hqgit-trust/src/lib.rs", nature: additive }
  - { spec: "060-identity-and-key-rotation", unit: "crates/hqgit-trust/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Login is OIDC; identity is a keypair (060). This spec adds the OIDC
  client (discovery, authorization code with PKCE, the device authorization
  grant for the CLI) with an injected HTTP seam so every flow is testable
  against a mock issuer, and the binding that ties an OIDC subject to a
  ledger identity: an identity.binding_added fact signed by the identity's
  active key, so a login proves control of a subject the issuer vouches for
  and the fact proves control of a key the ledger already knows. Workforce
  federation is a per-repository allow-list of issuers, with Rauthy as the
  self-hosted reference. No password is handled anywhere in the crate.
---

# 061: OIDC login

## 1. Purpose

Thesis §4.5 separates authentication from identity: OIDC (Rauthy as the
self-hosted answer) handles login and workforce federation; the ledger
holds the identity. The two meet at a binding fact. This spec supplies the
client half and the binding so that a human at a browser or a terminal can
prove to a server (090 onward) and to a certificate issuer (063) that a
given OIDC subject controls a given identity. Nothing here decides
authorization; it establishes who is speaking.

## 2. Territory

Two modules added to `crates/hqgit-trust`: `oidc.rs` (issuer configuration,
discovery, the two grants, token validation) and `session.rs` (the binding
facts, `BindingView`, and the in-memory `Session`), plus their tests and
the mock-issuer fixtures under `testdata/oidc/`. Adds the `openidconnect`
crate (pinned) to the workspace dependency table and to the crate manifest,
and re-exports through `lib.rs`.

## 3. Behavior

- **B-1 (issuer configuration).** `IssuerConfig { issuer_url: String,
  client_id: String, client_secret: Option<String>, scopes: Vec<String>,
  allowed_audiences: Vec<String>, extra }` and `FederationConfig { issuers:
  Vec<IssuerConfig> }` read from the repository config (021 `.hq/config.toml`
  table `[trust.oidc]`). A login against an issuer not in the list MUST be
  refused with `Error::Config` before any network call. The spec body
  carries a reference configuration for Rauthy (issuer URL shape, a public
  client for the CLI, a confidential client for the server).
- **B-2 (HTTP seam).** Every network interaction goes through an injected
  `HttpClient` trait (`fn request(&self, req: HttpRequest) ->
  Result<HttpResponse, Error>`); the production implementation is a thin
  wrapper the binary supplies, and tests use a `MockIssuer` replaying the
  fixtures under `testdata/oidc/` (a discovery document, a JWKS with a
  fixture signing key, recorded token responses). No test touches the
  network.
- **B-3 (discovery).** `discover(cfg, http) -> Result<IssuerMetadata>`
  fetches `<issuer>/.well-known/openid-configuration`, requires `issuer` to
  equal `cfg.issuer_url` exactly, requires `code` and
  `urn:ietf:params:oauth:grant-type:device_code` among the grant types
  the config will use, and caches the JWKS by `kid`.
- **B-4 (authorization code with PKCE).** `AuthCodeFlow::start(cfg, meta,
  redirect_uri, entropy: [u8; 32]) -> (AuthorizeUrl, PendingAuth)` builds
  the request with `code_challenge_method=S256`, a `state`, and a `nonce`
  derived from the caller-supplied entropy (the crate reads no randomness
  itself); `AuthCodeFlow::finish(pending, callback_params, http) ->
  Result<OidcSubject>` exchanges the code and validates the id token (B-6).
  `state` mismatch is `Error::Crypto`.
- **B-5 (device authorization grant).** `DeviceFlow::start(cfg, meta, http)
  -> Result<DeviceCode { user_code, verification_uri, interval, expires_in
  }>`; `DeviceFlow::poll(pending, http) -> Result<PollState>` with
  `PollState` a closed enum `Pending | SlowDown | Complete(OidcSubject) |
  Denied | Expired`. The caller owns the sleep; the crate never sleeps or
  reads a clock. This is the CLI's flow (032's config and 093's remote
  login consume it).
- **B-6 (token validation).** An id token is accepted only when: the JWS
  signature verifies against a JWKS key with the token's `kid`; `iss`
  equals the configured issuer; `aud` contains the client id or an allowed
  audience; `exp` is later than the caller-supplied `now: u64` seconds
  (injected, never read); `nonce` matches when a nonce was sent; `sub` is
  non-empty. The result is `OidcSubject { issuer: String, sub: String,
  email: Option<String>, claims_hash: Hash }` where `claims_hash` is the
  hash of the canonical encoding of the verified claim set, never the raw
  token. Access and refresh tokens are returned to the caller as opaque
  strings and never written to the ledger or to disk by this crate.
- **B-7 (binding facts).** Two fact kinds registered by `register_trust`
  (060): `identity.binding_added` with body `{ identity: IdentityId,
  issuer: String, sub: String, claims_hash: Hash, bound_at: Hlc, extra }`
  and `identity.binding_removed` with body `{ identity, issuer, sub,
  removed_at: Hlc, extra }`. Both entries MUST be signed by the identity's
  active key at the fact's `Hlc` (060 B-5); a binding signed by any other
  key is a `ChainDefect` and never applied. A binding fact is produced only
  by `bind(subject: &OidcSubject, identity, signer, hlc)` after a completed
  flow, so the fact exists only when both proofs were made in one session.
- **B-8 (`BindingView`).** A `DerivedState` fold answering `identity_for(
  issuer, sub) -> Option<IdentityId>` (the most recent unremoved binding)
  and `bindings_of(identity) -> Vec<Binding>`. One subject binds to at most
  one identity at a time; binding an already-bound subject to a second
  identity is recorded as a defect until the first is removed. An identity
  MAY hold bindings from several issuers (workforce federation).
- **B-9 (`Session`).** `Session { subject: OidcSubject, identity:
  IdentityId, established_at: Hlc, expires_at: u64 }` is an in-memory value
  the server (090) and the certificate issuer (063) consume; it is never
  persisted by this crate and never becomes a fact.
- **B-10 (no passwords).** No type in this crate holds a password, and no
  flow other than B-4 and B-5 exists. Resource-owner password credentials
  are refused at the type level (there is no constructor).

## 4. Functional requirements

- **FR-001.** All flow state machines are pure over `(config, metadata,
  injected entropy, injected now, responses)`; the `HttpClient` seam is the
  only I/O boundary.
- **FR-002.** Fixtures under `testdata/oidc/`: `discovery.json`,
  `jwks.json`, the fixture signing key, and recorded responses for a
  successful code exchange, a successful device flow, a `slow_down`, an
  `authorization_pending`, an `access_denied`, and an expired token.
- **FR-003.** Tests cover: discovery issuer mismatch refused; PKCE
  challenge equals `S256(verifier)`; `state` mismatch; nonce mismatch; a
  token signed by an unknown `kid`; `aud` mismatch; `exp` in the past;
  device flow state transitions including `SlowDown` back-off signal;
  binding signed by a rotated-out key recorded as a defect; a subject
  bound twice; federation refusal for an unlisted issuer.
- **FR-004.** `claims_hash` is stable across two validations of the same
  token (canonical claim ordering) and differs when any claim differs.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-trust --locked oidc` passes against the
  mock issuer with no network access (the test binary is run with
  networking disabled in CI where the runner supports it).
- **AC-2.** A fixture repository gains an `identity.binding_added` fact
  through `bind`, and `BindingView::identity_for` returns the identity for
  the fixture subject.

## 6. Out of scope

Serving OIDC (hqgit is a relying party, never an issuer); browser and
server session cookies (093, 095); the certificate issuance that consumes
a session (063); agent credentials, which are never OIDC-derived (100).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-trust --locked oidc
```
