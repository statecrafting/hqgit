---
id: "084-ecosystem-graph"
title: "Ecosystem graph: package dependencies joined to the code graph for downstream impact"
status: approved
kind: "feature"
domain: "l5-projection"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 6
depends_on:
  - "083-code-graph"
  - "075-build-graph"
  - "051-semantic-deltas"
establishes:
  - "crates/hqgit-projection/src/ecosystem/mod.rs"
  - "crates/hqgit-projection/src/ecosystem/deps.rs"
  - "crates/hqgit-projection/src/ecosystem/impact.rs"
  - "crates/hqgit-projection/tests/ecosystem.rs"
  - "crates/hqgit-projection/testdata/ecosystem/"
extends:
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/lib.rs", nature: additive }
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/registry.rs", nature: additive }
  # toml and serde_json (already in the workspace table) join this crate's manifest.
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/Cargo.toml", nature: additive }
summary: >
  The second half of design §1.1 point 6: the package dependency graph,
  read from manifests and lockfiles in each revision tree for Cargo, npm,
  Go, and Python, joined to the code graph (083) through the SCIP package
  coordinates so that "who depends on this package" becomes "which call
  sites in which repositories use the symbols this change removed or
  re-signed". It answers downstream impact for an API-surface delta (051)
  before the API breaks, plans crater-style downstream test runs as data
  the evaluation plane materializes through the build manifest (075), and
  reports usage with honest denominators: how many dependents are known,
  how many are indexed, how many are hit. It shares the 083 file and its
  isolation: non-authoritative, per-namespace rebuildable, integer-only.
---

# 084: Ecosystem graph

## 1. Purpose

Thesis §4.7: the cross-repo code index joined to the package dependency
graph is the one legitimately centralized component, isolated and
non-authoritative. The code graph alone answers "where is this symbol
used" inside repositories that happen to be indexed; the package graph
says which repositories are downstream at all, so a usage count can carry
its denominator instead of implying one. This spec builds the package
side, the join, the impact query, and the run planner, and it keeps the
crate topology intact: `hqgit-projection` does not depend on `hqgit-eval`
(080 FR-005), so runs are planned as data and executed elsewhere.

## 2. Territory

The `ecosystem` module of `hqgit-projection`: `mod.rs` (the projection,
tables, dependents query), `deps.rs` (manifest and lockfile readers per
ecosystem), `impact.rs` (delta to symbols to call sites, usage counts, run
planning), `tests/ecosystem.rs`, and fixtures under `testdata/ecosystem/`.
Additively: the `lib.rs` re-exports, the `register_all` entry, and the
crate manifest (`toml`, `serde_json`). The build manifest format is 075's;
the delta types are 051's; both are read, never redefined.

## 3. Behavior

- **B-1 (ecosystems).** `Ecosystem::{Cargo, Npm, Go, Python}` with the
  SCIP manager tokens it joins on: `cargo`, `npm`, `gomod`, and `pip`
  (aliases `pypi`, `python`). Sources per tree, found by file name at any
  depth except under `node_modules/`, `target/`, `vendor/`, `.git/`, and
  `.hq/`, each file at most 4 MiB:

  | ecosystem | manifests | lockfiles | recorded as `unsupported` |
  |---|---|---|---|
  | Cargo | `Cargo.toml` (workspace members expanded) | `Cargo.lock` | |
  | Npm | `package.json` (workspaces expanded) | `package-lock.json` v2, v3 | `pnpm-lock.yaml`, `yarn.lock` |
  | Go | `go.mod` | `go.sum` | |
  | Python | `pyproject.toml` (`project.dependencies`, `tool.poetry.dependencies`), `requirements*.txt` | `poetry.lock`, `uv.lock` | `Pipfile.lock` |

  An unsupported lockfile is a row, not silence, so a missing resolution
  is visible.
- **B-2 (the projection).** `EcosystemProjection { namespace: Hash }`
  (`NAME = "ecosystem"`, `SCHEMA_VERSION = 1`) stores in the 083
  `SharedStorage` file with checkpoint row `ecosystem@<namespace-hex>`.
  On `change.revision_submitted` it walks the revision's tree from the
  object store and applies B-3 for that tree; on `change.merged` it marks
  the merged revision's tree `head = 1` (the newest such tree by ordinal
  is the namespace's head; before any merge the newest parsed tree is).
  A tree the store does not hold yields `eco_trees.status = 'unavailable'`.
- **B-3 (tables).** `eco_trees(namespace, tree_cid, ordinal INTEGER NOT
  NULL, head INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL CHECK
  (status IN ('parsed','partial','unavailable')), PRIMARY KEY (namespace,
  tree_cid))`; `eco_manifests(namespace, tree_cid, path TEXT, blob_cid
  TEXT NOT NULL, ecosystem TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind
  IN ('manifest','lockfile','unsupported')), status TEXT NOT NULL CHECK
  (status IN ('parsed','malformed','unsupported','erased')), reason TEXT,
  PRIMARY KEY (namespace, tree_cid, path))`; `eco_packages(namespace,
  tree_cid, ecosystem, name TEXT, version TEXT, manifest_path TEXT NOT
  NULL, PRIMARY KEY (namespace, tree_cid, ecosystem, name))`;
  `eco_dependencies(namespace, tree_cid, ecosystem, package TEXT,
  dep_name TEXT, dep_kind TEXT NOT NULL CHECK (dep_kind IN
  ('normal','dev','build','optional')), requirement TEXT NOT NULL,
  resolved TEXT, source TEXT NOT NULL CHECK (source IN
  ('registry','git','path','workspace','unknown')), locked INTEGER NOT
  NULL DEFAULT 0, PRIMARY KEY (namespace, tree_cid, ecosystem, package,
  dep_name, dep_kind))` with an index on `(ecosystem, dep_name)`.
  `deps.rs` exposes one `read_<ecosystem>(files: &[(path, bytes)]) ->
  Result<Parsed { packages, dependencies, manifests }, Error>` per
  ecosystem; a malformed file marks its row `'malformed'` with the parser
  message, the tree `'partial'`, and the fold continues.
