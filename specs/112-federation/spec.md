---
id: "112-federation"
title: "Federation: peer registries as facts, the server sync driver, holds for unpromoted peers, and hq sync"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 8
depends_on:
  - "111-quic-transport"
  - "094-quarantine-and-promotion"
  - "032-cli-skeleton"
establishes:
  - "crates/hqgit-server/src/federation.rs"
  - "crates/hqgit-server/src/peers.rs"
  - "crates/hqgit-cli/src/cmd_sync.rs"
  - "crates/hqgit-server/tests/federation.rs"
  - "crates/hqgit-cli/tests/sync.rs"
extends:
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/lib.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/app.rs", nature: additive }
  # The [federation] config table and hqgit-sync as a server dependency.
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/config.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/Cargo.toml", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
  # hqgit-sync joins the CLI's dependencies.
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/Cargo.toml", nature: additive }
  # federation.peer_added, federation.peer_removed, federation.received.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  Thesis §6 step 8: hosts replicate signed history, not authority. A
  repository's peers are facts (identity, transport key, endpoints,
  namespaces, and the capability attestation that says what the peer may
  do here), folded into a registry that implements the transport's
  Authorizer with spec 094's capability checks. The server runs a per
  repository driver over 111 that pulls from every peer and pushes to the
  peers it is configured to push to; entries arriving from a peer without
  the promote capability go into a per-peer hold that no fold reads until
  a promotion fact (094) admits them, so a foreign host can contribute
  history but never decide what this host treats as main (constitution
  XV). The CLI is a peer like any other: hq sync, hq push, and hq pull
  speak the same protocol against a server or another laptop.
---

# 112: Federation

## 1. Purpose

The thesis's last risk (002 §8): decentralized state raises discovery
cost, which is why centralization keeps winning. hqgit answers with a
central index that has no lock-in (wave 6) and, here, replication of the
same signed history between hosts, so leaving a host is a sync rather
than a migration (constitution XIV). What is deliberately not replicated
is authority: which peers a host trusts, and which foreign entries it
admits to `main`, are local decisions recorded as local facts, verifiable
by anyone and binding on no one else.

## 2. Territory

`peers.rs` (the peer facts, `PeerRegistry`, `CapabilityAuthorizer`) and
`federation.rs` (the hold, admission, the driver, the status route) in
`crates/hqgit-server`; `cmd_sync.rs` in `crates/hqgit-cli`; and the two
test files. Additively: the server's `lib.rs`, `app.rs` (QUIC listener
and the status route), `config.rs` (`[federation]`), and manifest; the
CLI's dispatch, clap tree, and manifest; three fact kinds in spec 023's
vocabulary. The transport and session are 111; the capability predicate
and the promotion fact are 094.

## 3. Behavior

- **B-1 (peer facts).** `federation.peer_added { peer: Principal, key:
  PublicKey, endpoints: Vec<String>, relay: Option<String>, namespaces:
  Vec<Hash>, mode: PeerMode, capability: Option<AttestationId> }` with
  `PeerMode` a closed enum `Pull | Push | Both`; `federation.peer_removed
  { peer: Principal }`; `federation.received { peer: Principal, namespace:
  Hash, session: Hash, entries: Vec<EntryHash> }` (at most 4,096 hashes
  per fact, chunked). Endpoints are `host:port` strings; `key` is the
  peer's transport key (111 B-1), so a peer whose identity facts have not
  replicated yet is still pinned (111 B-2 `Pinned`). Peer facts are
  written to the repository's `main` namespace by the host's own Service
  identity (090); `federation.received` is written to the quarantine
  namespace (021 B-6).
