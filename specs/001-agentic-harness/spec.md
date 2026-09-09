---
id: "001-agentic-harness"
title: "Agentic engineering harness: session protocol, skills, agents, hooks, gate"
status: approved
kind: "governance"
domain: "governance"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: complete
risk: high
wave: 1
depends_on:
  - "000-hqgit-bootstrap"
establishes:
  - "AGENTS.md"
  - "CLAUDE.md"
  - "Makefile"
  - "spec-spine.toml"
  - ".mcp.json"
  - "standards/spec/contract.md"
  - "standards/spec/templates/"
  - ".claude/settings.json"
  - ".claude/agents/"
  - ".claude/rules/"
  - ".claude/skills/"
  - ".github/workflows/govern.yml"
  - ".github/dependabot.yml"
  - "scripts/verify-spec.sh"
  - "scripts/spec-dag.sh"
summary: >
  The governed-development loop every human and every driven session runs
  inside: the cross-agent New Sessions protocol and the Working the backlog
  protocol in AGENTS.md, the Claude Code skills (init, setup, next, build,
  verify, spec, commit, code-review, ship, shepherd, validate-and-fix,
  cleanup, implement-plan, research, refactor-claude-md), the six agents
  (architect, explorer, implementer, reviewer, ledger-guardian,
  trust-reviewer), the standing and path-scoped rules, the hooks that keep
  the derived artifacts fresh and block an ungated PR, the Makefile that is
  the one source of truth for what CI validates, and the CI workflow that
  re-runs the same gate. The harness is what makes the corpus buildable by
  claude-observatory: the orchestrator reads AGENTS.md's backlog section
  into every build prompt, drives the repo's own /ship, watches the CI this
  spec wires, and runs each spec's Verification block after merge.
---

# 001: Agentic engineering harness

## 1. Purpose

The corpus is only as buildable as the loop that builds it. This spec owns
that loop so that a change to how sessions are steered (a skill, a hook, a
rule, the CI gate) is a governed change coupled to a spec, never an
uncommitted habit. Everything here is substrate-level: it references the
`spec-spine` CLI, `cargo`, `gh`, and generic dev verbs, plus hqgit's own
build commands once spec 010 lands.

## 2. Territory

`AGENTS.md` (the cross-agent protocol authority), `CLAUDE.md` (what Claude
Code needs beyond it), `Makefile` (the CI composite), `spec-spine.toml`,
`.mcp.json`, the contract and templates under `standards/spec/` (the
constitution itself is in the bypass floor and is amended only by a spec
that `amends` it), the whole `.claude/` harness, the two workflows under
`.github/workflows/` that this spec names, and the two helper scripts. The
build session for any later spec is granted authority to append a dated
D-n note to this spec when it must adjust a hook or a Makefile target to
make its own territory buildable; it may not change the protocol's
substance without an amendment.

## 3. Behavior

- **B-1 (AGENTS.md is the protocol).** `AGENTS.md` carries a `## New
  Sessions` section that `/init` executes verbatim, and a `## Working the
  backlog` section that the orchestrator extracts verbatim into every build
  prompt. Both are edited in `AGENTS.md`, never duplicated into a skill.
- **B-2 (the gate is one composite).** `make spine` runs `spec-spine
  compile`, `spec-spine index`, `spec-spine lint --fail-on-warn`,
  `spec-spine index check`, `spec-spine couple --base origin/main --head
  HEAD`, and `scripts/spec-dag.sh` (cycle and lower-numbered-dependency
  check). `make ci` runs `make spine`, `spec-spine index coverage
  --fail-on-untraced`, and, whenever `Cargo.toml` exists, `cargo build
  --workspace --locked`, `cargo test --workspace --locked`, `cargo clippy
  --workspace --all-targets --locked -- -D warnings`, `cargo fmt --all
  --check`, and `cargo deny check` when `deny.toml` exists. Every target is
  guarded so the composite is green on the specify-only tree.
