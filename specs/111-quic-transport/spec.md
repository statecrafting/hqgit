---
id: "111-quic-transport"
title: "QUIC transport: identity-bound endpoints, the sync session, and the remote object source"
status: approved
kind: "feature"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 8
depends_on:
  - "110-set-reconciliation"
  - "060-identity-and-key-rotation"
establishes:
  - "crates/hqgit-sync/src/transport.rs"
  - "crates/hqgit-sync/src/session.rs"
  - "crates/hqgit-sync/src/object_source.rs"
  - "crates/hqgit-sync/tests/transport.rs"
extends:
  - { spec: "110-set-reconciliation", unit: "crates/hqgit-sync/src/lib.rs", nature: additive }
  # iroh, quinn, tokio, and hqgit-trust join the crate's dependencies.
  - { spec: "110-set-reconciliation", unit: "crates/hqgit-sync/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The wire under reconciliation: QUIC through iroh and quinn (thesis
  §4.2), where the peer's TLS key is its hqgit identity key, so a
  handshake is an identity proof checked against the rotation chain (060)
  and nothing else names a peer. One ALPN, one framed message stream per
  session, and one stream per object fetch. The session runs heads
  exchange, reconciliation (110) per namespace, entry ingest, and payload
  fetch through a RemoteObjectSource that implements spec 015's
  ObjectSource, so every byte from a peer arrives with a range proof and
  a tampered slice is refused before it exists locally. Reads are gated
  per namespace by an Authorizer seam and quarantine is never pulled
  unless asked for; an interrupted session leaves a valid replica and the
  next one resumes from the last completed watermark.
---

# 111: QUIC transport

## 1. Purpose

Spec 110 made replication a pure state machine over messages; this spec
gives it a network. Two properties are load-bearing. First, identity: a
peer is the key it proves possession of in the TLS handshake, and that
key resolves through the identity fold (060 B-5), so a revoked key cannot
sync even if the operator's peer list still names it (constitution XI).
Second, verification: content flows only through 015's proof-carrying
seam, so the transport can serve an untrusted client and accept from an
untrusted server without either trusting the other (thesis §4.1, D2).

## 2. Territory

`transport.rs` (endpoint, connection, framing, `QuicChannel`),
`session.rs` (the handshake, phases, authorization seam, resume state),
`object_source.rs` (`RemoteObjectSource` and its serving half) in
`crates/hqgit-sync`, plus `tests/transport.rs`. Additively: the crate's
`lib.rs` and manifest (`iroh`, `quinn`, `tokio`, `hqgit-trust`), and the
workspace dependency table. The peer registry, capability attestations,
scheduling, and the CLI verbs are spec 112; the resume file lives under
`.hq/sync.redb`, an additive entry in 021 B-1's layout.

## 3. Behavior

- **B-1 (endpoint and identity).** `Endpoint::bind(identity:
  &LocalIdentity, config: TransportConfig) -> Result<Endpoint, Error>`
  builds an `iroh::Endpoint` whose secret key is the identity's ed25519
  seed (021 B-4), so the TLS certificate presented is a raw public key
  (RFC 7250) equal to the identity's public key and `iroh`'s node id is
  that key. The ALPN is exactly `b"hqgit/sync/1"`; a connection
  negotiating any other ALPN is refused. `TransportConfig { bind:
  SocketAddr, relay: Option<String>, idle_timeout_s: u32 (default 30),
  max_frame: u32 (default 16 MiB), max_object_streams: u8 (default 8) }`.
  `PeerAddr { key: PublicKey, addrs: Vec<SocketAddr>, relay:
  Option<String> }` names a peer; `Endpoint::connect(&PeerAddr) ->
  Result<Connection, Error>` fails with `Error::Crypto` when the
  handshake's key differs from `PeerAddr.key`; `Endpoint::accept() ->
  Result<Connection, Error>`. `Connection::peer_key() -> PublicKey`.
- **B-2 (peer verification).** `verify_peer(key: &PublicKey, view:
  &IdentityView, now: &Hlc, authorizer: &dyn Authorizer) ->
  Result<PeerIdentity, Error>`: `key_valid_at(KeyId::of(key), now)` (060
  B-5) `Valid` yields `PeerIdentity::Known(identity)`; `Unknown` yields
  `PeerIdentity::Pinned(KeyId)` only when `authorizer.knows_key(key)`
  (an operator-pinned peer whose identity facts have not replicated
  yet), else `Error::Crypto("unknown peer key")`; `Rotated`, `Revoked`,
  and `NotYet` are `Error::Crypto` naming the state. `now` is the
  caller's `HlcGenerator` value (018); this crate reads no clock.
- **B-3 (framing and channel).** The first bidirectional stream a
  connection opens is the session stream; every message is a `u32`
  big-endian length followed by the canonical bytes of a 110 `Message` or
  a session message of B-4; a frame above `max_frame` or that fails
  canonical decode is `Error::Validation` and closes the connection with
  QUIC error code `0x01`. `QuicChannel` wraps the session stream and
  implements 110's `Channel`. Object fetches (B-6) each open their own
  bidirectional stream, at most `max_object_streams` in flight.
- **B-4 (session messages).** Kinds `sync.hello { v: 1, namespaces:
  Vec<Hash>, heads: BTreeMap<Hash, Vec<EntryHash>>, resume:
  Option<Bound> }`, `sync.begin { namespace: Hash, range: Range }`,
  `sync.end { namespace: Hash, outcome: Outcome }`, and `sync.bye {
  stats: SessionStats }`. `namespaces` lists the requested namespace ids;
  the default request is `[main]` and the quarantine namespace (021 B-6)
  is included only when the caller asks for it explicitly. `heads` are
  the sender's 017 heads per namespace; equal heads on both sides skip
  reconciliation for that namespace.
- **B-5 (`Authorizer` and phases).** `trait Authorizer { fn may_read(&self,
  peer: &PeerIdentity, namespace: &Hash) -> bool; fn may_write(&self,
  peer: &PeerIdentity, namespace: &Hash) -> bool; fn knows_key(&self,
  key: &PublicKey) -> bool; }` with `OwnerOnly` (the local identity and
  nothing else) and `StaticAuthorizer(BTreeMap<KeyId, BTreeSet<(Hash,
  Right)>>)` with `Right::{Read, Write}` shipped here; 112 supplies the
  capability-backed one. `Session::run(conn, repo, view, authorizer,
  now, request: SyncRequest) -> Result<SessionStats, Error>` proceeds:
  hello exchange (a namespace the peer may not read is answered with
  `sync.end { outcome: Denied }` and `Error::Policy("read denied for
  namespace <hex>")` on the requesting side; a peer with `may_write`
  false is served read-only, meaning its `RangeItems` are consumed for
  fingerprinting but no `WantEntries` is sent for its items); then per
  namespace `sync.begin`, 110 `run` over `QuicChannel` with an
  `EntryIndex` restricted to entries whose `extra["namespace"]` is that
  namespace (absent meaning `main`), ingest through `ingest_entry` (110
  B-7) with the 060 `RotationAwareResolver`, `sync.end`; then payload
  fetch (110 B-8) through B-6; then `sync.bye`. `SyncRequest {
  namespaces: Vec<Hash>, pull: bool, push: bool, fetch_payloads: bool }`.
