---
id: "093-connect-api"
title: "The typed API: gRPC and Connect JSON services for changes, reviews, attestations, policy, repos; the CLI remote client"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 6
depends_on:
  - "090-server-skeleton"
  - "026-review-threads"
  - "027-attestation-primitive"
  - "067-policy-evaluation-attestation"
  - "032-cli-skeleton"
  - "081-change-and-review-views"
establishes:
  - "proto/hqgit/v1/common.proto"
  - "proto/hqgit/v1/changes.proto"
  - "proto/hqgit/v1/reviews.proto"
  - "proto/hqgit/v1/attestations.proto"
  - "proto/hqgit/v1/policy.proto"
  - "proto/hqgit/v1/repos.proto"
  - "crates/hqgit-server/build.rs"
  - "crates/hqgit-server/src/api/mod.rs"
  - "crates/hqgit-server/src/api/connect.rs"
  - "crates/hqgit-server/src/api/read_model.rs"
  - "crates/hqgit-server/src/api/changes.rs"
  - "crates/hqgit-server/src/api/reviews.rs"
  - "crates/hqgit-server/src/api/attestations.rs"
  - "crates/hqgit-server/src/api/policy.rs"
  - "crates/hqgit-server/src/api/repos.rs"
  - "crates/hqgit-server/tests/api.rs"
  - "crates/hqgit-cli/build.rs"
  - "crates/hqgit-cli/src/client.rs"
  - "crates/hqgit-cli/src/cmd_remote.rs"
  - "crates/hqgit-cli/tests/remote.rs"
extends:
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/lib.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/app.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/Cargo.toml", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
  # The remotes table joins the CLI config; tonic and prost join its manifest.
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/config.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/Cargo.toml", nature: additive }
  # prost, tonic-build, protox, pbjson, pbjson-build, and tower-http cors, pinned.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The one typed API of the edge (thesis §2, L7): five services defined in
  protobuf, served as gRPC and as Connect-compatible JSON over plain HTTP
  on the same listener so browsers and CLIs use one contract. Every write
  is a fact append through the spec 021 path and the control plane (091),
  never a table update; approvals and attestations arrive already signed
  by their issuer and are verified before append; server-mediated writes
  record who they were made for. Reads come from the spec 081 projections
  when present and from a domain fold otherwise, through one ReadModel
  seam, and every response says which ledger entry it is projected as of.
  Pagination is by total-order cursor. The CLI gains a generated client
  and hq remote so every existing verb can target a hosted repository.
---

# 093: The Connect API

## 1. Purpose

Thesis §4.7: the edge is interchangeable clients over the same signed
history, which is only true if there is one contract those clients share.
This spec is that contract. It refuses two shortcuts that would recreate
the incumbent shape (thesis §1): an API that updates rows (every write
here appends a fact, constitution VI), and an API that answers from an
index as if it were truth (every read carries `as_of`, 080 B-5). The CLI
client exists so that the offline verbs of wave 1 and a hosted repository
are the same verbs with a `--remote` flag (constitution XIII).

## 2. Territory

The protobuf package `hqgit.v1` under `proto/`; in `hqgit-server`,
`build.rs` (tonic-build plus pbjson-build over `proto/`), the `api` module
(`mod.rs` mounts, `connect.rs` the JSON transport, `read_model.rs` the
seam, one file per service), and `tests/api.rs`; in `hqgit-cli`,
`build.rs` (the client side of the same protos, generated independently
because the CLI never depends on the server), `client.rs`, `cmd_remote.rs`,
and `tests/remote.rs`. Additively: the server's `app.rs`, `lib.rs`, and
manifest (090); the CLI's `main.rs`, `cli.rs`, `config.rs`, and manifest
(032). The review UI that consumes the JSON form is 095.

## 3. Behavior

