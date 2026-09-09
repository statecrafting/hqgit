# hqgit

**A verifiable evidence ledger for software change.**

Canonical state is a per-repository DAG of signed, content-addressed objects
covering code, collaboration, and evidence. Everything else (indexes, feeds,
queues, dashboards) is a projection rebuildable from zero. The forge is one
client of that ledger, the CI system is another, and the agent runtime is a
third. The wedge is absorption, not replacement: hqgit builds the
verification and review plane over existing GitHub repositories and lets
hosting commoditize underneath.

## Status: specified, not yet built

This repository is a complete specification corpus and the harness that
builds it. There is no code under `crates/` yet. Every ordinary spec is
`status: approved` and `implementation: pending`; spec ordinals are the
build order; and each spec is bounded to one driven session's territory.
The corpus is designed to be built by
[claude-observatory](https://github.com/bartekus/claude-observatory), which
schedules the lowest-numbered ready spec, drives one fresh Claude Code
session through `AGENTS.md`'s backlog protocol, ships through this repo's
own `/ship` skill and hooks, shepherds the PR through the CI wired here, and
runs the spec's `## Verification` block after merge. Done is never
self-authored.

## Reading the corpus

| Start here | What it is |
|---|---|
| `specs/002-platform-thesis/spec.md` | the layer model, the nouns, the crate topology, the eight-wave build order |
| `specs/003-chassis-alignment/spec.md` | the boundary with the rahi chassis: chassis-free through wave 5, composed at wave 6 |
| `docs/design/00-architecture.md` | the analysis the thesis is derived from |
| `docs/design/01-build-order.md` | the spec DAG, rendered |
| `standards/spec/constitution.md` | the fifteen principles, seven of them frozen at tier 1 |
| `specs/000-hqgit-bootstrap/spec.md` | what a spec is, and the frozen invariants |
| `AGENTS.md` | the session protocol and the backlog discipline |

The layer model:

```
L7  Edge:        git-compat endpoint, gRPC/Connect API, sync protocol, UI, agents
L6  Policy:      merge predicates as versioned WASM modules
L5  Projection:  code graph, search, ecosystem graph, feeds   [disposable]
L4  Trust:       identities, key rotation, attestation verify, transparency log
L3  Evaluation:  hermetic build/test graph, remote execution, action cache
L2  Domain:      Change, Revision, Anchor, Review, Attestation, Policy
L1  Ledger:      per-repo signed hash-linked event DAG + convergent state
L0  Objects:     content-addressed blob/tree store (BLAKE3), chunked
```

Rust for the trusted core; Go only at the executor seam; TypeScript for the
review UI. Sixty-four ordinary specs across eight waves; hash stability of
the ledger (specs 011, 012, 017) comes first because it is the only mistake
the project cannot recover from.

## Governance

The corpus is governed by [spec-spine](https://github.com/statecrafting/spec-spine)
0.17.0. `make spine` runs the gate (compile, index, lint, index check,
couple, DAG check); `make ci` adds ownership coverage and the cargo gates
once a workspace exists. Derived artifacts under `.derived/` are committed
and read only through `spec-spine` subcommands. Every source file inside a
crate must be specifically claimed by a spec; a session that adds a file
claims it in the spec it is implementing.

```sh
cargo install spec-spine-cli --locked   # or: npm i -g spec-spine@0.17.0
make spine
spec-spine registry list
scripts/spec-dag.sh
```

## Building it with claude-observatory

```sh
cd ../claude-observatory
bun src/index.ts orchestrator projects add /path/to/hqgit   # registers, qualifies, arms
bun src/index.ts orchestrator dag                            # the readiness view
bun src/index.ts orchestrator next                           # 010-workspace-and-core-types
bun src/index.ts orchestrator daemon start
```

The orchestrator's state root for this project lives under `data/`, which
is gitignored. Any spec can be pulled back to `status: draft` to hold it for
human review; drafts are visible as blockers and never scheduled.

## License

AGPL-3.0, see `LICENSE`.