- **B-2 (registry and rights).** `PeerRegistry` is a `DerivedState` (019)
  folding B-1 into `BTreeMap<Principal, Peer>` (last `peer_added` in total
  order wins; `peer_removed` deletes). Rights come from the referenced
  capability attestation, verified through 094's `capability.rs` over a
  064 verified set: `read` (pull `main`), `read-quarantine` (pull the
  quarantine namespace and this host's holds), `write` (push into a
  hold), `promote` (push admitted directly). `CapabilityAuthorizer {
  registry, capabilities }` implements 111 B-5's `Authorizer`: `may_read
  (peer, ns)` is `read` for `main` and `read-quarantine` for quarantine;
  `may_write` is `write` or `promote`; `knows_key` is membership of the
  key in the registry. A peer with no capability attestation has no
  rights at all; the registry entry alone grants nothing.
- **B-3 (hold).** `Hold` is a per-peer `EntryStore` (021 B-2, redb) at
  `<data>/repos/<namespace-hex>/.hq/hold/<peer-hex>.redb`. An incoming
  session from a peer whose rights include `write` but not `promote`
  ingests into the hold through 110 B-7's checks with the hold as the
  store (parents may resolve from either the ledger or the hold); on
  `sync.end { Ok }` the host appends `federation.received` naming the
  session and the held hashes. A peer with `promote` ingests into the
  ledger directly. No fold, projection, or API read ever opens a hold
  except `read-quarantine` reads and the promotion path.
- **B-4 (admission).** `promote_hold(repo, peer, session: Hash, verified)
  -> Result<Admitted, Error>` is what 094's promotion path calls when a
  `namespace.promoted` fact whose subject is a `federation.received`
  entry hash is appended by a principal holding `promote`: every held
  entry named by that fact is ingested into the ledger in `(hlc, hash)`
  order, payloads fetched from the hold's object store, and the hold
  entries deleted; `Admitted { entries: u32, payloads_missing: u32 }`.
  A `namespace.promoted` without the capability is refused by 094 before
  this function runs. Nothing is retagged: the entries keep their
  issuers, signatures, and namespace markers, and 020's tombstones apply
  to them as to any other.
- **B-5 (outgoing sessions).** `FederationDriver::new(repos: &RepoRegistry
  (090), endpoint: Endpoint (111), config)` runs one task per repository:
  every `interval_s` (default 60) it folds the registry and, for each
  peer in `Pull` or `Both`, opens a session with `SyncRequest { pull:
  true, push: mode == Both, namespaces: peer.namespaces }`; for `Push`
  peers, `pull: false, push: true`. The remote host applies its own
  authorizer to what we push (B-2 on its side). Failures back off per
  peer (base 5 s, factor 2, cap 900 s) and are recorded on
  `PeerStatus { last_ok: Option<Hlc>, last_error: Option<String>,
  consecutive_failures: u32 }`; the driver never busy-loops.
- **B-6 (incoming sessions).** `app.rs` binds the QUIC endpoint from
  `[federation] bind = "0.0.0.0:4433"` (`enabled = false` skips all of
  this) with the host's Service identity and accepts connections into
  `Session::run` (111 B-5) with the `CapabilityAuthorizer` of the
  repository the hello names; the repository is located by its namespace
  id through 090's `RepoRegistry`; an unknown namespace is
  `Error::NotFound` after the handshake and never before (no existence
  oracle for unauthenticated keys). `GET /federation/status` returns
  `{ "enabled", "peers": [{ "peer", "mode", "rights", "status" }] }`
  per repository for the operator; it is read-only and served from the
  registry fold.
- **B-7 (CLI verbs).** `hq peer add <name> --key <hex> --addr <host:port>
  [--relay <url>] [--namespace <name>]... [--mode pull|push|both]`
  records `[[sync.peers]]` in `.hq/config.toml`; `hq peer list` and
  `hq peer remove <name>`. `hq sync [<name>] [--namespace <name>]
  [--no-payloads]` runs a `Both` session against the named peer or every
  configured peer; `hq pull [<name>]` and `hq push [<name>]` are `pull`
  only and `push` only. The CLI's local authorizer is 111's `OwnerOnly`
  extended with the configured peers holding `promote` for pulls: a
  laptop trusts the peers its owner configured, and its ingest goes
  straight to the ledger. The CLI's identity key (021 B-1) is the
  transport key. Output in JSON mode is `{ "peer", "namespaces": [{
  "namespace", "received", "sent", "payloads_missing", "rounds" }],
  "resumed": bool }` per peer; exit `0` when every session completed,
  `1` on a policy or identity refusal, `3` on transport failure.
- **B-8 (no ambient input on hashed paths).** The driver's interval and
  backoff use `tokio` timers outside every hashing path; `now` for 111
  B-2 comes from each repository's `HlcGenerator` (018).

## 4. Functional requirements

- **FR-001.** `tests/federation.rs` boots two servers on ephemeral ports,
  each hosting one repository replicated from one genesis, registers each
  as the other's peer with `Both` and `promote`, appends distinct facts on
  each, runs one driver tick on both, and asserts identical total orders
  (018) and object stores; it then starts an `hq` process (assert_cmd)
  with the first server as a `pull` peer and asserts the CLI ledger
  matches.
- **FR-002.** Tests cover: a peer without a capability attestation is
  refused with `Error::Policy` and nothing is ingested; a peer with
  `write` only lands its entries in the hold, `main`'s fold (024) does
  not see them, `federation.received` names them, and `promote_hold`
  after a `namespace.promoted` admits them with the fold updated; a peer
  with `read` only never receives our `WantEntries`; a removed peer is
  refused on the next tick; backoff schedule after two failures; the
  status route reflects the registry.
- **FR-003.** `tests/sync.rs` drives `hq peer add`, `hq sync --json`, `hq
  pull`, and `hq push` against a server started in-process by the test,
  asserting the JSON shape, the exit codes of B-7, and that a second
  `hq sync` reports `received = 0` and `resumed = true`.
- **FR-004.** Neither crate gains a dependency on the other; `hqgit-sync`
  is the shared crate (constitution XIII).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-server --locked federation` passes.
- **AC-2.** `cargo test -p hqgit-cli --locked sync` passes.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Peer discovery through the ecosystem index (084 lists repositories; a
later spec joins them to peers); promotion policy beyond 094's
capability check; replicating the action cache (071) between hosts;
cross-host merge-queue coordination (076 runs on one host's 091 leader);
mirroring to GitHub (040 to 042); web UI for peers (095).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-server --locked federation
cargo test -p hqgit-cli --locked sync
```
