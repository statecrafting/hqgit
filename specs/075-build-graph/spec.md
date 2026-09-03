---
id: "075-build-graph"
title: "Build graph: the hq-build.toml manifest, pinned toolchains, and affected-target selection"
status: approved
kind: "feature"
domain: "l3-evaluation"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 5
depends_on:
  - "070-reapi-types"
establishes:
  - "crates/hqgit-eval/src/graph/mod.rs"
  - "crates/hqgit-eval/src/graph/manifest.rs"
  - "crates/hqgit-eval/src/graph/toolchain.rs"
  - "crates/hqgit-eval/src/graph/affected.rs"
  - "crates/hqgit-eval/tests/graph.rs"
  - "crates/hqgit-eval/testdata/graph/"
extends:
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/src/lib.rs", nature: additive }
  # toml and globset join the crate's dependencies.
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/Cargo.toml", nature: additive }
  # globset is new to the workspace; toml was pinned by 032.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Design doc §1.1 point 4: CI is a pure function of repository state. This
  spec gives that function its argument list. A repository declares its
  targets in hq-build.toml (inputs as globs over the tree, an argv command,
  a pinned toolchain, declared outputs, target dependencies, and the escape
  hatches network and nondeterministic), a toolchain is the content hash of
  a pinned image or a nix-style closure, and a target's identity is a pure
  function of the subtree its globs select. Affected-target selection is a
  comparison of those identities between two tree cids, transitive over
  dependencies, with no execution. Every declaration becomes an action
  platform property (070), so an escape hatch is visible in provenance
  (074) rather than hidden in a script, and a target that declares nothing
  cannot read anything it did not declare in the Trusted tier (073).
---

# 075: Build graph

## 1. Purpose

Thesis §4.4 fixes `eval(repo_state_hash, target, toolchain_hash) ->
output_hash` and thesis §8 names the standing risk: hermetic builds tax
ergonomics, and the escape hatches are where the model leaks, so they must
be attested too. This spec is the manifest that makes `target` and
`toolchain_hash` well-defined, the hermeticity rule that makes the input
hash honest, and the affected-target algorithm the merge queue (076) uses
to know which results it may reuse. It executes nothing.

## 2. Territory

The `graph/` module of `crates/hqgit-eval`: `mod.rs` (the `BuildGraph`
type and the action builder), `manifest.rs` (the `hq-build.toml` grammar,
parser, and validation), `toolchain.rs` (toolchain sources and hashing),
`affected.rs` (target keys and affected selection); `tests/graph.rs`; and
recorded selection vectors under `testdata/graph/`. Additively: the crate
manifest (`toml`, `globset`) and `lib.rs`. Executing an action is 072 and
073; attesting it is 074; deciding to merge on the results is 076.

## 3. Behavior

- **B-1 (manifest location and schema).** The manifest is the file
  `hq-build.toml` at the root of a spec 013 `Tree`. `Manifest::parse(bytes)
  -> Result<Manifest, Error>` returns `Error::Parse` on invalid TOML,
  `Error::Schema` on a `schema` MAJOR other than `1`, and `Error::Config`
  naming the key on any unknown key at any level (no silent extras). The
  grammar, every key listed:

  ```toml
  schema = "1.0.0"                       # required

  [toolchain.<name>]                     # one table per toolchain
  image = "blake3:<64 hex>"              # OCI image digest, or
  closure = "blake3:<64 hex>"            # nix-style closure hash
  reference = "ghcr.io/org/img:tag"      # optional, descriptive only

  [target.<name>]                        # one table per target
  inputs = ["src/**/*.rs", "Cargo.toml"] # globs over the tree, required
  deps = ["other-target"]                # target dependencies, default []
  command = ["cargo", "test", "--locked"]# argv, no shell, required
  env = { RUSTFLAGS = "-D warnings" }    # default {}
  toolchain = "rust"                     # a [toolchain.*] name, required
  outputs = ["target/report.json"]       # declared output paths, default []
  timeout_s = 600                        # default 900, max 86400
  tier = "trusted"                       # "trusted" | "untrusted", default "trusted"
  gate = true                            # participates in merge gating, default true

  [target.<name>.escape]                 # optional; the escape hatches
  network = ["index.crates.io"]          # egress hosts, default []
  nondeterministic = false               # outputs not a pure function, default false
  ```

  Exactly one of `image` and `closure` MUST be present per toolchain.
  Names match `^[a-z][a-z0-9_-]*(/[a-z][a-z0-9_-]*)*$`; `TargetId` (070
  B-5) is the validated target name. Globs use `globset` syntax, are
  relative to the tree root, MUST NOT begin with `/` or contain `..`, and
  the manifest itself is an implicit input of every target. `env` keys
  match `^[A-Z_][A-Z0-9_]*$` and are emitted sorted.
