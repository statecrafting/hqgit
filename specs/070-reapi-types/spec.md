---
id: "070-reapi-types"
title: "Remote Execution API types: vendored protos, BLAKE3 digests, actions, the CAS adapter"
status: approved
kind: "kernel"
domain: "l3-evaluation"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 5
depends_on:
  - "013-object-store"
establishes:
  - "crates/hqgit-eval/Cargo.toml"
  - "crates/hqgit-eval/build.rs"
  - "crates/hqgit-eval/proto/build/bazel/remote/execution/v2/remote_execution.proto"
  - "crates/hqgit-eval/proto/build/bazel/semver/semver.proto"
  - "crates/hqgit-eval/proto/google/"
  - "crates/hqgit-eval/src/lib.rs"
  - "crates/hqgit-eval/src/digest.rs"
  - "crates/hqgit-eval/src/action.rs"
  - "crates/hqgit-eval/src/cas_adapter.rs"
  - "crates/hqgit-eval/tests/"
  - "crates/hqgit-eval/testdata/reapi/"
extends:
  # prost, prost-types, tonic, tonic-build, protox: the wire substrate of L3.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The evaluation plane speaks the Bazel Remote Execution API rather than a
  protocol of its own (thesis D9), so existing executors, clients, and
  caches interoperate on day one. This spec founds hqgit-eval with the
  vendored REAPI v2 protos compiled at build time, a BLAKE3 digest function
  that coincides with the hqgit object hash for raw blobs and carries an
  explicit mapping where the two encodings differ (Directory versus Tree),
  the pure construction of an Action from (repository state, target,
  toolchain) whose digest is the key the cache and the merge queue share,
  and the CAS adapter that presents the spec 013 object store as REAPI
  content-addressable storage. No service listens yet (072) and nothing
  executes (073): this is the typed vocabulary the rest of wave 5 shares.
---

# 070: Remote Execution API types

## 1. Purpose

Thesis §4.4 fixes the evaluation plane as `eval(repo_state_hash, target,
toolchain_hash) -> output_hash`, cached globally on input hash, and thesis
D9 refuses to invent the protocol: the Bazel Remote Execution API (REAPI)
already has executors, clients, and caches. What hqgit adds is the
identity of the inputs: the repository state is a spec 013 tree, the
toolchain is a hash, and the action digest is therefore a pure function of
canonical, content-addressed inputs. This spec is where REAPI's digests and
hqgit's Cids are reconciled once, in code, with a table for every place the
two byte encodings differ, so no later spec has to guess which hash it is
holding.

## 2. Territory

`crates/hqgit-eval` as founded here: the manifest (workspace dependencies
on `hqgit-types`, `hqgit-object`, `prost`, `prost-types`, `tonic`), the
`build.rs` that compiles the vendored protos through `tonic-build` with
`protox` (no `protoc` binary is required, so `--locked` builds are
hermetic), the vendored proto tree, `lib.rs`, `digest.rs` (the digest
function and the mapping table), `action.rs` (Action, Command, and the
action key), `cas_adapter.rs` (the object store seen as CAS), the `tests/`
subtree, and recorded REAPI fixtures under `testdata/reapi/`. The gRPC
services are spec 072; the cache is spec 071; provenance is spec 074; the
build graph is spec 075.

## 3. Behavior

- **B-1 (vendored protos).** The crate vendors
  `build/bazel/remote/execution/v2/remote_execution.proto` and
  `build/bazel/semver/semver.proto` at REAPI v2.3 or later (the first
  release whose `DigestFunction.Value` enumerates `BLAKE3 = 9`), plus the
  `google/api`, `google/rpc`, `google/longrunning`, and `google/bytestream`
  protos they import, byte for byte from upstream with the upstream commit
  recorded in `proto/VERSION`. `build.rs` generates `build.bazel.remote.
  execution.v2`, `google.longrunning`, `google.bytestream`, and `google.rpc`
  modules with server and client stubs; generation MUST be deterministic
  (sorted inputs, no timestamps in output).
- **B-2 (digest function).** `Digest { hash: Hash, size_bytes: u64 }` is
  the typed form of the REAPI `Digest` message; the wire `hash` field is
  the 64-character lowercase hex of spec 010's `Hash`, and `DigestFunction`
  is always `BLAKE3`. `digest_of(bytes) -> Digest` is `Hash::of(bytes)`
  with the byte length. A server or client advertising any other digest
  function is refused with `Error::Validation` naming the function.