- **B-1 (common shapes).** `common.proto`: `Hash { string hex }`, `Cid {
  string codec; string hex }`, `Hlc { uint64 wall_ms; uint32 logical;
  string node }`, `Principal { string kind; string hex }`, `AsOf { Hash
  entry; uint64 ordinal }`, `Page { string cursor; uint32 limit }` (limit
  1..=200, default 50), `Namespace { Hash id; string name }`, and
  `ErrorDetail { string kind; string message }`. Hashes and cids render
  exactly as 032 B-3 renders them.
- **B-2 (services).** `Changes { ListChanges, GetChange, GetRevisionDiff,
  OpenChange, SubmitRevision, RetitleChange, AbandonChange }`; `Reviews {
  ListThreads, OpenThread, PostComment, ResolveThread, ReopenThread,
  Approve }`; `Attestations { ListAttestations, GetAttestation, Issue }`;
  `Policy { Evaluate, ListVerdicts, Replay }`; `Repos { ListRepos,
  CreateRepo, GetRepo, ListEntries, Append, PutObjects, GetObject }`. All
  RPCs are unary; every list takes `Page` and returns `next_cursor` plus
  `AsOf`; every read returns `AsOf`. `ListThreads` returns each thread's
  position for the requested revision (081 B-2 resolutions) and, with
  `include_bodies`, comment text resolved from the object store or
  `erased = true`. `GetRevisionDiff(revision, against: PREVIOUS | BASE)`
  returns per-file unified hunks computed from the two trees.
- **B-3 (two transports, one listener).** Every RPC is reachable as gRPC
  and as Connect unary JSON: `POST /hqgit.v1.<Service>/<Method>` with
  `Content-Type: application/json`, body the proto3 JSON of the request
  (pbjson-generated serde, never hand-written), errors as `{ "code":
  "<connect code>", "message", "details": [ErrorDetail] }` with Connect's
  HTTP status mapping, CORS from `[api] cors_origins`. `connect.rs` is one
  generic handler that deserializes, calls the same service object tonic
  calls, and serializes, so the two transports cannot drift.
- **B-4 (writes are appends).** Every write RPC ends in exactly one call:
  `RepoHandle::append(fact, target)` which builds the entry through 021
  `append_fact` and commits through the 091 `ControlPlane` (`propose`),
  with `target` from the 090 `NamespaceRouter`. Server-mediated writes
  (`OpenChange`, `SubmitRevision`, `RetitleChange`, `AbandonChange`,
  `OpenThread`, `PostComment`, `ResolveThread`, `ReopenThread`) are signed
  by the server identity with `extra["on_behalf_of"]` the caller and
  `extra["via"] = "connect-api"` (090 B-4). `Approve`, `Attestations.Issue`,
  and `Policy.Evaluate`'s result are attestations, and an attestation is
  signed by its issuer or it is nothing (027, constitution XI): `Approve`
  and `Issue` take `bytes attestation` (027 canonical bytes) plus the
  claim object, verify the signature through the repository's resolver
  before append, and refuse a server-signed substitute; `Evaluate` runs
  067 on the server and the resulting `hqgit/policy-eval/v1` attestation
  is issued by the server's Service principal. `Repos.Append` accepts a
  client-built entry (`bytes entry`, `bytes payload`) and runs the 017 B-6
  checks; it is how the CLI submits entries it signed locally. There is
  no RPC that updates any row anywhere.
- **B-5 (reads through one seam).** `read_model.rs`: `trait ReadModel {
  fn list_changes(..) -> Result<AsOf<Page<ChangeRow>>, Error>; fn change_
  detail(..); fn threads_for(..); fn attestations_for(..); fn verdicts_
  for(..); fn stack_of(..); }` with `ProjectedReadModel` over the 081
  views when their checkpoint exists for the repository and `FoldReadModel`
  over the 024, 026, 027, and 050 folds otherwise; the choice is per
  request and logged. A cursor is the base64 of 081's `PageCursor`; a
  cursor from another query is `invalid_argument`. Rows are never
  re-sorted after the read model orders them.