- **B-2 (validation).** `Manifest::validate(&self) -> Result<BuildGraph,
  Error>` returns `Error::Validation` naming the target for: a `deps` entry
  that is not a target, a `toolchain` that is not declared, a dependency
  cycle (the cycle is listed in order), an output path equal to or nested
  inside another target's output path, an `outputs` entry that is absolute
  or contains `..`, and an empty `command`. `BuildGraph { targets:
  BTreeMap<TargetId, Target>, toolchains: BTreeMap<String, Toolchain>,
  order: Vec<TargetId> }` where `order` is the dependency order with ties
  broken by name, so iteration is deterministic.
- **B-3 (toolchain).** `Toolchain { name: String, source: ToolchainSource,
  reference: Option<String> }` with `ToolchainSource` a closed enum `Image
  { digest: Hash } | Closure { hash: Hash }`. `toolchain_hash(&Toolchain)
  -> Hash` is `Hash::of(b"hqgit/v1/toolchain/image" || digest)` or
  `Hash::of(b"hqgit/v1/toolchain/closure" || hash)`; `reference` never
  enters the hash. This hash is the `toolchain` field of 070's
  `ActionInput` and, for an `Image` source, the `rootfs` the Untrusted tier
  (073 B-6) pins.
- **B-4 (input selection).** `select_inputs(tree: &Cid, target: &Target,
  store: &dyn ObjectStore) -> Result<InputSet, Error>` walks the tree (013
  B-3 order), matches every file and symlink path against the target's
  globs, and returns `InputSet { entries: BTreeMap<String, (EntryMode,
  Cid)> }` plus the manifest entry. A glob matching nothing is allowed
  (generated paths may be absent); an `InputSet` that is empty apart from
  the manifest is `Error::Validation`. `input_root(set, store) ->
  Result<Cid, Error>` builds and stores the pruned spec 013 `Tree` holding
  exactly those entries at their original paths, so the input root contains
  nothing the target did not declare. That pruned tree is what 073 B-5
  mounts read-only: hermeticity is a property of the input root, not of
  a sandbox rule.
- **B-5 (target key).** `target_key(tree: &Cid, target: &TargetId, graph:
  &BuildGraph, store) -> Result<Hash, Error>` is `Hash::of(canonical
  DagCbor of { input_root, command, env, toolchain: toolchain_hash, tier,
  escape, timeout_s, deps: [target_key(dep) for dep in deps sorted] })`.
  A dependency's key enters its dependents' keys, so a change anywhere
  upstream changes every downstream key without executing anything.
  `TargetKeys = BTreeMap<TargetId, Hash>` for a whole tree is computed in
  `order` with memoization, in one pass.
