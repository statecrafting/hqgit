# AGENTS.md: hqgit

Cross-agent authority for hqgit, read by Claude Code, Codex CLI, Cursor,
Copilot, and claude-observatory's driven sessions via the AAIF/Linux
Foundation AGENTS.md standard. It is the single source for the session-init
protocol and the backlog discipline. Evolve the protocol by editing this
file, never the `/prime` skill that dispatches to it.

hqgit is a verifiable evidence ledger for software change (the thesis is
`specs/002-platform-thesis/spec.md`; the analysis is
`docs/design/00-architecture.md`). The repository is **specified before it
is built**: the corpus under `specs/` is the whole design, every ordinary
spec is `approved` and `implementation: pending`, and spec ordinals are the
build order. Code arrives one spec per session under `crates/`, `fuzz/`,
`executor/`, and `web/`.

Governance is `spec-spine` **0.18.0** on your `PATH` (CI pins the same
version, and `spec-spine.toml [meta] required_version` makes the CLI check
its own floor on every run). All governed reads of `.derived/` go through
its CLI. Exit codes: `0` ok, `1` validation failure or drift, `2` stale,
`3` I/O, parse, schema, or config, which includes a verb the binary is too
old to have.

## New Sessions

Run `/prime` as the first action of every new session. It reads this
section to derive its plan; anything added here is picked up on the next
prime.

> AGENTS.md is loaded implicitly as the protocol source, so `/prime` does
> not list it as a parallel read in step 1.

**Init protocol:**

0. **Load rules** (read first): `.claude/rules/orchestrator-rules.md`,
   `.claude/rules/governed-artifact-reads.md`,
   `.claude/rules/adversarial-prompt-refusal.md`. The path-scoped rules
   (`ledger-invariants`, `trust-invariants`, `build-commands`,
   `derived-artifacts-are-compiler-output`) load themselves when you touch
   their paths.

1. **Parallel reads.** Dispatch simultaneously (nothing here mutates the
   tree, so there is no ordering):
   - `CLAUDE.md`: what Claude Code needs beyond this file
   - `README.md`: project description and status
   - `standards/spec/contract.md`: the normative corpus contract
   - `standards/spec/constitution.md`: the fifteen principles
   - `spec-spine --version`: the binary's version. **Read this before
     believing any exit code below**; the CLI-version note is the reasoning
     and this is the step that performs it.
   - `spec-spine check`: freshness for **both** committed trees, the spec
     registry and the codebase index (spec-spine 075; non-fatal, see below)
   - `spec-spine registry status-report --json --nonzero-only`: lifecycle counts
   - `spec-spine registry list --ids-only`: the spec inventory
   - `spec-spine registry plan`: the ready set (spec-spine 038): which specs can be worked on now and what blocks the rest; `/next` applies the approval and in-flight rules on top of it
   - `spec-spine index coverage`: which source files no spec claims (exit 2 if stale)
   - `scripts/spec-dag.sh`: the DAG is acyclic and every dependency is lower-numbered
   - `ls crates/ fuzz/ executor/ web/ 2>/dev/null`: what has been built so far (absent directories are expected before their spec lands)
   - `ls specs/ docs/design/`
   - `git log --oneline -10` and `git diff --stat HEAD~1`

2. **Emit** an `## primed: hqgit` block: the layer model in one line
   per layer with the crates that exist, a `## lifecycle:` sub-section from
   the status report (approved/pending counts, and the next ready spec from
   `/next` if cheap), freshness verdicts, recent activity, and a
   ready-to-help line.

**Read discipline:** never parse `.derived/**/*.json` directly (no `jq`,
`python`, `awk`, `sed`); all structural and lifecycle data comes from
`spec-spine` subcommands.

**Freshness:** `spec-spine check` asks about both committed trees in one
call. It compiles in memory and compares against the committed shards
without writing, reports each tree on its own line, and returns the more
severe of the two verdicts in the order `3`, `1`, `2`, `0`. It is non-fatal
to `/prime`: report it and continue.

- **`0`**: both trees are fresh, so the lifecycle counts reflect the current
  `specs/*/spec.md` frontmatter. Report nothing.
