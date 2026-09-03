---
id: "000-hqgit-bootstrap"
title: "Bootstrap spec system for hqgit (specify first, build by spec)"
status: approved
kind: "constitutional-bootstrap"
domain: "governance"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: n-a
risk: critical
wave: 1
origin:
  retroactive: true   # authority held since before the graph existed
unamendable:
  - "markdown-truth-boundary"
  - "json-truth-boundary"
  - "determinism-requirement"
  - "directory-name-equals-id"
  - "typed-authority-graph"
  - "refusal-rule"
  - "canonical-derived-boundary"
  - "facts-immutable"
  - "hash-stability"
  - "single-evidence-primitive"
  - "erasure-by-tombstone"
  - "agent-principal-class"
  - "layer-direction"
summary: >
  Foundational contract for the hqgit corpus. Authored truth lives only in
  markdown with YAML frontmatter; machine-consumable truth about the corpus is
  compiler-emitted JSON read only through spec-spine; every artifact is a
  deterministic function of (config, file contents); and a typed authority
  graph governs who owns what. hqgit is specified in full before a line of it
  is built: the corpus is the design, spec numbers are the build order, and an
  orchestrator drives one spec per fresh session through build, ship,
  shepherd, and verify. This spec also freezes the seven system invariants
  (constitution VI through XIII) that no later spec may amend, because the
  first of them (hash stability of the ledger) is the only mistake the
  project cannot recover from.
---

# 000: Bootstrap spec system for hqgit

This is the spec that defines what a spec *is* for hqgit. It sits at the top
of the constitutional hierarchy (`standards/spec/constitution.md` is
subordinate to it). It was authored by hand on 2026-09-02, before any code
existed, together with the whole corpus it governs; the code is built to
satisfy the corpus, one spec per driven session, and the coupling gate holds
from the first governed commit.

## 1. The authoring / derived boundary

There are exactly two kinds of truth in this repository.

- **Authored truth** lives only in markdown (`specs/NNN-slug/spec.md`,
  `standards/`), with YAML frontmatter. Humans, and agents holding explicit
  authority, write authored truth. *(anchor: `markdown-truth-boundary`)*
- **Machine-consumable truth** about the corpus is emitted only by
  `spec-spine`, as JSON, into `.derived/`. No hand-authored JSON is
  authoritative; compiled JSON is read only through `spec-spine` subcommands,
  never by `jq`, `grep`, or a hand-rolled reader. *(anchor:
  `json-truth-boundary`)*

The derived shard trees are committed. `build-meta.json` (the only wall-clock
artifact) is gitignored.

## 2. Identity: directory name equals id

A spec's directory under `specs/` is named exactly `NNN-slug`; its `id`
equals that name; `NNN` is unique across the corpus. In this corpus `NNN` is
also the build order: a spec's `depends_on` names only lower-numbered specs,
so the orchestrator's "lowest-numbered ready spec" rule reproduces the
thesis's build order (spec 002 §6) without a second scheduling table.
*(anchor: `directory-name-equals-id`)*

## 3. The typed authority graph

Specs declare typed edges (`establishes`, `extends`, `refines`,
`supersedes`, `amends`, `co_authority`, `constrains`, `references`) and the
units they own (`file`, `section`, `symbol`, `directory`, `crate`, `module`).
Authority is derived by walking the graph. `references` is non-owning.
*(anchor: `typed-authority-graph`)*

Corpus rules on top of the grammar:

- A crate-founding spec `establishes` the crate's `Cargo.toml`, `src/lib.rs`,
  and each of its own source files explicitly, plus its `tests/` and
  `testdata/` subtrees.
- A later spec that adds modules to an existing crate `establishes` its own
  files and `extends` the founder's `src/lib.rs` (re-exports) and, when it
  adds a dependency, the founder's `Cargo.toml` and the workspace manifest's
  `workspace.dependencies` section (spec 010).
- `[coupling] require_ownership` is on. Every source file inside a crate MUST
  be specifically claimed. A build session that adds a file adds it to the
  `establishes` list of the spec it is implementing, in the same change.
- The manifest floor (`[package.metadata.spec-spine].spec`) names the
  crate-founding spec and exists for drift, not for coverage.