- **B-6 (affected).** `affected(old: &Cid, new: &Cid, graph: &BuildGraph,
  store) -> Result<Affected, Error>` returns `Affected { changed:
  BTreeSet<TargetId>, unchanged: BTreeSet<TargetId>, added:
  BTreeSet<TargetId>, removed: BTreeSet<TargetId> }` by comparing
  `TargetKeys` of both trees, where `graph` is parsed from `new`'s manifest
  and `old`'s manifest is parsed separately (a target present in only one
  is `added` or `removed`). A target is `changed` when its key differs;
  because keys are transitive (B-5), no separate closure step exists. The
  function is pure over its arguments and never consults a cache.
- **B-7 (action construction).** `to_action_input(tree: &Cid, target:
  &TargetId, graph, dep_outputs: &BTreeMap<TargetId, Cid>, namespace:
  &Hash, store) -> Result<ActionInput, Error>` builds 070 B-5's
  `ActionInput` with `input_root` = the pruned tree of B-4 plus each
  dependency's output tree grafted at `.hq-deps/<dep name>/` (`dep_outputs`
  MUST cover every dependency; a missing one is `Error::NotFound`),
  `command` from `command`, `env`, and `outputs` (`Command.output_paths`),
  `timeout_s`, `do_not_cache = escape.nondeterministic`, and platform
  properties `hqgit.target`, `hqgit.toolchain`, `hqgit.sandbox-tier`
  (`tier` spelled as 073 B-1), `hqgit.rootfs` (image digest hex, `Image`
  sources only), `hqgit.namespace`, `hqgit.network` (declared hosts joined
  by `,`, present only when non-empty), and `hqgit.nondeterministic`
  (`"true"`, present only when set). A nondeterministic target therefore
  never enters the cache (071 B-7) and is executed on every evaluation;
  every escape hatch is an external parameter of the provenance claim (074
  B-2) by construction.
- **B-8 (tier floor).** `tier` in the manifest is a floor, never a ceiling:
  073 B-2's assignment rule may raise an action to `untrusted` (fork
  origin, agent principal) and nothing in this module may lower it. A
  target declaring `network` non-empty with `tier = "trusted"` is
  `Error::Validation`: the Trusted tier has no network (073 B-5), so the
  declaration would be a lie.
- **B-9 (no ambient input).** No clock, environment, working directory,
  or `HashMap`; the tree is read only through the `ObjectStore` seam.

## 4. Functional requirements

- **FR-001.** `testdata/graph/<case>/` holds `hq-build.toml`, `before/`
  and `after/` directory snapshots, and `expected.json` listing `changed`,
  `unchanged`, `added`, `removed`, and each target's platform properties.
  Cases: a leaf edit affecting one target and its dependents, a
  manifest-only edit affecting every target, a dependency-only change, a
  toolchain digest bump, an added and a removed target, an edit outside
  every glob affecting nothing, and an escape-hatch target.
- **FR-002.** Tests cover: every B-1 parse and B-2 validation refusal with
  the named key or target; `toolchain_hash` vectors for both sources with
  `reference` ignored; `select_inputs` excluding undeclared paths and
  including the manifest; `input_root` reproducing a fixture tree cid;
  `target_key` stability across two computations and sensitivity to each
  field; `affected` against every FR-001 case; `to_action_input` platform
  properties, `do_not_cache` for a nondeterministic target, and the dep
  graft path; the B-8 refusals.
- **FR-003.** Computing `TargetKeys` for a graph of 1,000 targets in a
  chain visits each target once (asserted through a counting store).
- **FR-004.** The module exposes no function that executes a command or
  opens a network connection; `cargo tree -p hqgit-eval` gains only `toml`
  and `globset`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-eval --locked graph` passes, vectors
  included.
- **AC-2.** For every FR-001 case, `affected(before, after)` equals
  `expected.json` and `affected(after, after)` reports everything
  `unchanged`.

## 6. Out of scope

Executing targets (072, 073); the provenance claim the properties land in
(074); the merge queue that consumes `affected` (076); a `hq build` verb
(a later CLI spec); per-language dependency inference (targets declare).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-eval --locked graph
```