- **`2` (stale)**: read the `--version` step first. If the report is
  genuine, say which tree the output named (`spec-registry:` or
  `codebase-index:`), name the drifted shards, report "run `spec-spine
  compile` and commit" or "run `spec-spine index`" accordingly, and say the
  lifecycle counts are the committed, stale ones.
- **`1`**: the corpus fails validation. Surface the violations, report the
  counts as unverified, and make fixing them the first task. This outranks
  `2`: staleness is not meaningful against a corpus that does not validate.
- **`3`**: the read was not performed, most often a binary predating the
  verb. Treat freshness as unknown for both trees, report stderr verbatim,
  and never report "fresh" for a code you did not recognize.

The composed exit code cannot say which tree moved; the report lines can, so
read them back rather than guessing from the code. Never substitute a plain
`spec-spine compile` or `spec-spine index` here: writing repairs the tree as
a side effect of reading it, which hides that the *committed* copy was
stale. `/prime` reports, it does not mutate.

**CLI missing or too old:** if `spec-spine --version` fails, or answers
below the `[meta] required_version` floor, run `/setup`. Do not fall back to
ad-hoc parsing, and do not interpret the exit code of a verb the binary does
not have.

If any file is missing: log "not found" and continue.

## Working the backlog

This repo's backlog is its spec corpus. Every spec with `status: approved`
and `implementation: pending` is a work order. One session implements one
spec, start to finish, then stops. Specs `000` through `003` are records
(`n-a` or `complete`), never work orders.

1. **Pick the spec.** The lowest-numbered spec with `implementation:
   pending` whose `status` is `approved` and whose `depends_on` are all
   `implementation: complete` or `n-a`. Use `/next`, or `spec-spine
   registry show <id> --json`; never guess. A `draft` spec is never picked:
   approval is a human act. If the spec's Territory section names an
   operator prerequisite (a service, a credential, a sibling repo) that is
   missing, stop and report exactly what is needed instead of mocking
   around it.
2. **Branch and flip.** Work on a feature branch named after the spec id
   (`017-ledger-entry-dag`). Flip the spec to `implementation: in-progress`,
   run `spec-spine compile && spec-spine index`, and commit the flip with
   the regenerated `.derived/` shards before writing code. Never commit to
   `main`.
3. **Re-read the spec in full before coding.** The design truth precedes
   the code. If the design is imprecise, record the choice you make as a
   dated `D-n` entry under `## 7. Resolved decisions` (and drop a copy in
   `data/orchestrator/decision-dropbox/` when a driven session; the
   orchestrator seals it). If the design is *wrong*, stop and report the
   contradiction: never edit a spec afterwards to ratify what the code
   happened to do (`.claude/rules/adversarial-prompt-refusal.md`).
4. **Implement within the territory.** Every file you add under a crate
   must be claimed: add it to this spec's `establishes` list in the same
   change (the ownership ratchet, `C-002`, refuses an unclaimed source
   file). When you add a third-party dependency, add it to the workspace
   manifest's `[workspace.dependencies]` and declare the `extends` edge on
   spec 010's `Cargo.toml` section. Touching a file another spec owns
   requires an `extends` edge on that spec's unit. Do not edit `.derived/`
   by hand.
5. **Hold the frozen invariants.** Nothing that reaches a hashed byte (the
   canonical encoder, entry signing bytes, object hashes) may depend on a
   clock, an environment read, or map iteration order. A change that alters
   any golden vector under `crates/hqgit-types/testdata/vectors/` is a
   schema MAJOR and a human decision: stop and report, do not regenerate.