- **B-3 (the coincidence rule).** For a raw blob, the REAPI digest hash
  equals the hash of the spec 013 `Cid { codec: Raw }` of the same bytes,
  so a blob has one identity in both worlds. For structured messages the
  encodings differ: a REAPI `Directory` is a deterministically serialized
  protobuf, a hqgit `Tree` is DAG-CBOR. `digest.rs` therefore carries an
  explicit `DirectoryMap` (`BTreeMap<Cid, Digest>` plus the inverse) built
  by `tree_to_directory(tree: &Tree, store) -> Result<(Directory, Digest),
  Error>` and `directory_to_tree(dir: &Directory, store) -> Result<Cid,
  Error>`; both conversions are pure given the store, and both are tested to
  round-trip. Tree entry modes map to `FileNode.is_executable`,
  `DirectoryNode`, and `SymlinkNode`; a mode with no REAPI counterpart is
  `Error::Validation`. `Tree` chunked blobs (spec 014 `BlobManifest`) are
  presented as one REAPI blob with the whole-content hash recorded in the
  manifest, never as their chunks.
- **B-4 (canonical proto bytes).** Every message hqgit digests
  (`Directory`, `Command`, `Action`) is serialized in REAPI's required
  canonical form: fields in field-number order, repeated entries sorted
  where the API mandates it (`Directory.files` by name, `Command.
  environment_variables` by name, `Command.output_paths` lexicographic), no
  unknown fields, no default-valued scalars emitted. `canonical_bytes(msg)`
  is the one serialization path and is what `digest_of` receives.
- **B-5 (action key).** `action.rs` defines `ActionInput { input_root: Cid,
  target: TargetId, command: Command, toolchain: Hash, platform:
  BTreeMap<String, String>, timeout_s: Option<u32>, do_not_cache: bool }`
  and `action_key(input: &ActionInput, store) -> Result<ActionKey, Error>`
  where `ActionKey(Digest)` is the digest of the REAPI `Action` built from
  the `Command` digest, the `Directory` digest of `input_root` (B-3), the
  timeout, `do_not_cache`, and the platform properties. The toolchain hash
  enters the action as the platform property `hqgit.toolchain` and the
  target as `hqgit.target`, so two evaluations differing only in toolchain
  or target never share a key. `salt` is never used. The key is the
  `output_hash` of the thesis's `eval` signature: what the cache (071) is
  indexed by and what the merge queue (076) speculates over.
- **B-6 (CAS adapter).** `CasAdapter<S: ObjectStore>` implements a
  `ContentAddressable` trait: `find_missing(&[Digest]) -> Vec<Digest>`,
  `read(&Digest) -> Result<Bytes, Error>`, `write(bytes) -> Result<Digest,
  Error>`, and `read_directory_tree(root: &Digest) -> Result<Vec<Directory>,
  Error>` (the `GetTree` shape), all over spec 013's `ObjectStore` with
  blobs stored as `Raw` and directories stored as their canonical proto
  bytes as `Raw` with the `DirectoryMap` updated. Every read verifies the
  hash on the way out (013 B-x); a size mismatch between the requested
  `size_bytes` and the stored length is `Error::Validation`.
- **B-7 (no ambient input).** Nothing in this crate reads a clock, the
  environment, or a `HashMap`; spec 010 FR-003's source guard applies. The
  generated code is excluded from that guard by path.

## 4. Functional requirements

- **FR-001.** `build.rs` compiles the vendored protos with `protox` and
  `tonic-build`; generated output lands under `OUT_DIR`, never in the
  source tree; a checked-in `proto/VERSION` names the upstream commit.
- **FR-002.** Tests cover: `digest_of` against recorded REAPI fixtures
  under `testdata/reapi/` (a blob, a `Directory`, a `Command`, an `Action`,
  each with its expected BLAKE3 digest produced by an independent REAPI
  implementation); the coincidence rule for raw blobs; `Tree` to
  `Directory` and back for a nested fixture with an executable and a
  symlink; a chunked blob presented as one REAPI blob; `action_key`
  stability across two builds and sensitivity to each input field; refusal
  of a non-BLAKE3 digest function.
- **FR-003.** The `ContentAddressable` trait is object-safe and the adapter
  is tested against spec 013's `MemoryStore`: find-missing, write-read
  round trip, size mismatch refusal, `read_directory_tree` breadth-first
  order.
- **FR-004.** The crate depends on `hqgit-types` and `hqgit-object` only
  within the workspace; `tonic` server features are enabled but no service
  is implemented here.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-eval --locked` passes, fixtures included.
- **AC-2.** `cargo build -p hqgit-eval --locked` succeeds on a machine with
  no `protoc` installed.
- **AC-3.** `spec-spine index` discovers `hqgit-eval` bound to this spec and
  `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The action cache and its trust rules (071); the gRPC services and the
scheduler (072); executors and sandboxes (073); provenance attestations
(074); the build manifest and affected-target selection (075); the merge
queue (076).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-eval --locked
cargo clippy -p hqgit-eval --all-targets --locked -- -D warnings
```
