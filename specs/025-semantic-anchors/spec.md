---
id: "025-semantic-anchors"
title: "Semantic anchors: comments that survive rebase by resolving against content"
status: approved
kind: "kernel"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "024-change-and-revision"
establishes:
  - "crates/hqgit-domain/src/anchor.rs"
  - "crates/hqgit-domain/src/syntax/mod.rs"
  - "crates/hqgit-domain/src/syntax/rust.rs"
  - "crates/hqgit-domain/src/syntax/typescript.rs"
  - "crates/hqgit-domain/src/syntax/text.rs"
  - "crates/hqgit-domain/tests/anchor.rs"
  - "crates/hqgit-domain/testdata/anchors/"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Review is anchored to text in every incumbent, which is why a rebase
  orphans every comment. hqgit anchors a location to a syntax node: the
  path, the named-node path from the root, and the BLAKE3 hash of the
  node's content, with a text position as the fallback of last resort.
  Resolution against a new tree answers Exact, Moved (the same content
  elsewhere, rename-tolerant), Text (parsing failed or the language is
  unknown), or Lost, never a silent guess. Rust and TypeScript are the
  first languages, with tree-sitter grammars pinned exact so spans are
  identical across releases; everything else degrades to the text path,
  visibly. This is the primitive spec 026's threads and spec 051's deltas
  build on.
---

# 025: Semantic anchors

## 1. Purpose

Design §1.1 point 2: comments anchor to semantic locations (AST node plus
content hash) so they survive rebase. Thesis §4.3 fixes the shape
`Anchor { path, tree_sitter_node_path, node_content_hash }` with text
position as the fallback only when resolution fails. This spec implements
that shape and the resolution algorithm, and it is honest about the long
tail (thesis §8): a language without a grammar gets the text path and says
so.

## 2. Territory

`anchor.rs` (the `Anchor` type, `anchor_at`, `resolve`, `Resolution`),
the `syntax/` module (language detection, parsing through tree-sitter for
Rust and TypeScript, and the text degrade path), `tests/anchor.rs`, and
the fixture subtree `testdata/anchors/`. Additively: `lib.rs` re-exports,
the crate manifest, and the workspace dependency table (tree-sitter,
tree-sitter-rust, tree-sitter-typescript, each pinned to an exact version).

## 3. Behavior

- **B-1 (`Anchor`).** `Anchor { path: String, node_path: Vec<NodeStep>,
  node_content_hash: Hash, fallback: TextPosition, extra: BTreeMap<String,
  Value> }` with `NodeStep { kind: String, index: u16 }` (the node's
  tree-sitter kind name and its index among the parent's named children)
  and `TextPosition { line: u32, column: u32, context_hash: Hash }` (1-based
  line, 0-based UTF-8 byte column, BLAKE3 of the line's bytes with trailing
  whitespace removed). `path` is repo-relative POSIX. The type derives
  `Canonical` and provides `to_value()` and `from_value(&Value)` for the
  opaque `anchor` field spec 023 reserved on `review.thread_opened`.
- **B-2 (languages).** `syntax::detect(path) -> Language` maps `.rs` to
  `Rust`, `.ts`, `.tsx`, `.mts`, `.cts` to `TypeScript`, and everything
  else to `Text`. `syntax::parse(language, bytes) -> Result<Tree, Error>`
  wraps tree-sitter for the two grammars and returns a line-indexed
  `Tree::Text` for `Text`; a grammar parse that produces an error node
  still returns a tree (tree-sitter is error-tolerant), and `Tree::has_errors()`
  reports it. Grammar crates are pinned exact in `[workspace.dependencies]`
  because a grammar upgrade can move node kinds and spans; bumping one is
  an authoring change to this spec.
- **B-3 (`anchor_at`).** `anchor_at(tree: &Tree, path: &str, range:
  ByteRange) -> Anchor` selects the smallest named node whose byte range
  covers `range`, records its `node_path` from the root (root excluded),
  hashes its exact source bytes into `node_content_hash`, and computes the
  fallback from the range start. On `Tree::Text` the `node_path` is empty
  and `node_content_hash` equals `fallback.context_hash`.
- **B-4 (`resolve`).** `resolve(anchor: &Anchor, tree: &Tree) ->
  Resolution` where `Resolution` is `Exact(ByteRange) | Moved { range:
  ByteRange, confidence: Confidence } | Text(ByteRange) | Lost` and
  `Confidence` is `High | Low`. The algorithm, in order:
  1. Walk `node_path`; if a node is found and its content hash equals
     `node_content_hash`, `Exact`.
  2. Otherwise collect every named node of the last step's `kind` whose
     content hash matches. Exactly one: `Moved` with `High`. Several: the
     one whose `node_path` has the smallest edit distance to the anchor's,
     `Moved` with `Low`; ties break on the earliest byte offset.
  3. Otherwise find lines whose trimmed hash equals
     `fallback.context_hash`, nearest to `fallback.line` first: `Text`.
  4. Otherwise `Lost`.
  On `Tree::Text` the algorithm starts at step 3. `resolve` is a pure
  function of `(anchor, tree)` and is deterministic.
- **B-5 (survival guarantees).** An anchor MUST resolve `Exact` after any
  edit outside the anchored node's bytes (insertions above, sibling
  reorders, whitespace changes elsewhere), and MUST resolve `Moved` after
  the anchored node is moved within the file or its parent is renamed,
  provided its own bytes are unchanged. An edit inside the node degrades
  to `Text` when the anchored line survives and `Lost` otherwise; this is
  the documented limit, not a defect.
- **B-6 (ranges).** `ByteRange { start: u64, end: u64 }` in bytes of the
  file at the tree's revision; a `line_range(tree, range) -> (u32, u32)`
  helper converts for display. No floats anywhere.

## 4. Functional requirements

- **FR-001.** Fixtures under `testdata/anchors/<lang>/<case>/{before,
  after}.<ext>` with a `case.json` naming the anchored range and the
  expected `Resolution` after the edit: rename above, insert above, body
  edit below, node moved, node edited (Text), node deleted (Lost), for
  both Rust and TypeScript; an unknown extension exercising the text path.
- **FR-002.** A test pins the exact versions of the three tree-sitter
  crates and fails if `Cargo.lock` disagrees, so a grammar bump is a
  visible change to this spec's territory.
- **FR-003.** `Anchor` round-trips through `to_value` and `from_value` with
  `extra` preserved; a golden `domain/anchor.json` vector records the
  canonical bytes of one anchor (added to the 011 vector directory through
  spec 023's edge).
- **FR-004.** A property test asserts `resolve(anchor_at(tree, p, r),
  tree)` is `Exact` for every named node of a fixture tree.
- **FR-005.** Parsing never panics on arbitrary bytes; a fuzz-style test
  feeds random byte strings through `parse` for each language.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked anchor` passes with every
  fixture in FR-001.
- **AC-2.** The rename-above fixtures for both languages resolve `Exact`
  and the moved-node fixtures resolve `Moved` with `High`.

## 6. Out of scope

Threads and re-anchoring policy (026); public-API extraction (051); more
languages (a later spec per language, each pinning its grammar); symbol
resolution across files (083).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked anchor
```