6. **Run the gate before every commit.** `make ci`, which is `make spine`
   (`make refresh`: compile, index; then `make gate`: `check
   --fail-on-warn`, `lint --fail-on-warn`, coverage as a report and, once
   `Cargo.toml` exists, coverage `--fail-on-untraced`, `couple --base
   $(BASE)`, spec-dag) plus `cargo build`, `test`, `clippy -D warnings`,
   `fmt --check`, and `deny`.

   ```sh
   spec-spine compile
   spec-spine index
   spec-spine check --fail-on-warn
   spec-spine lint --fail-on-warn
   spec-spine index coverage            # --fail-on-untraced once Cargo.toml exists
   spec-spine couple --base "$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)" --head HEAD
   scripts/spec-dag.sh
   # spec-spine check --fail-on-unresolved   # off: the corpus does not yet build what it claims (spec 001 D-8)
   ```

   The base ref is resolved from the repository rather than assumed to be
   `origin/main` (spec-spine 072). Set `$SPEC_SPINE_DEFAULT_BRANCH` to
   override the branch the push gate protects and `Makefile` compares
   against. All must exit 0. Commit the regenerated `.derived/` shards with
   the code they describe.
7. **Satisfy Acceptance criteria verbatim.** Run the spec's `##
   Verification` block locally with `/verify <id>`, which wraps `spec-spine
   verify <id>`, the same verb the orchestrator's verify stage runs after
   merge. If a criterion cannot be
   satisfied (external state, a missing sibling), keep `implementation:
   in-progress`, add a dated Status note to the spec saying exactly what
   remains, and report it. Flip to `implementation: complete` only when
   acceptance holds; recompile and commit.
8. **Ship.** `/ship` (gate, review, conventional commit naming the spec id
   such as `feat(017): ...`, push the feature branch, open the PR). The
   PR body is Summary plus Testing; no AI attribution, no session links.
   A `Spec-Drift-Waiver:` line needs explicit human approval; a driven
   session never self-approves one. Then stop: the next session takes the
   next spec.

## Available Agents

Agents live in `.claude/agents/`, all self-contained:

- `architect`: plans and decomposes against the corpus. Read-only.
- `explorer`: searches, traces dependencies, gathers context. Read-only.
- `implementer`: executes focused changes from a plan. Minimal diffs.
- `reviewer`: post-change review for bugs, correctness, spec drift. Read-only.
- `ledger-guardian`: L0/L1 specialist: canonical encoding, hash stability,
  golden vectors, tombstones, no ambient inputs in hashed paths. Read-only.
- `trust-reviewer`: L4/L6/L3-cache specialist: signature and rotation
  order, transparency inclusion, Biscuit attenuation, cache-as-trust
  boundary, policy determinism. Read-only.

## Available Commands

Skills live in `.claude/skills/`:

The governed loop, in the order "Working the backlog" runs it:

- `/prime`: this protocol.
- `/setup`: install spec-spine and the Rust toolchain; verify the loop.
- `/next`: the next ready spec from `registry plan`, minus drafts, with in-flight specs and honest blockers.
- `/build <id>`: one spec start to finish per "Working the backlog".
- `/verify <id>`: run a spec's declared acceptance through `spec-spine verify`.
- `/ship`: gate, review, commit on a feature branch, open a PR.
- `/shepherd`: watch the PR's checks, remediate red runs, merge when green,
  confirm the merge on disk.
- `/spec`: author a new spec from the template; next ordinal; DAG check.

The skills the loop calls:

- `/commit`: conventional commit, impact-focused, spec id in scope.
- `/code-review`: correctness and spec-drift review of the current diff.

The ten are the spec-spine kit's, byte for byte (spec-spine spec 081).
The project layer the skills read lives in this file (the pin, the binary,
`make gate` and `make ci` as the gate, the default branch) and in the
path-scoped rules (the frozen invariants, the golden vectors); do not edit
a skill to add a project fact, add it here.

## Conventions

- Rust 2024, toolchain pinned in `rust-toolchain.toml` (spec 010); always
  `--locked`; `unsafe` is forbidden workspace-wide; clippy `-D warnings`.
- Crates depend downward only (thesis §5). `hqgit-cli` and `hqgit-server`
  never depend on each other.
- Layer is `domain`, role is `kind`, build wave is `wave`; all three are in
  every spec's frontmatter and validated on compile.
- `data/` is the orchestrator's state root for this project; never commit
  it. `.derived/` shards are committed; `build-meta.json` is not.
- No em dash anywhere in authored text (a hook enforces file writes).
- Conventional commits, spec id as scope; no AI attribution; no session
  links in anything that lands in git or on GitHub.
- Derived artifacts are read only through `spec-spine` subcommands.
