---
id: "010-workspace-and-core-types"
title: "Cargo workspace and the core types: Hash, Cid, Principal, keys, Hlc, Error"
status: approved
kind: "kernel"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "002-platform-thesis"
establishes:
  - "Cargo.toml"
  - "rust-toolchain.toml"
  - "deny.toml"
  - "crates/hqgit-types/Cargo.toml"
  - "crates/hqgit-types/src/lib.rs"
  - "crates/hqgit-types/src/hash.rs"
  - "crates/hqgit-types/src/cid.rs"
  - "crates/hqgit-types/src/principal.rs"
  - "crates/hqgit-types/src/key.rs"
  - "crates/hqgit-types/src/hlc.rs"
  - "crates/hqgit-types/src/error.rs"
  - "crates/hqgit-types/src/version.rs"
  - "crates/hqgit-types/tests/"
summary: >
  The first build: a virtual Cargo workspace with the toolchain pinned,
  unsafe forbidden, one shared dependency table, and a supply-chain policy;
  plus hqgit-types, the plain-data substrate every other crate depends on
  and that depends on nothing in the workspace. It fixes the value types
  that reach hashed bytes: Hash (BLAKE3-256), Cid (codec plus hash), the
  four-variant Principal, KeyId and Signature with the ed25519 Signer and
  Verifier seams and the frozen signing preimage, the Hlc timestamp with its
  total order, the Error enum with the four exit codes, and the schema
  version constants. Everything here is owned data with serde derives and no
  lifetimes, generics, or trait objects at the boundary, so the same types
  back the CLI, the server, and any future binding.
---

# 010: Cargo workspace and the core types

## 1. Purpose

Every layer above L0 shares a handful of value types, and several of them
are hashed or signed. If those types are defined twice, or defined with a
representation that can drift (a float, a map with unstable order, a clock
read), the ledger's hash stability (constitution VIII) is lost before the
ledger exists. This spec creates the workspace and pins those types in one
dependency-free crate. It also plants the `Principal` enum with its `Agent`
variant now, because the thesis (002 §6, step 7) requires agents to be a
distinct principal class from the first type definition even though the
agent runtime ships in wave 7.

## 2. Territory

The workspace root (`Cargo.toml`, `rust-toolchain.toml`, `deny.toml`) and
the whole of `crates/hqgit-types` as it stands after this spec: the crate
manifest, `lib.rs`, the seven modules named in `establishes`, and the
`tests/` subtree. The canonical encoder (`src/codec/`) is spec 011's
territory inside the same crate; it `extends` this spec's `lib.rs` and
`Cargo.toml`. Later specs that add a third-party dependency declare an
`extends` edge on this spec's `Cargo.toml` section `workspace.dependencies`.

## 3. Behavior

- **B-1 (workspace).** The root `Cargo.toml` is a virtual workspace with
  `members = ["crates/*"]` and `exclude = ["fuzz"]` (spec 012 keeps its own
  workspace), `resolver = "3"`, a `[workspace.package]` table (edition 2024,
  `rust-version`, license `AGPL-3.0-only`, repository URL), a
  `[workspace.lints.rust]` table with `unsafe_code = "forbid"`, a
  `[workspace.lints.clippy]` table denying `unwrap_used`, `expect_used`,
  `indexing_slicing`, and `float_arithmetic` in library code, and a single
  `[workspace.dependencies]` table where every third-party dependency's
  version lives. Crate manifests reference `workspace = true` for
  everything they inherit.
- **B-2 (toolchain).** `rust-toolchain.toml` pins a stable channel by exact
  version with `components = ["rustfmt", "clippy"]`. `Cargo.lock` is
  committed and every gate passes `--locked`.
- **B-3 (supply chain).** `deny.toml` allows `MIT`, `Apache-2.0`,
  `BSD-2-Clause`, `BSD-3-Clause`, `ISC`, `Unicode-3.0`, `Zlib`, `MPL-2.0`,
  and `AGPL-3.0-only` (this workspace), denies unknown registries and git
  sources except allow-listed ones, warns on duplicate versions, and denies
  advisories with a known fix.
- **B-4 (`Hash`).** A `#[repr(transparent)]` newtype over `[u8; 32]`, the
  BLAKE3-256 output. `Hash::of(&[u8]) -> Hash` is the only constructor from
  content; `Hash::from_bytes` and `as_bytes` round-trip. `Display` and
  `FromStr` are exactly 64 lowercase hex characters, no prefix. `Ord` is the
  byte order. serde encodes it as a byte string, never as text, so that the
  canonical encoding (011) is 32 bytes plus the CBOR header.
- **B-5 (`Cid`).** `Cid { codec: Codec, hash: Hash }` where `Codec` is a
  closed enum `DagCbor | Raw` with `u64` tags `0x71` and `0x55` (the IPLD
  multicodec values) so a Cid is portable. serde encodes a Cid as the
  two-element array `[codec_tag, hash_bytes]`. `Display` is
  `<codec-name>:<hex>` (`dag-cbor:ab12...`).