## 4. Determinism

Every artifact-producing step of the corpus toolchain is a pure function of
`(config, file contents)`. *(anchor: `determinism-requirement`)*

## 5. The refusal rule

If the coupling gate fails because code and its owning spec disagree, no
agent resolves it by editing the spec to match the code it just wrote. The
contradiction is surfaced to a human, or to an agent with explicit authority
recorded in the spec's Territory section. *(anchor: `refusal-rule`)*

## 6. The frozen system invariants

The following invariants of the system hqgit describes are frozen here, at
tier 1, so that no ordinary spec and no amendment to the constitution can
weaken them. Each is stated in full in the constitution; the anchor is the
freeze.

- Canonical state is the signed, content-addressed per-repository DAG (L0
  through L4). Everything else is a rebuildable projection. *(anchor:
  `canonical-derived-boundary`)*
- Facts are immutable and merge by set union; only derived state converges.
  *(anchor: `facts-immutable`)*
- The canonical encoding and the ledger entry hash are frozen from the first
  signed entry; unknown fields are preserved; nothing is reordered inside a
  schema MAJOR; golden vectors are the record. *(anchor: `hash-stability`)*
- All evidence is one `Attestation` primitive. *(anchor:
  `single-evidence-primitive`)*
- The log holds commitments, never content; deletion is a tombstone over a
  commitment, never a rewrite. *(anchor: `erasure-by-tombstone`)*
- Agents are a distinct principal class with a delegation chain in their
  credential. *(anchor: `agent-principal-class`)*
- Layers depend downward only; L5 and above never write authoritatively; the
  CLI and the server share one ledger implementation. *(anchor:
  `layer-direction`)*

## 7. Corpus conventions

- **Frontmatter.** Every ordinary spec carries `kind`, `domain` (its layer),
  `implementation`, `risk`, `authors`, `wave`, and a non-empty `depends_on`.
  `domain` and `kind` are closed enums (`spec-spine.toml`).
- **Body.** Sections in order: Purpose, Territory, Behavior (B-n with
  MUST/SHOULD/MAY), Functional requirements (FR-nnn), Acceptance criteria
  (AC-n), Out of scope, Resolved decisions (D-n), and an unnumbered
  `## Verification` section holding `verify:cli` fenced blocks (one shell
  command per line, run after merge by the verify stage). A spec for code
  with no observable command records that explicitly in Verification rather
  than omitting the section.
- **Decisions.** Where a spec is silent, the build session records a dated
  D-n entry under Resolved decisions (and drops a copy in the orchestrator's
  decision drop-box when driven). Decisions are appended, never rewritten; a
  later decision supersedes by naming the earlier one.
- **Amendments.** A change to a shipped spec's contract is an `## Amendments
  received` entry with a date and provenance, and it invalidates every
  transitive dependent until re-verification (spec 002 §7).
- **Style.** No em dash character anywhere in authored text; conventional
  commit messages referencing the spec id; no AI attribution and no session
  links in anything that lands in git or on GitHub.

## 8. Lifecycle as scheduling

- `status: approved` + `implementation: pending` is a work order.
- `status: draft` is never schedulable and stays visible as a blocker.
  Approval is the operator's act; a machine-authored spec is born draft.
- `implementation: n-a` (this spec, the thesis, the harness) and `complete`
  count as shipped, pinned at the sha256 of the spec's normalized `spec.md`.
- `depends_on` MUST be acyclic. A cycle refuses scheduling for the whole
  corpus; the gate does not catch it, so the `/spec` skill and the
  `spec-dag` check in `make spine` do.

## 9. Bootstrap order

1. This spec, the constitution, the thesis (002), and the harness (001) are
   authored by hand, together with every ordinary spec of the corpus.
2. `spec-spine compile`, `index`, `lint --fail-on-warn`, and `couple` are
   green with zero packages discovered and every owning unit reported as
   `W-001` (declared, not yet built). That is the honest starting state.
3. Spec 010 creates the Cargo workspace and the first crate. From then on
   each driven session implements exactly one spec's territory, and the
   corpus governs the code it produced.