- **B-4 (dependents).** `PackageRef { ecosystem, name }`.
  `dependents(store, pkg) -> AsOf<Vec<Dependent { namespace, tree_cid,
  package, dep_kind, requirement, resolved, source }>>` answers over each
  namespace's head tree only, sorted by `(namespace, package, dep_kind)`.
  `packages_of(store, namespace) -> AsOf<Vec<PackageRow>>` lists a head
  tree's packages.
- **B-5 (impact).** `downstream_impact(store, origin: PackageRef, delta:
  &ApiSurfaceDelta) -> AsOf<ImpactReport>`. Each delta item 051 marks
  removed or signature-changed carries a path and an item name; it maps
  to the `code_definitions` rows (083) of the origin namespace's latest
  indexed tree at that path whose `code_symbols.display_name` equals the
  name or whose `descriptors` end in the name followed by `#`, `().`, or
  `.`. Zero matches list the item under `unmapped`; several include all.
  For every dependent of B-4 whose head tree has an ingested 083 index,
  the mapped symbols' `code_references` rows in that namespace and tree
  are its call sites. `ImpactReport { origin, delta_items: u32,
  mapped: Vec<SymbolId>, unmapped: Vec<UnmappedItem { path, name }>,
  dependents: Vec<DependentImpact { namespace, package, tree_cid,
  symbols_used: Vec<SymbolId>, call_sites: Vec<Location> }>,
  denominators: Denominators { known: u32, indexed: u32, impacted: u32 }
  }`, every list sorted, dependents without call sites omitted from
  `dependents` but counted in `known` and `indexed`.
- **B-6 (honest counts).** `usage(store, symbol: &SymbolId) ->
  AsOf<Usage { users: u32, call_sites: u32, of_indexed_dependents: u32,
  of_known_dependents: u32 }>` where `users` counts dependents with at
  least one reference. `Usage::percent_of_indexed(&self) -> Option<u32>`
  is `users * 100 / of_indexed_dependents`, `None` when the denominator is
  zero; there is no float anywhere and no rendering prints a percentage
  without both numbers beside it.
- **B-7 (planning runs).** `plan_downstream_runs(store, objects, report:
  &ImpactReport) -> AsOf<Vec<DownstreamRun { namespace, package,
  tree_cid, targets: Vec<String>, status: Planned | NoManifest |
  NoTestTargets, because: Vec<SymbolId> }>>` reads `hq-build.toml` at the
  dependent's tree root and selects the targets whose `kind = "test"` and
  whose `inputs` globs match at least one call-site path. The reader
  extracts only target names, kinds, and input globs; the manifest's full
  semantics (toolchains, escape hatches, affected selection) stay with
  075, and the consumer (076 or an operator) materializes each run as a
  070 action through 075's manifest module. Sorted by `(namespace,
  package, target)`.
- **B-8 (erasure and idempotence).** `on_tombstone(cid)` deletes the
  packages and dependencies derived from any manifest whose `blob_cid`
  is that cid and marks the row `'erased'`. Every write is an upsert on
  its primary key; a rebuild is byte-identical to the incremental fold.
  No clock, no `HashMap`.

## 4. Functional requirements

- **FR-001.** Fixtures under `testdata/ecosystem/`: `cargo-workspace/`,
  `npm-lock-v3/`, `go-mod/`, `python-pyproject/`, `python-requirements/`,
  `unsupported-pnpm/`, `malformed-cargo/`, each with an `expected.json`
  of rows; and `impact/` pairing 083's `rust-two-crates` indexes with the
  two crates' manifests, a 051 delta fixture removing one function, and
  `expected-impact.json`, `expected-runs.json`, and an `hq-build.toml`
  for the dependent.
- **FR-002.** Tests cover: every parser fixture yields its expected rows;
  a malformed manifest marks `'malformed'` and `'partial'` and the fold
  continues; an unsupported lockfile is a visible row; `dependents`
  across two namespaces uses head trees only and follows a merge;
  `downstream_impact` maps the removed function to the dependent's call
  sites and lists an unmapped item; denominators count a dependent that
  lacks an index as known but not indexed; `percent_of_indexed` on zero
  is `None`; `plan_downstream_runs` selects the test target whose inputs
  match and reports `NoManifest` for a dependent without `hq-build.toml`;
  a tombstoned manifest erases its rows; rebuild equals incremental.
- **FR-003.** The crate manifest gains no dependency outside the
  workspace table, and `hqgit-eval` is not among its dependencies (a test
  reads `Cargo.toml` and asserts it).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-projection --locked ecosystem` passes.
- **AC-2.** On the `impact/` fixture, the report names crate `b` with one
  call site, `denominators = { known: 1, indexed: 1, impacted: 1 }`, and
  the plan names `b`'s test target.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Executing planned runs (076 consumes the plan); proposing codemods to
dependents as changes (a later feature spec over 093); lockfile formats
listed as unsupported in B-1 (each a later additive extension of
`deps.rs`); vulnerability or license data joins (a later spec over the
license and static-finding predicates); serving over the API (093).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-projection --locked ecosystem
```
