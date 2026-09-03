---
id: "051-semantic-deltas"
title: "Semantic deltas: API surface, dependency, and capability changes as attestations"
status: approved
kind: "feature"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 3
depends_on:
  - "027-attestation-primitive"
  - "050-stacked-changes"
  - "025-semantic-anchors"
establishes:
  - "crates/hqgit-domain/src/delta/mod.rs"
  - "crates/hqgit-domain/src/delta/api_surface.rs"
  - "crates/hqgit-domain/src/delta/dependencies.rs"
  - "crates/hqgit-domain/src/delta/capabilities.rs"
  - "crates/hqgit-domain/tests/delta.rs"
  - "crates/hqgit-domain/testdata/deltas/"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  # The reserved hqgit/semantic-delta/v1 claim schema gets its shape here.
  - { spec: "027-attestation-primitive", unit: "crates/hqgit-domain/src/predicate.rs", nature: additive }
  # Manifest and lockfile parsing needs toml and serde_json.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The line diff is the lowest-value view of a change (design §1.1 point
  3). For a pair of trees this spec computes the three views a reviewer
  wants first: the public API surface delta (items added, removed, and
  re-signatured, via tree-sitter for Rust and TypeScript), the dependency
  delta (Cargo and npm manifests and lockfiles, new registry or git
  sources called out), and the capability delta (network, filesystem,
  process, environment, secret, unsafe, and dynamic-code access by static
  heuristics that deliberately over-report). Each delta is issued as an
  Attestation under hqgit/semantic-delta/v1 (constitution IX), so policy
  and the UI consume evidence rather than a rendering. The result is
  deterministic for two trees and a pinned analyzer, and a file it cannot
  analyze is listed as unsupported, never silently skipped.
---

# 051: Semantic deltas

## 1. Purpose

Thesis §4.3 and design §1.1 point 3: the high-value views of a change are
deltas of API surface, dependency set, and capability set, and review
should start from them. Thesis §8 accepts that semantic review is
per-language (Rust and TypeScript first, everything else degrading
visibly). This spec turns those views into evidence: an attestation with
a typed claim, signed by whoever computed it, replayable against the two
trees it names. Constitution IX forbids a new noun, so a delta registers a
predicate and nothing else.

## 2. Territory

The `delta/` module in `crates/hqgit-domain`: `mod.rs` (`DeltaSet`, the
claim, issuance, the unsupported vocabulary), `api_surface.rs`,
`dependencies.rs`, `capabilities.rs`; `tests/delta.rs`; and the fixture
subtree `testdata/deltas/`. Additively: `lib.rs` re-exports; the
`hqgit/semantic-delta/v1` claim schema and validator in 027's
`predicate.rs` (replacing the opaque reservation); `toml` pinned exact in
`[workspace.dependencies]` (plus `serde_json` unless 032 already added
it), inherited by the crate manifest.

## 3. Behavior

- **B-1 (entry point).** `compute_deltas(store: &dyn ObjectStore,
  from_tree: &Cid, to_tree: &Cid) -> Result<DeltaSet, Error>` with
  `DeltaSet { from_tree: Cid, to_tree: Cid, analyzer: Analyzer, api:
  ApiSurfaceDelta, dependencies: DependencyDelta, capabilities:
  CapabilityDelta }`. Touched paths come from 050 `tree_diff`; only
  touched files are read. `Analyzer { name: String, version: String,
  grammars: BTreeMap<String, String> }` records the crate version
  (`env!("CARGO_PKG_VERSION")`) and the exact grammar crate versions 025
  pins, so a claim names the analyzer that produced it.
- **B-2 (never silence).** Every touched file ends in exactly one place:
  analyzed, or in the relevant delta's `unsupported: Vec<Unsupported>`
  with `Unsupported { path: String, reason: UnsupportedReason }` and
  `UnsupportedReason` a closed enum `Language(String) | ParseErrors |
  Binary | TooLarge { bytes: u64 } | Erased | Lockfile(String)`. `Binary`
  is a NUL byte in the first 8 KiB; `TooLarge` is over 4 MiB; `Erased` is
  a 020 tombstone; `Language` carries the extension.