- **B-6 (`Principal`).** `enum Principal { Human(HumanId), Agent(AgentId),
  Service(ServiceId), Org(OrgId) }`, each id a newtype over `Hash` (the
  identity's genesis hash, spec 060). The enum is `#[non_exhaustive]` for
  readers, exhaustive for writers within the crate, and its serde form is
  externally tagged with the lowercase variant name. `Principal::kind()`
  returns a `PrincipalKind` enum that policy (065) and authorization (101)
  match on; there is no conversion between kinds.
- **B-7 (keys and signing).** `KeyId` is `Hash::of(public_key_bytes)`.
  `PublicKey` is 32 bytes (ed25519); `Signature` is 64 bytes; both encode as
  byte strings. `SignDomain(&'static str)` names what is being signed. The
  frozen preimage is `b"hqgit/v1/" || domain || 0x00 || payload`; the
  `Signer` trait is `fn sign(&self, domain: SignDomain, payload: &[u8]) ->
  Signature` and `fn key_id(&self) -> KeyId`; the `Verifier` trait is
  `fn verify(&self, domain: SignDomain, payload: &[u8], sig: &Signature) ->
  Result<(), Error>`. `Ed25519Signer` (from a 32-byte seed) and
  `Ed25519Verifier` (from a `PublicKey`) are the only implementations here.
  Seeds are never `Debug`-printed or serialized.
- **B-8 (`Hlc`).** `Hlc { wall_ms: u64, logical: u32, node: NodeId }` with
  `NodeId` a 16-byte newtype. `Ord` is lexicographic on `(wall_ms, logical,
  node)`; serde encodes the three fields as a three-element array. The type
  reads no clock; generation is spec 018's `clock.rs`.
- **B-9 (`Error`).** One `Error` enum for the workspace's library crates with
  variants `Validation(String)`, `NotFound(String)`, `Drift(String)`,
  `Stale(String)`, `Io(String)`, `Parse(String)`, `Schema(String)`,
  `Config(String)`, `Crypto(String)`, and `Policy(String)`, each carrying an
  owned message, plus `fn exit_code(&self) -> i32` mapping to `1`
  (validation, not found, drift, crypto, policy), `2` (stale), and `3`
  (io, parse, schema, config). Binaries (032, 090) map exit codes in exactly
  one place each through this function.
- **B-10 (versions).** `version.rs` holds `pub const` schema versions as
  `&str` in `MAJOR.MINOR.PATCH`: `OBJECT_SCHEMA_VERSION`,
  `LEDGER_SCHEMA_VERSION`, `DOMAIN_SCHEMA_VERSION`, all `"1.0.0"`, and
  `WIRE_VERSION_PREFIX = "hqgit/v1/"`. Bumping a MAJOR is a spec amendment.
- **B-11 (plain data).** Every public type is owned, `Clone`, `Debug`
  (seeds excepted), `PartialEq`, `Eq`, and serde-derived; no lifetimes,
  generics, or trait objects appear in a public field. Nothing in this crate
  reads `std::time`, `std::env`, or iterates a `HashMap`: `BTreeMap` is the
  only map type.

## 4. Functional requirements

- **FR-001.** `cargo build --workspace --locked` and `cargo clippy
  --workspace --all-targets --locked -- -D warnings` pass with
  `hqgit-types` as the sole member; `cargo tree -p hqgit-types` shows no
  workspace crate.
- **FR-002.** Tests cover: `Hash` hex round-trip and byte order; `Cid`
  serde form as the tagged pair; `Principal` serde tag names and `kind()`;
  the signing preimage against a recorded vector (seed, domain, payload,
  expected signature); `Hlc` ordering across each field; every `Error`
  variant's exit code.
- **FR-003.** A test reads the crate's own sources and asserts none contains
  `std::time`, `std::env`, `HashMap`, `HashSet`, `f32`, or `f64` outside a
  comment (the cheap guard behind B-11).
- **FR-004.** `cargo deny check` passes with the `deny.toml` of B-3.
- **FR-005.** Every crate manifest carries
  `[package.metadata.spec-spine] spec = "<founding spec id>"` (this crate:
  `010-workspace-and-core-types`), the manifest floor spec-spine's coupling
  gate reads.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-types --locked` passes.
- **AC-2.** `make ci` exits 0 on the branch (the cargo gates are now live).
- **AC-3.** `spec-spine index` discovers exactly one package,
  `hqgit-types`, bound to this spec, and `spec-spine index coverage
  --fail-on-untraced` exits 0.

## 6. Out of scope

The canonical encoder and unknown-field preservation (011); the HLC
generation algorithm (018); identity, rotation, and keyless signing (060,
063); any I/O.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-types --locked
cargo clippy -p hqgit-types --all-targets --locked -- -D warnings
```
