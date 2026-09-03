---
id: "090-server-skeleton"
title: "The hqgit-server binary: one listener for HTTP and gRPC, config, the repo registry, health, shutdown"
status: approved
kind: "kernel"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 6
depends_on:
  - "021-local-repository"
establishes:
  - "crates/hqgit-server/Cargo.toml"
  - "crates/hqgit-server/src/main.rs"
  - "crates/hqgit-server/src/lib.rs"
  - "crates/hqgit-server/src/config.rs"
  - "crates/hqgit-server/src/app.rs"
  - "crates/hqgit-server/src/health.rs"
  - "crates/hqgit-server/src/repos.rs"
  - "crates/hqgit-server/src/auth.rs"
  - "crates/hqgit-server/src/telemetry.rs"
  - "crates/hqgit-server/tests/"
extends:
  # axum, tonic, tonic-health, tokio, tower, tower-http, tracing, and
  # tracing-subscriber join the shared dependency table, pinned.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The hosted edge begins here. This spec founds hqgit-server, the binary
  that serves every later L7 surface (the git endpoint 092, the Connect API
  093, the review UI 095, federation 112) from one listener, and fixes the
  frame those specs hang on: TOML plus environment configuration, one axum
  router that multiplexes HTTP/1.1 and gRPC on a single port, a registry
  that opens spec 021 repositories lazily under a fixed data-directory
  layout, a server identity of kind Service, the caller and namespace
  routing seams every request passes through, health and readiness
  endpoints, structured logs, graceful shutdown, and exit codes through
  Error::exit_code. The server runs the same ledger implementation as the
  CLI (thesis §5) and never depends on hqgit-cli (constitution XIII).
---

# 090: The hqgit-server binary

## 1. Purpose

Thesis §4.7 and §5: the edge is a set of interchangeable clients over the
same signed history, and the server is one of them, embedding the very
`Repository` (021) the `hq` binary (032) writes to. Nothing in this spec
interprets a fact; it is the process boundary, the port, the data
directory, and the seams (who is calling, where does a write go) that the
git endpoint, the API, the quarantine, and the UI all need to agree on.
Founding those once, before any route exists, is what keeps 092 through
095 from inventing four authentication shapes.

## 2. Territory

`crates/hqgit-server` as founded here: the manifest (binary and library
targets, both named `hqgit-server`, workspace dependencies `hqgit-types`,
`hqgit-object`, `hqgit-ledger`, and `hqgit-domain`; never `hqgit-cli`),
`main.rs` (argument parsing, the single exit), `lib.rs`, `config.rs`,
`app.rs` (the router builder and `AppState`), `health.rs`, `repos.rs` (the
registry and the server identity), `auth.rs` (the `Caller` type and the two
seams), `telemetry.rs` (logging), and the `tests/` subtree with the
ephemeral-server harness later specs reuse. The control plane is 091, the
git protocol 092, the API 093, quarantine 094, static files 095.

## 3. Behavior

- **B-1 (config).** `Config { bind: SocketAddr, data_dir: PathBuf, node:
  Option<NodeId>, oidc: OidcSection { issuer: Option<String>, audience:
  Option<String> }, log: LogSection { format: Json | Text, level: String },
  limits: LimitsSection { max_body_bytes: u64, request_timeout_secs: u64 },
  shutdown_grace_secs: u64, anonymous_read: bool }`. Defaults: bind
  `127.0.0.1:7410`, `max_body_bytes` 64 MiB, timeout 60, grace 20,
  `anonymous_read = true`, log `json` at `info`. Load order: the file named
  by `--config <path>` or `HQGIT_SERVER_CONFIG`, then the environment
  (`HQGIT_BIND`, `HQGIT_DATA_DIR`, `HQGIT_OIDC_ISSUER`, `HQGIT_LOG_FORMAT`,
  `HQGIT_LOG_LEVEL`), then defaults. An unknown key is `Error::Config`
  naming it. `oidc` is a placeholder 061 reads; no secret ever lives in the
  file.
- **B-2 (one listener).** `app.rs` exposes `AppState { config: Arc<Config>,
  repos: Arc<RepoRegistry>, auth: Arc<dyn Authenticator>, router: Arc<dyn
  NamespaceRouter>, identity: Arc<ServerIdentity> }` and `AppBuilder::new(
  state).with_http(Router<AppState>).with_grpc(service).build() -> Router`.
  `build` merges every HTTP router, mounts every tonic service through
  `tonic::service::Routes`, and dispatches by `Content-Type`
  (`application/grpc*` to tonic, everything else to axum) so HTTP/1.1,
  Connect JSON (093), and HTTP/2 gRPC share `config.bind`. Layers, in
  order: request id (`x-request-id`, generated when absent), tracing span,
  body limit, timeout. Later specs add routes only through the builder.
- **B-3 (repo registry).** `RepoRegistry::new(data_dir, identity,
  registrars: Vec<Registrar>)` where a `Registrar` is a fact-registry
  install function (019 B-2: `register_domain`, later `register_trust`),
  applied to every repository on open. Layout: `<data>/repos/<namespace-hex>/
  .hq` (64 lowercase hex characters, the working directory of a spec 021
  `Repository`). `open(&self, ns: &Hash) -> Result<Arc<RepoHandle>, Error>`
  opens lazily, memoizes in a `Mutex<BTreeMap<Hash, Arc<RepoHandle>>>`, and
  returns the same `Arc` for the same namespace; `create(&self) ->
  Result<Arc<RepoHandle>, Error>` runs `Repository::init` (021 B-4) with the
  server identity; `list() -> Result<Vec<Hash>, Error>` scans the directory
  sorted; `close_idle(older_than)` drops handles. `RepoHandle { namespace:
  Hash, repo: RwLock<Repository> }`: reads take the read lock, appends the
  write lock, so the 021 append path stays the only write path.