- **B-3 (CI is the same gate).** `.github/workflows/govern.yml` runs on
  pull requests: `spec-spine compile --check`, `index check`, `lint
  --fail-on-warn`, `couple` with the PR body as waiver source, `index
  coverage --fail-on-untraced`, the cargo gates when a workspace exists,
  and `spec-spine attest --with-coupling` uploaded as a build artifact (the
  corpus attestation, the repo's own ledger seal). It pins `spec-spine` to
  the version named in `AGENTS.md`.
- **B-4 (hooks).** `.claude/settings.json` wires: `SessionStart` (report
  registry and index freshness), `PostToolUse` on `Edit|Write` (recompile
  after a spec edit; staleness check after any hashed-input edit),
  `PreToolUse` on `Bash` (block `gh pr create` unless the coupling gate is
  green or a `Spec-Drift-Waiver:` is inline in the body; block `git push`
  to the default branch), and `Stop` (auto-regenerate a stale index outside
  a rebase or merge). Permissions allow the read-only git verbs, `cargo`,
  `make`, and `spec-spine`; they deny publishing and destructive `gh`
  verbs.
- **B-5 (skills).** `.claude/skills/` ships fifteen skills. The governed
  loop: `/init`, `/setup`, `/next` (the lowest-numbered ready pending spec,
  computed through `spec-spine registry`), `/build <id>` (one spec start
  to finish: branch, flip in-progress, implement, gate, flip complete),
  `/verify <id>` (run the spec's `verify:cli` blocks locally), `/spec`
  (author a new spec from the template with the next ordinal and a DAG
  check), `/commit`, `/code-review`, `/ship`, `/shepherd` (watch the PR's
  checks, remediate, merge when green, confirm on disk). Supporting:
  `/validate-and-fix`, `/cleanup`, `/implement-plan`, `/research`,
  `/refactor-claude-md`.
- **B-6 (agents).** Four pipeline agents (`architect`, `explorer`,
  `implementer`, `reviewer`) and two domain specialists, both read-only:
  `ledger-guardian` (L0/L1 hash stability, canonical encoding, tombstones)
  and `trust-reviewer` (signatures, key rotation, transparency inclusion,
  Biscuit attenuation, cache-as-trust-boundary, policy determinism).
- **B-7 (rules).** Three standing rules (orchestrator, governed artifact
  reads, adversarial prompt refusal) and three path-scoped rules
  (`ledger-invariants` on the L0/L1 crates, `trust-invariants` on the
  L4/L6 crates and the action cache, `build-commands` on `crates/**`).
- **B-8 (house style).** No em dash anywhere; conventional commits naming
  the spec id (`feat(017): ...`); no AI attribution; no session links in
  commits, PR bodies, or comments. The skills restate these where they
  produce text that lands in git.

## 4. Functional requirements

- **FR-001.** `scripts/spec-dag.sh` reads `spec-spine registry list --json`
  (a typed read), refuses any `depends_on` cycle naming the path, refuses a
  dependency on a higher-numbered spec, and refuses a dependency on an
  unknown id. Exit 0 clean, 1 on a violation, 3 when spec-spine is absent.
- **FR-002.** `scripts/verify-spec.sh <id>` extracts every `verify:cli`
  fenced block from `specs/<id>/spec.md`, runs each non-comment line in
  order from the repo root, prints command and exit code, and exits non-zero
  on the first failure; a spec with no `## Verification` section exits 0
  and prints `not-declared`.
- **FR-003.** Every hook exits 0 when `spec-spine` or `jq` is absent,
  printing what was skipped, so a missing tool never blocks a session.
- **FR-004.** The `PreToolUse` PR gate refreshes the index before coupling
  and blocks when `.derived/` is left uncommitted by that refresh.

## 5. Acceptance criteria

- **AC-1.** `make spine` exits 0 on the specify-only tree (zero packages,
  every owning unit `W-001`).
- **AC-2.** `scripts/spec-dag.sh` exits 0 on this corpus and exits 1 with
  the cycle named on a fixture corpus containing `a -> b -> a`.
- **AC-3.** `scripts/verify-spec.sh 001-agentic-harness` runs this spec's
  block below and exits 0.

## 6. Out of scope

The orchestrator itself (claude-observatory owns its stages); the Rust
toolchain pins and lints (spec 010); language-specific CI beyond the
guarded cargo composite (each crate-founding spec extends the workflow when
it needs a service or a matrix).

## 7. Resolved decisions

D-1 (2026-09-02, authoring). The observatory's build stage runs only the
four spec-spine commands as its post-session gate on a Rust target (its
spec 016 D-10 gates bun commands on a root `tsconfig.json`), so cargo
correctness reaches the pipeline through two doors: `make ci` inside the
session (the backlog protocol requires it before flipping to complete) and
the CI workflow that shepherd watches. This repo therefore never places a
`tsconfig.json` at the root; the review SPA (spec 095) keeps its own under
`web/`.

D-2 (2026-09-02, authoring). The constitution is in spec-spine's bypass
floor and is deliberately not claimed here: it changes only through a spec
that `amends` it, which is the governed path the constitution's own
Amendment section names.

D-3 (2026-09-03, first CI run). B-3's "cargo gates when a workspace
exists" is guarded by an output of the `spine` job, not by `hashFiles` in
a job-level `if`. GitHub allows `hashFiles` only inside a step (a
job-level `if` is evaluated before any checkout), and the workflow fails
at startup with `calling function "hashFiles" is not allowed here`, which
reports as a run with no checks rather than as a failed gate. The `spine`
job probes for `Cargo.toml` and `deny.toml` after its checkout and
publishes `has_cargo` and `has_deny`; the `cargo` and `deny` jobs gate on
those. The guard's meaning is unchanged.

D-4 (2026-09-06, pin bump). The `spec-spine` pin moves from 0.11.0 to
0.14.0 in every site that states it (`govern.yml`, `AGENTS.md`, `README.md`,
`/setup`, the architect agent). The corpus was verified byte-compatible
first: 0.14.0's `compile --check` and `index check` both report fresh
against shards written by 0.11.0. What the bump buys: `registry plan`
(spec-spine 038, which `/next` reimplemented in Python), `--json` verdicts
on the gate verbs (037), `layout.state_dir` (039), the `depends_on` cycle
refusal (033, half of `scripts/spec-dag.sh`), and the lifecycle fixes
(041, 044, 045) this specify-first corpus lives inside. `spec-spine index`
now prints the `W-001` warnings it always recorded; on a corpus with no
code yet that is one line per not-yet-written unit and is the expected
state, not a defect. Follow-ons (add `registry plan` to the init reads,
retire the Python in `/next`, declare `data/` as `state_dir`) are their
own change.

D-5 (2026-09-06, kit adoption). The fifteen skills under `.claude/skills/`
are the spec-spine kit's own (spec-spine spec 048), taken byte for byte,
and the three standing rules are the kit's spec 047 text. The kit moved
every project fact out of the skills into `AGENTS.md` and the path-scoped
rules, which this repository already held (`make spine`, `make ci`, the
0.14.0 pin, the invariants), so nothing was lost in the swap and a future
kit update is a copy. What changed in substance: `/next` wraps
`spec-spine registry plan` and drops the Python readiness script (the D-4
follow-on), `/spec` derives the ordinal from `registry list --ids-only`,
`/code-review` uses `compile --check` so a review never writes, `/commit`
carries the session-link and em-dash bans, and `scripts/verify-spec.sh`
is the kit's copy, which also accepts a numbered `## N. Verification`
heading. `scripts/spec-dag.sh` stays: `compile` now refuses a cycle, but
the lower-numbered-dependency check is this corpus's own rule. B-4's hooks
are unchanged: the kit's hooks now read and never write (spec-spine spec
046), and porting them here changes what B-4 requires of the `PreToolUse`
and `Stop` hooks, which is an amendment for a human to file, not a
mid-build edit.

D-6 (2026-09-09, hashed inputs). Six of the ten `[index]
extra_hashed_inputs` patterns ended in `**`, which enumerates directories
and contributes no bytes to any content hash. `standards/`,
`.github/workflows/`, `.claude/agents/`, `.claude/rules/`,
`.claude/skills/` and `docs/design/` were therefore folded into the global
scalar by nothing at all: an edit to `standards/spec/contract.md`, or to a
standing rule under `.claude/rules/`, staled no shard and passed `index
check` clean. The bare filenames in the same list (`AGENTS.md`,
`CLAUDE.md`, `Makefile`, `.claude/settings.json`) were never affected and
are unchanged. Every glob is rewritten as `**/*`, and `scripts/**/*`,
`.mcp.json` and `.github/dependabot.yml` are added for the four claimed
paths that no pattern covered at all.

Measured with the pinned 0.14.0 binary, which is what CI recomputes
against. Before the change, appending a line to `standards/spec/contract.md`
left `index check` at exit 0; after it, the same edit exits 2. The config
edit on its own moves the global scalar, and regenerating rewrites all 68
index shards and no registry shard. That full restale is the one-time cost
of the patterns finally covering bytes, and it is the evidence the hole was
real rather than cosmetic.

The `spec-spine` pin is untouched here. No spec text names the
hashed-input patterns, so this is a choice the corpus was silent on and a
dated decision entry is the right instrument for it. The pin bump is a
separate change, and the coverage step it stumbles on needs an amendment to
B-2 and B-3 rather than an entry like this one.

## Verification

```verify:cli
scripts/spec-dag.sh
scripts/verify-spec.sh 000-hqgit-bootstrap
make spine
```