- **B-6 (auth).** The 090 `Caller` reaches every handler; reads are open
  to `Anonymous` when `anonymous_read` is set, writes require a principal
  (`unauthenticated` otherwise), and an `Agent` principal on `Approve` is
  `permission_denied` (constitution XII; 102 refines). Objects: `PutObjects`
  verifies each object's hash on receipt (013 B-4) and caps the batch at
  `[api] max_objects_per_call` (default 1000) and `max_body_bytes` (090).
- **B-7 (errors).** `Error` maps to `invalid_argument` (Validation,
  Crypto), `not_found`, `failed_precondition` (Stale, Drift),
  `permission_denied` (Policy), `internal` (Io, Parse, Schema, Config),
  each with `ErrorDetail.kind` the lowercase variant; the client maps back
  so 010 B-9's exit codes hold end to end.
- **B-8 (CLI remote).** `hq remote add <name> <url> --namespace <hex>`,
  `hq remote remove | list | status <name>` store `[remotes.<name>] url,
  namespace` in the user config (032 B-4) and read the token from
  `HQ_TOKEN` or `[remotes.<name>].token_env`. A global `--remote <name>`
  makes `status`, `log`, `change list|show|new|submit`, `review show|
  comment|reply|resolve|approve`, and `attest list|show|<issue>` target the
  remote: reads through the API; `submit` uploads the snapshot's objects
  with `PutObjects` then calls `SubmitRevision`; `approve` and `attest`
  sign locally (033 B-6, 034 B-1) and submit through `Approve` and
  `Issue`. `client.rs` is tonic over HTTP/2 with rustls (`--insecure` for
  `http://` in tests). `--json` output is byte-identical to the local
  verb's for the same ledger (032 FR-004).
- **B-9 (no ambient input).** No handler formats the wall clock; every
  timestamp in a response is a ledger `Hlc` or an `AsOf`.

## 4. Functional requirements

- **FR-001.** `tests/api.rs` runs against 090's `TestServer` with
  `LocalControlPlane` (091) through the generated tonic client and a
  plain HTTP client for Connect JSON, covering: `CreateRepo` then
  `GetRepo` heads; `OpenChange`, `PutObjects`, `SubmitRevision`, and
  `GetChange` as of the new entry; `ListChanges` pagination stable across
  an insert between two pages; `PostComment` and `ListThreads` with
  bodies and an erased body; `Approve` with a locally signed attestation
  accepted and with a tampered signature `invalid_argument`; `Issue` of
  an unknown predicate carried verbatim; `Evaluate` on a fixture policy
  and `ListVerdicts`, then `Replay` reporting `Match`; every `Error`
  variant's code through a fixture handler; anonymous write
  `unauthenticated`; an Agent `Approve` `permission_denied`; the same
  `ListChanges` page from `FoldReadModel` and `ProjectedReadModel`
  compared equal; Connect JSON request and gRPC request for one method
  yielding the same response body.
- **FR-002.** `tests/remote.rs` drives the `hq` binary with `assert_cmd`
  against the same server: `remote add`, `change list --remote`, `review
  comment --remote`, `review approve --remote`, and `status --remote`.
- **FR-003.** Both `build.rs` files compile only `proto/hqgit/v1/*.proto`
  through `protox` (no `protoc` on the host) and fail the build on a
  proto change that removes or renumbers a field (a golden descriptor set
  under each crate's `tests/`).
- **FR-004.** `cargo tree -p hqgit-cli` shows no `hqgit-server` and vice
  versa.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-server --locked api` and `cargo test -p
  hqgit-cli --locked --test remote` pass.
- **AC-2.** `curl -X POST http://<addr>/hqgit.v1.Repos/ListRepos -H
  'content-type: application/json' -d '{}'` returns a JSON page with
  `asOf`.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The browser client (095), OIDC sessions and device-code login (061),
Biscuit-authenticated agents (102), capability-checked routing and
quarantine reads (094), server-side streaming, and any RPC over issues
(a later feature spec adds `issues.proto` beside these).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-server --locked api
cargo test -p hqgit-cli --locked --test remote
```