- **B-4 (server identity).** `ServerIdentity` is a spec 021 `LocalIdentity`
  stored at `<data>/identity/seed` (mode `0600`), generated on first boot,
  with `Principal::Service(ServiceId)` derived as 060 will (an
  `identity.created` fact appended to each repository this identity
  creates). It signs every entry the server itself issues; an entry the
  server appends on behalf of a caller carries `extra["on_behalf_of"] =
  <principal>` and `extra["via"] = "<surface>"` (092, 093 fill the surface).
- **B-5 (caller seam).** `auth.rs`: `Caller { principal: Option<Principal>,
  trust: CallerTrust }` with `CallerTrust` a closed enum `Anonymous |
  Bearer { token_hash: Hash } | Verified { identity: IdentityId, key: KeyId
  }`. `trait Authenticator: Send + Sync { fn authenticate(&self, headers:
  &HeaderMap) -> Result<Caller, Error>; }` with two implementations here:
  `AnonymousAuthenticator` and `StaticTokenAuthenticator(BTreeMap<Hash,
  Principal>)` keyed by `Hash::of(token)` for tests. `Caller` is an axum
  extractor and a tonic interceptor extension. 061 and 100 supply
  production authenticators; nothing here validates a credential.
- **B-6 (namespace routing seam).** `trait NamespaceRouter: Send + Sync {
  fn target_for(&self, caller: &Caller, repo: &RepoHandle) -> Result<Hash,
  Error>; }` answers which namespace a write lands in. The default here,
  `TrustRouter`, returns `main` for `CallerTrust::Verified` and the repo's
  quarantine namespace (021 B-6) for everything else, so constitution XV
  holds from the first write; 094 replaces it with the capability-checked
  router. No surface may append without consulting the router.
- **B-7 (health).** `GET /healthz` answers `200 { "status": "ok",
  "version": <crate version> }` whenever the process serves; `GET /readyz`
  answers `200 { "ready": true }` when the data directory is writable and
  the identity is loaded, else `503 { "ready": false, "reasons": [...] }`.
  Neither opens a repository. The gRPC health service (`tonic-health`)
  reports `SERVING` on the same port for `hqgit.v1`.
- **B-8 (shutdown and exit).** `SIGTERM` or `SIGINT` stops accepting,
  drains in-flight requests for `shutdown_grace_secs`, drops every
  `RepoHandle` (redb commits are already durable, 021 B-2), and exits `0`.
  A startup failure exits through spec 010 `Error::exit_code` in the one
  `std::process::exit` call in `main.rs`; `hqgit-server --check-config`
  loads the config and exits without binding.
- **B-9 (logs).** `telemetry.rs` installs `tracing-subscriber` with JSON
  lines (`ts`, `level`, `target`, `request_id`, `method`, `path`, `status`,
  `latency_ms`, `namespace`) or text per config. No log line ever carries a
  bearer token, a request body, or object content; a test greps for both.
- **B-10 (same ledger, no ambient input on hashed paths).** The crate
  never spawns `git` or `hq`; it reaches the ledger only through 021
  `Repository`. The wall clock enters only through one `SystemClock`
  implementing 018's `ClockSource`, constructed in `repos.rs` and handed to
  each repository's `HlcGenerator`; no handler formats `SystemTime` into a
  response. `BTreeMap` is the only map type.

## 4. Functional requirements

- **FR-001.** `tests/harness.rs` exposes `TestServer::start(config_overrides)
  -> TestServer { addr, data_dir: TempDir, state }` binding port `0`, used
  by every later server test; drop shuts the server down.
- **FR-002.** Tests cover: config precedence file, then environment, then
  defaults; an unknown key exits `3` through the binary; `/healthz` 200 and
  `/readyz` 200 on a fresh data directory, 503 after the directory is made
  read-only; the gRPC health check `SERVING`; `create` then `open` returns
  the same `Arc` twice and the layout of B-3 exists on disk; a repository
  created by the server opens with `hq status` (032) from its directory;
  `StaticTokenAuthenticator` yields `Bearer` for a known token and
  `Anonymous` for none; `TrustRouter` sends an anonymous write to
  quarantine; a request in flight completes during graceful shutdown; logs
  contain `request_id` and never the test bearer.
- **FR-003.** `main.rs` contains exactly one `process::exit`; a contract
  test drives every `Error` variant through `--check-config` fixtures.
- **FR-004.** The manifest carries `[package.metadata.spec-spine] spec =
  "090-server-skeleton"` and `cargo tree -p hqgit-server` shows no
  `hqgit-cli`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-server --locked` passes.
- **AC-2.** `hqgit-server --data-dir <tmp>` boots, answers `/healthz`, and
  exits `0` on `SIGTERM` within the grace period.
- **AC-3.** `spec-spine index` discovers `hqgit-server` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Replicated append order and placement (091), the git smart protocol (092),
the typed API and its CLI client (093), capability checks and quarantine
limits (094), static files for the UI (095), OIDC sessions (061), Biscuit
authentication (102), and federation (112).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-server --locked
cargo run -p hqgit-server --locked -- --check-config
```
