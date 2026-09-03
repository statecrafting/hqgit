---
id: "NNN-slug"                 # MUST equal the directory name; NNN = unique 3-digit ordinal = build order
title: "Short imperative title"
status: draft                  # draft | approved | superseded | retired; only approved specs schedule
kind: kernel                   # constitutional-bootstrap | thesis | governance | kernel | feature | tooling
domain: l1-ledger              # governance | l0-objects | l1-ledger | l2-domain | l3-evaluation | l4-trust | l5-projection | l6-policy | l7-edge
created: "YYYY-MM-DD"
authors: ["Bartek Kus"]
implementation: pending        # pending | in-progress | complete | n-a | deferred
risk: medium                   # low | medium | high | critical (critical = touches hashed bytes or trust decisions)
wave: 1                        # build-order wave, 1..8 (spec 002 §6)
depends_on:
  - "NNN-lower-numbered"       # every dependency is lower-numbered; the graph is a DAG
summary: >
  One short paragraph: what territory this spec claims and why it exists.
# --- typed edges (declare territory + relationships) ---
# establishes:
#   - "crates/hqgit-x/Cargo.toml"                     # a crate-founding spec claims its manifest
#   - "crates/hqgit-x/src/lib.rs"
#   - "crates/hqgit-x/src/thing.rs"                   # every source file, explicitly
#   - "crates/hqgit-x/tests/thing.rs"
#   - "crates/hqgit-x/testdata/thing/"                # fixtures as a subtree
# extends:
#   - { spec: "NNN-founder", unit: "crates/hqgit-x/src/lib.rs", nature: additive }          # re-exports
#   - { spec: "NNN-founder", unit: "crates/hqgit-x/Cargo.toml", nature: additive }           # new deps
#   - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
# constrains:
#   - { flavor: invariant-freeze, unit: "crates/hqgit-types/testdata/vectors/", note: "golden vectors are frozen" }
# references:
#   - { unit: { kind: file, path: "docs/design/00-architecture.md" }, role: context }
---

# NNN: Title

## 1. Purpose

What problem this spec solves, and which thesis section (spec 002) or
constitutional principle it serves. One or two paragraphs.

## 2. Territory

The units this spec claims, in prose (mirrors the frontmatter). Name the
crate, the modules, and the seams it exposes to later specs.

## 3. Behavior

- **B-1 (name).** What the governed code MUST do. Use MUST/SHOULD/MAY.
- **B-2 (name).** ...

## 4. Functional requirements

- **FR-001.** Testable requirement, including the seams (traits, injected
  readers) that keep the core pure and the tests fixture-driven.
- **FR-002.** ...

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-x --locked` passes.
- **AC-2.** A concrete observable outcome against a fixture.

## 6. Out of scope

What this spec deliberately does not cover, and which later spec covers it.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-x --locked
```