- **B-6 (`RemoteObjectSource`).** Object stream messages: `obj.slice {
  cid, range }`, `obj.whole { cid }`, `obj.size { cid }`, and replies
  `obj.slice_ok { proof: SliceProof, bytes }`, `obj.whole_ok { bytes }`,
  `obj.size_ok { len }`, `obj.absent`. `RemoteObjectSource { conn }`
  implements 015 B-4's `ObjectSource`; the serving half answers from
  `LocalSource` over the repository store with proofs from the stored
  outboard (015 B-1). Serving requires `may_read` for at least one
  namespace of the session; objects are not partitioned by namespace
  (content addressing does not know namespaces) and encrypted namespaces
  protect content by ciphertext (020 B-3), not by transport. Every slice
  is verified by 015 `verify_slice` against the requested cid before it
  is returned, so a peer serving altered bytes produces `Error::Crypto`
  naming the chunk group and nothing enters the store.
- **B-7 (resume).** `.hq/sync.redb` holds `peers: (peer KeyId, namespace)
  -> ResumeState { completed_to: Bound, last_heads: Vec<EntryHash> }`,
  written only after `sync.end { Ok }`. A session with a resume state
  first reconciles `[completed_to, MAX)`; if 110's final fingerprint
  check fails for that range the session falls back to the whole space
  once. Because ingest is idempotent and parent-first, an interrupted
  session at any frame leaves a valid ledger with at worst `Missing`
  payloads, and no partial object (015 B-5).
- **B-8 (limits and refusals).** Per connection: one session stream, at
  most `max_object_streams` object streams, idle close after
  `idle_timeout_s`, an `Abort` on any 110 B-5 violation. Every refusal
  maps to one `Error` variant: `Crypto` (identity, tamper), `Policy`
  (authorization), `Validation` (protocol), `Io` (transport). The
  serving side never reveals why beyond the variant name.

## 4. Functional requirements

- **FR-001.** `tests/transport.rs` binds two endpoints on ephemeral
  loopback ports, each over a 021 repository initialized from one
  genesis with its own identity facts, and asserts: a full sync converges
  both ledgers and object stores; a second sync exchanges no entries and
  resumes from `completed_to`; a peer holding only `Read` receives entries
  and sends none; a namespace without `may_read` is `Error::Policy`;
  quarantine is untouched by a default request and synced when
  requested with the right.
- **FR-002.** Tests cover: ALPN mismatch refused; a connection whose
  handshake key differs from `PeerAddr.key`; every `KeyValidity` state
  in `verify_peer`, including `Pinned`; an oversized frame; a serving
  endpoint wrapped to flip one byte in a slice or a proof yielding
  `Error::Crypto` with the store unchanged; an interrupted session
  (connection dropped mid-`Entries`) followed by a successful resume.
- **FR-003.** The `bao`-verified path is the only path from the network
  to the object store; a test enumerates `object_source.rs` for calls to
  `ObjectStore::put` and asserts each is preceded by `fetch_into` or
  `verify_slice`.
- **FR-004.** `iroh` and `quinn` are pinned exact in the workspace table;
  `hqgit-sync` gains `hqgit-trust` and no other workspace crate.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-sync --locked transport` passes.
- **AC-2.** `cargo test -p hqgit-sync --locked` passes in full.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The peer registry, capability attestations as authorization, server
scheduling, and the CLI verbs (112); quarantine admission of foreign
entries (112 over 094); relay operation and NAT traversal policy beyond
what `iroh` provides by configuration; bandwidth shaping; git protocol
compatibility (092).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-sync --locked transport
cargo test -p hqgit-sync --locked
```