- **B-3 (items).** `api_surface::extract_items(language, path: &str,
  bytes: &[u8]) -> Result<Vec<Item>, Error>` for Rust and TypeScript
  through 025's `syntax::parse`. `Item { path: String, name: String, kind:
  ItemKind, visibility: Visibility, signature: String, signature_hash:
  Hash, anchor: Anchor }`; `name` is qualified within the file
  (`outer::Inner::method` in Rust, `Outer.method` in TypeScript);
  `ItemKind` is `Function | Method | Struct | Enum | Union | Trait |
  TraitImpl | TypeAlias | Const | Static | Module | Macro | Class |
  Interface | Variable | ReExport`; `Visibility` is `Public | Restricted |
  Private`. Rust `Public` is unrestricted `pub` (plus `#[macro_export]`),
  `pub(crate)`, `pub(super)`, and `pub(in ..)` are `Restricted`; TypeScript
  `Public` is any `export` form. Public methods and fields of a public
  type are part of its signature and items of their own. `signature` is
  the item's source with function bodies and comments removed and
  whitespace runs collapsed to one space; `signature_hash =
  Hash::of(signature)`; `anchor` is 025 `anchor_at` over the item node.
- **B-4 (`ApiSurfaceDelta`).** `{ added: Vec<Item>, removed: Vec<Item>,
  changed: Vec<ItemChange { before: Item, after: Item }>, unsupported }`
  over `Public` items only, keyed by `(path, kind, name)`, every list
  sorted by that key. A removed file removes all its items; a renamed
  file appears as removals plus additions (path-keyed by design; cross-file
  identity is 083).
- **B-5 (`DependencyDelta`).** `Dep { ecosystem: Ecosystem, manifest:
  String, name: String, version: String, source: Source, scope: Scope,
  locked: Option<String> }` with `Ecosystem` `Cargo | Npm`, `Source`
  `Registry(String) | Git { url: String, rev: Option<String> } |
  Path(String) | Workspace`, `Scope` `Normal | Dev | Build | Optional |
  Peer`. Parsed: `Cargo.toml` at any depth (`dependencies`,
  `dev-dependencies`, `build-dependencies`, `target.*.dependencies`,
  `workspace.dependencies`), `Cargo.lock` (`[[package]]` name, version,
  source, filling `locked`), `package.json` (the four dependency maps),
  `package-lock.json` (v2 and v3 `packages`); `yarn.lock`, `pnpm-lock.yaml`,
  `go.mod`, `requirements.txt`, and `pyproject.toml` are
  `Unsupported::Lockfile` by name.
  `DependencyDelta { added, removed, version_changed: Vec<DepChange {
  before: Dep, after: Dep }>, source_changed: Vec<DepChange>, new_sources:
  Vec<Source>, unsupported }` keyed by `(ecosystem, manifest, name)`;
  version comparison is string inequality (no semver arithmetic);
  `new_sources` lists every `Registry` or `Git` source present in `to` and
  absent from `from` across all manifests.
- **B-6 (`CapabilityDelta`).** `Capability` is a closed enum `Network |
  Filesystem | Process | Environment | Secret | Unsafe | DynamicCode`.
  `CapabilityUse { capability, path, evidence: String, anchor: Anchor }`
  where `evidence` is the matched import path, call, or block kind. The
  heuristic table is fixed in `capabilities.rs` and pinned by a golden
  listing (`testdata/deltas/capabilities/rules.json`): Rust `std::net`,
  `tokio::net`, `reqwest`, `hyper`, `ureq` are `Network`; `std::fs`,
  `tokio::fs` `Filesystem`; `std::process`, `tokio::process`, `libc`
  `Process`; `std::env` `Environment`; `unsafe` blocks and functions
  `Unsafe`; `libloading` `DynamicCode`. TypeScript imports of `net`,
  `http`, `https`, `dns`, `tls`, `fetch(`, `WebSocket` are `Network`; `fs`,
  `fs/promises` `Filesystem`; `child_process` `Process`; `process.env`
  `Environment`; `eval(` and `new Function(` `DynamicCode`; the `node:`
  prefix is stripped. `Secret` is any `Environment` use whose key or
  binding name contains, case-insensitively, one of `secret`, `token`,
  `password`, `passwd`, `api_key`, `apikey`, `credential`,
  `private_key`. `CapabilityDelta { gained: Vec<CapabilityUse>, lost:
  Vec<CapabilityUse>, unsupported }` compares the per-file use sets keyed
  by `(capability, path, evidence)`. No data flow is traced: a name match
  counts, so the delta over-reports by design.
