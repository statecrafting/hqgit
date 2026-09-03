# CLAUDE.md

Read `AGENTS.md` first: it carries the session protocol (`## New Sessions`)
and the backlog discipline (`## Working the backlog`). This file only holds
what Claude Code needs beyond it.

## What this is

hqgit is a verifiable evidence ledger for software change: a per-repository
DAG of signed, content-addressed objects covering code, collaboration, and
evidence, with everything else (indexes, feeds, queues, dashboards) a
projection rebuildable from zero. The forge, the CI system, and the agent
runtime are three clients of that ledger. Read
`specs/002-platform-thesis/spec.md` for the layer model, the crate topology,
and the build order; `docs/design/00-architecture.md` for the analysis;
`specs/003-chassis-alignment/spec.md` for the boundary with the rahi
chassis, which waves 1 through 5 never touch and wave 6 composes.

The repository is specified before it is built. Every ordinary spec is
`approved` + `implementation: pending`, spec ordinals are the build order,
and code lands one spec per session. Before spec 010 lands there is no
`Cargo.toml`; every Makefile target and CI step is guarded for that.

## Commands

```sh
make spine      # spec-spine compile, index, lint --fail-on-warn, index check, couple, spec-dag
make ci         # make spine + index coverage --fail-on-untraced + the cargo gates (when Cargo.toml exists)
make build      # cargo build --workspace --locked
make test       # cargo test  --workspace --locked
make lint       # cargo clippy --workspace --all-targets --locked -- -D warnings
make fmt        # cargo fmt --all --check
make deny       # cargo deny check (when deny.toml exists)
make fuzz       # short cargo-fuzz smoke of every target under fuzz/ (spec 012)
make coverage   # spec-spine index coverage
make attest     # spec-spine attest --with-coupling -> .derived/attestation/
scripts/verify-spec.sh <id>   # run a spec's verify:cli blocks (what the verify stage runs after merge)
scripts/spec-dag.sh           # depends_on is acyclic and only points to lower-numbered specs

# One crate, one test:
cargo test -p hqgit-ledger --locked --test entry
cargo test -p hqgit-types --locked codec::
```

Exit codes of `spec-spine`: `0` ok, `1` validation failure or drift, `2`
stale, `3` I/O, parse, schema, or config. The `hq` binary (spec 032) adopts
the same four.

## Architecture in one screen

| Layer | Crates | Founding specs |
|---|---|---|
| L0 objects | `hqgit-object`, `hqgit-git` (bridge) | 013, 031 |
| L1 ledger | `hqgit-types` (codec), `hqgit-ledger`, `hqgit-sync` | 011, 017, 110 |
| L2 domain | `hqgit-types` (nouns), `hqgit-domain` | 010, 023 |
| L3 evaluation | `hqgit-eval`, `executor/` (Go) | 070, 073 |
| L4 trust | `hqgit-trust`, `hqgit-agent` | 060, 100 |
| L5 projection | `hqgit-projection` | 080 |
| L6 policy | `hqgit-policy`, `hqgit-policy-sdk` | 065, 066 |
| L7 edge | `hqgit-cli` (`hq`), `hqgit-mirror`, `hqgit-server`, `web/` | 032, 040, 090, 095 |

Dependencies point downward only. `hqgit-cli` and `hqgit-server` embed the
same ledger implementation and never depend on each other.

## Invariants that shape every change

- **Canonical versus derived.** L0 through L4 are canonical; L5 and above
  never write authoritatively. No authoritative row outside the log.
- **Hash stability.** The canonical encoder (spec 011) and entry signing
  bytes (spec 017) are frozen by golden vectors under
  `crates/hqgit-types/testdata/vectors/`. No clock, env read, float, or
  `HashMap` iteration order reaches a hashed byte. A vector change is a
  schema MAJOR and a human decision; never regenerate vectors to make a
  test pass.
- **Facts are immutable.** Only derived state converges (LWW over HLC).
  Sequence CRDTs are for collaborative text only.
- **One evidence primitive.** Everything is an `Attestation`; new evidence
  kinds register a predicate, never a new noun.
- **Erasure by tombstone.** The log holds commitments, never content.
- **Agents are a distinct principal.** `Principal::Agent` carries a
  delegation chain; it never authenticates as a human.
- **Cache is a trust boundary.** Unattested cache hits are misses for
  anything that gates a merge.

## Governance mechanics

- Every source file inside a crate must be specifically claimed by a spec
  (`require_ownership` is on). Add new files to the implementing spec's
  `establishes` in the same change.
- `.derived/` shards are committed; regenerate with `spec-spine compile &&
  spec-spine index` and commit them with the change. `build-meta.json` is
  gitignored.
- Derived artifacts are read only through `spec-spine` subcommands.
- Hooks in `.claude/settings.json` recompile after spec edits, check
  staleness after hashed-input edits, block `gh pr create` on a red
  coupling gate, and block `git push` to `main`.
- The coherence guard: never edit an owning spec to make the gate pass on
  code that contradicts it. Surface the contradiction.

## House style

- No em dash character anywhere (chat, code, comments, specs, commits).
- Conventional commits with the spec id as scope: `feat(017): ...`.
- No AI attribution and no session links in commits, PR bodies, or comments.
- Specs follow `standards/spec/templates/spec-template.md`: Purpose,
  Territory, Behavior (B-n), Functional requirements (FR-nnn), Acceptance
  criteria (AC-n), Out of scope, Resolved decisions (D-n), `## Verification`.