- **B-7 (claim and issuance).** `SemanticDeltaClaim { from_tree: Cid,
  to_tree: Cid, from_revision: Option<RevisionId>, to_revision:
  RevisionId, analyzer: Analyzer, delta: Delta, extra }` with `Delta` an
  externally tagged enum `Api(ApiSurfaceDelta) |
  Dependencies(DependencyDelta) | Capabilities(CapabilityDelta)`; every
  struct derives `Canonical` (011). `predicate.rs` registers its validator
  for `hqgit/semantic-delta/v1` in `register_builtin`: required fields,
  sorted and duplicate-free lists, `Cid` codecs `DagCbor`, ids 32 bytes.
  `DeltaSet::claims(&self, from_revision, to_revision) ->
  [SemanticDeltaClaim; 3]` and `issue_deltas(store: &dyn ObjectStore,
  claims: &[SemanticDeltaClaim], issuer: Principal, signer: &impl Signer,
  at: Hlc) -> Result<Vec<(Attestation, DomainFact)>, Error>` store each
  claim as a `DagCbor` object, sign with `subject = to_revision` (027
  B-3), and return the `attestation.issued` facts for the caller to append
  (021). The issuer is the computing principal: the server's `Service`
  identity, or offline the local identity (033); policy (065) decides
  which issuers count, the domain refuses none.
- **B-8 (determinism).** For equal `(from_tree, to_tree, analyzer)` the
  three claims are byte-identical, independent of store insertion order
  and of the order `tree_diff` is walked; no clock, environment, `HashMap`,
  or float appears; `BTreeMap` and sorted `Vec`s only. Equal trees produce
  three empty deltas, still issued, so "no change" is evidence too.

## 4. Functional requirements

- **FR-001.** Fixtures under `testdata/deltas/api/{rust,typescript}/<case>/`
  (`before.<ext>`, `after.<ext>`, `expected.json`) cover: item added,
  removed, signature changed, body-only change (no delta), visibility
  widened and narrowed, nested method, re-export, default export, file
  removed, file renamed, parse errors, an unknown extension, a binary
  file, and an oversize file.
- **FR-002.** Fixtures under `testdata/deltas/deps/{cargo,npm}/<case>/`
  (`before/`, `after/`, `expected.json`) cover: added, removed, version
  changed, dev scope, workspace inheritance, a new git source, a new
  registry, lockfile-only resolution change, and a `pnpm-lock.yaml`
  reported unsupported.
- **FR-003.** Fixtures under `testdata/deltas/capabilities/{rust,typescript}/`
  cover each `Capability` gained and lost, the secret heuristic on a key
  and on a binding, and `rules.json` matches the table in code exactly.
- **FR-004.** `testdata/deltas/claims/semantic-delta-api.json` records the
  canonical bytes and hash of one claim; frozen (constitution VIII): a
  shape change is a predicate `v2`, never an edit.
- **FR-005.** Tests: double computation yields identical bytes; the
  validator accepts every fixture claim and rejects a missing field, an
  unsorted list, and a `Raw` tree cid; `issue_deltas` produces three
  attestations whose signatures verify (027 B-6) and whose subjects equal
  `to_revision`; a fuzz-style test feeds random bytes through
  `extract_items` for both languages without panic.
- **FR-006.** `lib.rs` re-exports `compute_deltas`, `DeltaSet`,
  `SemanticDeltaClaim`, `Delta`, the three delta types, `Item`,
  `Capability`, and `Unsupported`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked delta` passes with every
  fixture in FR-001 to FR-003.
- **AC-2.** `cargo test -p hqgit-domain --locked attestation` still passes
  with the semantic-delta validator installed.

## 6. Out of scope

Conflict detection over deltas (052); cross-file and cross-repo symbol
identity and downstream impact (083, 084); observed test behavior (074);
rendering the deltas ahead of the line diff (095); policies that require
a delta (066); more languages and ecosystems (a later spec per language,
each pinning its grammar).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked
```
