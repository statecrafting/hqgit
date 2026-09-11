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
  - ".githooks/"
  - ".gitattributes"
  - "scripts/spec-dag.sh"
summary: >
  The governed-development loop every human and every driven session runs
  inside: the cross-agent New Sessions protocol and the Working the backlog
  protocol in AGENTS.md, the Claude Code skills (prime, setup, next, build,
  verify, ship, shepherd, spec, and the two the loop calls, commit and
  code-review), the six agents (architect, explorer, implementer, reviewer,
  ledger-guardian, trust-reviewer), the standing and path-scoped rules, the
  read-only hooks that report derived-artifact freshness and block an
  ungated PR, the opt-in merge driver over the committed shard globs, the
  Makefile that is the one source of truth for what CI validates, and the
  CI workflow that re-runs the same gate. The harness is what makes the corpus buildable by
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
`.github/workflows/` that this spec names, `.githooks/` and the
merge-driver stanza of `.gitattributes`, and `scripts/spec-dag.sh`. The
build session for any later spec is granted authority to append a dated
D-n note to this spec when it must adjust a hook or a Makefile target to
make its own territory buildable; it may not change the protocol's
substance without an amendment.

## 3. Behavior

- **B-1 (AGENTS.md is the protocol).** `AGENTS.md` carries a `## New
  Sessions` section that `/prime` executes verbatim, and a `## Working the
  backlog` section that the orchestrator extracts verbatim into every build
  prompt. Both are edited in `AGENTS.md`, never duplicated into a skill.
- **B-2 (the gate is one composite).** The `Makefile` splits the loop the
  way the spec-spine kit does (amended 2026-09-09, D-8). `make gate` is
  read-only throughout: `spec-spine check --fail-on-warn`, `spec-spine lint
  --fail-on-warn`, `spec-spine index coverage`, `spec-spine couple --base
  $(BASE) --head HEAD`, and `scripts/spec-dag.sh` (cycle and
  lower-numbered-dependency check). `make refresh` is the writing half,
  `spec-spine compile` and `spec-spine index`, for a live session that can
  commit the shards it regenerates. `make spine` is `refresh` then `gate`,
  and `make ci` is `spine` plus `cargo build --workspace --locked`, `cargo
  test --workspace --locked`, `cargo clippy --workspace --all-targets
  --locked -- -D warnings`, `cargo fmt --all --check`, and `cargo deny
  check` when `deny.toml` exists. `make verify SPEC=<id>` runs one spec's
  declared acceptance through `spec-spine verify` and sits outside the gate
  chain, because it executes what the corpus declares.

  `BASE` is resolved from the repository rather than assumed to be
  `origin/main`: `$SPEC_SPINE_DEFAULT_BRANCH`, then the remote's own HEAD,
  then `main` (spec-spine 072).

  Every target is guarded so the composite is green on the specify-only
  tree. Two refusals are guarded rather than unconditional, for different
  reasons: `index coverage --fail-on-untraced` runs whenever `Cargo.toml`
  exists, because spec-spine 059 refuses an empty coverage universe rather
  than passing it vacuously (amended 2026-09-09, D-7); `check
  --fail-on-unresolved` sits behind the `UNRESOLVED_GATE` variable and is
  off, because it refuses while any spec declares a file no code has
  created yet, which stays true until the last wave lands (D-8). The bare
  `index coverage` line runs on every tree so the number is always
  reported.
- **B-3 (CI is the same gate).** `.github/workflows/govern.yml` runs on
  pull requests: `spec-spine check --fail-on-warn` (one verb, both
  committed trees, read-only; amended 2026-09-09, D-8), `lint
  --fail-on-warn`, `couple` with the PR body as waiver source, `index
  coverage` as a report, and, when a workspace exists, `index coverage
  --fail-on-untraced` and the cargo gates (amended 2026-09-09, D-7),
  `scripts/spec-dag.sh`, and `spec-spine attest --with-coupling` uploaded
  as a build artifact (the corpus attestation, the repo's own ledger seal).
  It pins `spec-spine` to the version named in `AGENTS.md`, which
  `spec-spine.toml [meta] required_version` also states as a floor the CLI
  checks on every run. `--fail-on-unresolved` is absent for the same reason
  it is off in `make gate`.
- **B-4 (hooks).** `.claude/settings.json` carries the kit's four hooks
  byte for byte, with one sanctioned local edit: the `PostToolUse` glob
  list is tuned to this repository's `[index] extra_hashed_inputs`
  (amended 2026-09-09, D-8). **The hooks read and never write**, with a
  single exception. `SessionStart` reports both freshness verdicts through
  `spec-spine check`. `PostToolUse` on `Edit|Write` recompiles the registry
  after a `specs/*/spec.md` edit, which is the exception, because a live
  session can commit the shards it just staled; after any other
  hashed-input edit it only reports. `PreToolUse` on `Bash` blocks `gh pr
  create` on a non-fresh `check`, on uncommitted `.derived/` shards, or on
  a red coupling gate without an inline `Spec-Drift-Waiver:`, and blocks a
  `git push` that would update the resolved default branch while allowing a
  tag push. `Stop` reports a stale tree and does not regenerate it: a
  session that has ended cannot commit the shards a write would leave
  behind. Every hook resolves the binary as `$SPEC_SPINE_BIN`, then the
  repository's own release build, then `PATH`, and acts on the repository
  the command targets rather than the session's project. Permissions allow
  the read-only git verbs, `cargo`, `rustup`, `make`, and `spec-spine`;
  they deny publishing and destructive `gh` verbs.
- **B-5 (skills).** `.claude/skills/` ships the spec-spine kit's ten,
  byte for byte (amended 2026-09-09, D-8). The governed loop: `/prime`,
  `/setup`, `/next` (the lowest-numbered ready pending spec, computed
  through `spec-spine registry`), `/build <id>` (one spec start to finish:
  branch, flip in-progress, implement, gate, flip complete), `/verify <id>`
  (the spec's declared acceptance through `spec-spine verify`), `/ship`,
  `/shepherd` (watch the PR's checks, remediate, merge when green, confirm
  on disk), `/spec` (author a new spec from the template with the next
  ordinal and a DAG check). The two the loop calls: `/commit` and
  `/code-review`.
- **B-6 (agents).** Four pipeline agents (`architect`, `explorer`,
  `implementer`, `reviewer`) and two domain specialists, both read-only:
  `ledger-guardian` (L0/L1 hash stability, canonical encoding, tombstones)
  and `trust-reviewer` (signatures, key rotation, transparency inclusion,
  Biscuit attenuation, cache-as-trust-boundary, policy determinism).
- **B-7 (rules).** Three standing rules (orchestrator, governed artifact
  reads, adversarial prompt refusal) and four path-scoped rules
  (`ledger-invariants` on the L0/L1 crates, `trust-invariants` on the
  L4/L6 crates and the action cache, `build-commands` on `crates/**`, and
  the kit's `derived-artifacts-are-compiler-output` on `.derived/**`,
  which reinforces the standing read rule at the moment a shard is open
  and never replaces it; amended 2026-09-09, D-8).
- **B-9 (the merge driver).** `.githooks/merge-derived-index.sh` is a git
  merge driver that resolves a conflict in a committed shard by
  regenerating both artifacts from the merged tree, and
  `.gitattributes` binds it to the shard globs. It is **opt-in per clone**:
  nothing happens until `./.githooks/enable-merge-driver.sh` registers it
  in that clone's git config, and it fails closed, leaving the conflict in
  place, when no binary is found or regeneration fails. It never replaces
  the staleness gate, which is what proves the regenerated result is what
  the corpus compiles to (added 2026-09-09, D-8).
- **B-8 (house style).** No em dash anywhere; conventional commits naming
  the spec id (`feat(017): ...`); no AI attribution; no session links in
  commits, PR bodies, or comments. The skills restate these where they
  produce text that lands in git.

## 4. Functional requirements

- **FR-001.** `scripts/spec-dag.sh` reads `spec-spine registry list --json`
  (a typed read), refuses any `depends_on` cycle naming the path, refuses a
  dependency on a higher-numbered spec, and refuses a dependency on an
  unknown id. Exit 0 clean, 1 on a violation, 3 when spec-spine is absent.
- **FR-002.** One spec's declared acceptance runs through `spec-spine
  verify <id>` (spec-spine 049), reached as `make verify SPEC=<id>` or
  `/verify <id>`, and that is the same verb the orchestrator's verify stage
  runs after merge. It executes every non-comment line of every
  ```` ```verify:cli ```` fence from the repository root, in order, stopping
  at the first non-zero exit; `--plan` prints the commands and runs none; a
  spec with no `## Verification` section reports `not-declared` and exits 0,
  which is an honest zero and not a pass. The harness ships no second
  implementation of this protocol (amended 2026-09-09, D-8).
- **FR-003.** Every hook exits 0 when `spec-spine` or `jq` is absent,
  printing what was skipped, so a missing tool never blocks a session.
- **FR-004.** The `PreToolUse` PR gate is read-only: it never writes into
  the repository it is judging. It blocks unless `spec-spine check` answers
  `0`, reading each non-zero code for what it means rather than calling
  every one of them staleness (`2` stale, `1` a corpus that does not
  validate, `3` a read that was not performed, most often a binary
  predating the verb), and it blocks when `.derived/` carries uncommitted
  shards (amended 2026-09-09, D-8).

## 5. Acceptance criteria

- **AC-1.** `make gate` exits 0 on the specify-only tree (zero packages,
  every owning unit `W-001`) and leaves `git status --porcelain` empty,
  because every step of it is read-only. `make ci` exits 0 on the same
  tree.
- **AC-2.** `scripts/spec-dag.sh` exits 0 on this corpus and exits 1 with
  the cycle named on a fixture corpus containing `a -> b -> a`.
- **AC-3.** `spec-spine verify 001-agentic-harness` runs this spec's block
  below and exits 0.
- **AC-4.** Editing `.claude/settings.json` without editing this spec fails
  `spec-spine couple` with `C-001`, and the same holds for `.githooks/` and
  `.gitattributes`.

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
index shards and no registry shard. That restale is the one-time cost of
the change, but it is not by itself evidence of anything: `spec-spine.toml`
is folded whole into the global scalar, so any edit to it restales every
index shard, a comment included. The probe above is the evidence that the
patterns now cover bytes.

The `spec-spine` pin is untouched here. No spec text names the
hashed-input patterns, so this is a choice the corpus was silent on and a
dated decision entry is the right instrument for it. The pin bump is a
separate change, and the coverage step it stumbles on needs an amendment to
B-2 and B-3 rather than an entry like this one.

D-7 (2026-09-09, pin bump and the coverage amendment). The `spec-spine`
pin moves from 0.14.0 to 0.17.0 in every site that states it
(`govern.yml`, `AGENTS.md`, `README.md`, the architect agent). As in D-4
the corpus was verified byte-compatible first: 0.17.0's `compile --check`
and `index check` both report fresh against the shards on `main`, and no
registry shard other than this spec's own changes here. The `L-008`
warnings 0.17.0 reported were the dead globs D-6 already fixed, so `lint
--fail-on-warn` is clean under the new pin without further change.

One gate step could not be: `index coverage --fail-on-untraced` refuses an
empty coverage universe (spec-spine 059) rather than passing it vacuously,
and this corpus has no packages, so under 0.17.0 the step could only
refuse. B-2 and B-3 named the flag unconditionally, so removing it was not
a choice the spec was silent on and a decision entry could not do it. The
maintainer amended B-2 and B-3 directly on 2026-09-09: coverage runs as a
report until the first package carries source files, and as a refusal
from then on, under the same `Cargo.toml` guard the cargo gates already
use. `Makefile` and `govern.yml` apply that guard; the bare `index
coverage` line stays in both so the empty universe is reported on every
run rather than skipped. The flag comes back on its own the day spec 010
lands a workspace, with no further edit to either file.

What the bump buys: `verify` running a spec's declared acceptance (049),
`index diagnostics` for unresolved units (050), `couple` naming the
`extends` crossing that cleared a change (052), the `L-008` lint that
found D-6's dead globs (057), `registry plan` answering blocked as well as
ready (060), `[meta] required_version` so the CLI can check its own floor
(062), and a malformed spec id refused rather than panicking (070). Setting
`required_version` is the obvious follow-on and is its own change.

D-8 (2026-09-09, kit v18 adoption). The `spec-spine` pin moves from 0.17.0
to 0.18.0 and the harness adopts the kit as it ships at that release. The
maintainer amended B-2, B-3, B-4, B-5 and B-7 directly and added B-9,
because each of them named the shape the kit replaced and a decision entry
cannot change what a behavior clause requires; D-7 set that precedent for
the same reason. FR-002 and FR-004 are rewritten for the same cause. What
moved:

- **One freshness verb.** `spec-spine check` (spec-spine 075) replaces the
  `compile --check` plus `index check` pair everywhere: the Makefile, the
  workflow, all four hooks, and the AGENTS.md protocol. It reads both
  committed trees, writes nothing, returns the more severe verdict in the
  order `3`, `1`, `2`, `0`, and reports per tree on its own line, so the
  gate reads the line rather than guessing from the composed code. The PR
  gate now distinguishes those four codes instead of treating every
  non-zero as staleness, which had been sending sessions to regenerate
  shards that were already correct (spec-spine 080).
- **The hooks are the kit's.** D-5 left B-4's hooks in place because
  porting the kit's read-only hooks changes what B-4 requires, and that is
  an amendment for a human to file. This is that amendment. The `Stop` hook
  no longer regenerates a stale index: a session that has ended cannot
  commit the result, and an orchestrator that refuses to start on a dirty
  tree then never starts one. The `PreToolUse` push gate protects the
  branch the repository actually has rather than the literal name `main`
  (spec-spine 072), and matches the push verb anchored rather than as a
  substring, so a command that merely mentions it is no longer refused
  (spec-spine 071). One local edit: the `PostToolUse` glob list is tuned to
  this repository's `[index] extra_hashed_inputs`, which is step 4 of the
  kit's own install instructions. `scripts/**`, `.githooks/**`,
  `.gitattributes` and `.github/dependabot.yml` are the additions over the
  kit's list, and D-6's rule holds: every glob must cover bytes.
- **Ten skills, not fifteen.** The kit cut `/validate-and-fix`,
  `/cleanup`, `/implement-plan`, `/research` and `/refactor-claude-md`
  because nothing in the loop referenced them (spec-spine 081), and `/init`
  is renamed `/prime` so one name serves the protocol and the skill
  (spec-spine 075). The ten remaining are byte-identical to the kit, which
  keeps a future kit update a copy rather than a merge. That is the whole
  value of the arrangement D-5 bought, so the five were dropped rather than
  kept as local forks nobody upstream maintains.
- **`scripts/verify-spec.sh` is deleted.** `spec-spine verify` (0.15.0)
  absorbed it, the kit stopped shipping it once every adopter had upgraded
  (spec-spine 074), and a harness that quietly runs a second implementation
  of one protocol is exactly the drift this corpus exists to refuse. This
  spec's own Verification block and `make verify` now call the verb.
- **Make targets.** `gate` (read-only) and `refresh` (writing) are the
  kit's split, and they are the honest names: the old `make spine` began
  with `compile` and `index`, so the gate repaired what it was meant to
  judge. `spine` and `ci` stay as aliases because spec 000 section 8 and
  spec 003 AC-1 name `make spine` and spec 010 AC-2 names `make ci`;
  renaming them would have edited two specs this change has no authority
  over. `spine` is now `refresh` then `gate`, which is a superset of what
  it ran before.
- **The merge driver is installed dormant.** The kit's own guidance is
  that one spec per pull request against sharded committed trees wants the
  gate and not the driver, which is this repository exactly. It is shipped
  anyway because it costs two files and a `.gitattributes` stanza, does
  nothing in any clone until `enable-merge-driver.sh` is run there, and is
  the answer the day this corpus goes parallel. Its `# Spec:` header names
  this spec rather than the spec-spine ordinal the kit ships.
- **`[meta] required_version = ">=0.18.0"`.** The follow-on D-7 named. The
  CLI now checks its own floor on every run, so a contributor on an older
  binary is told which version to install instead of reading the exit code
  of a verb that binary never had.

What did **not** move, and why. `check --fail-on-unresolved` is in the
kit's `make gate` unconditionally and is off here, behind `UNRESOLVED_GATE`.
It refuses while any spec declares a file no code has created yet: 558
diagnostics today. It is tempting to guard it the way D-7 guarded coverage,
on `Cargo.toml`, and that would be wrong. The two refusals become
satisfiable at different moments. Coverage needs one package carrying
source files, which spec 010 delivers; unresolved needs the corpus to build
everything it claims, which is the end of wave 6. Guarding it on
`Cargo.toml` would turn `make gate` red the day spec 010 lands and stay red
for the rest of the build. The variable is the honest guard, and flipping
it to 1 is a one-line change for whoever closes the last wave.

The pin bump restales every shard: 0.18.0 writes `specVersion 1.2.0` in the
registry shards where 0.17.0 wrote `1.1.0`, and the index shard hashes move
with it. Measured before the change, in a scratch copy: 136 files, one line
each, no other field on any shard differs. Adding `[meta] required_version`
and the two hashed-input globs to `spec-spine.toml` restales the index
again on its own, because the config file is folded whole into the global
scalar (D-6). Both restalings are regenerated and committed here.

D-9 (2026-09-11, kit revision: severity triage in `/shepherd`). The harness
moves from the kit bytes the v18 release carried to the kit as it ships
after spec-spine spec 082. One file changes:
`.claude/skills/shepherd/SKILL.md`. The other nine skills, the four rules
the kit ships, `.mcp.json`, the two merge-driver scripts and the
`.gitattributes` stanza were compared file by file against the kit at that
revision first and are already byte-identical, so this is the copy D-8 said
a kit update would be.

What 082 adds is a classification step ahead of the fix. `/shepherd`
previously treated every red required check as remediable until it was
inside the edit, and stated its one escalation, the coupling gate, at step
2 of the remediation procedure, which is to say after the session had
already committed to fixing. The skill now triages the run log in one pass
before touching the branch and records the class in its report. Four
classes are CRITICAL and consume no remediation round at all: a coupling
refusal whose only remedy is editing a spec the session is not
implementing, or a waiver; a hand-edit to an artefact the path-scoped rule
names, the derived tree included; a dependency cycle, because which edge to
drop is a question about authority; and an ambient input reaching a hashed
path, a determinism job that passes on some platforms included. Each of
those goes to a human with its evidence and a proposed remedy, and the
report's thread line reads `not read` rather than `none`, because the
threads were never fetched and reporting that as an absence of threads is a
claim the run did not make. HIGH, MEDIUM and LOW are fixed worst first
inside the existing two-round bound, with the gate re-run to completion
locally before the push, since the chain hides every finding behind the
link that failed.

This is a decision entry and not an amendment. B-5 requires the ten skills
byte for byte and does not enumerate the steps of any one of them, so
adopting a newer kit revision satisfies what B-5 already says rather than
changing it; D-6 set the precedent for a choice the spec was silent on.
B-5's parenthetical gloss for `/shepherd` stays accurate, and naming the
classification step there would be an amendment to a behavior clause, which
is the maintainer's to file (D-7 and D-8 both say so).

The `spec-spine` pin does not move. Spec 082 is kit text with no CLI
surface, and the spec-spine revision that carries it still reports 0.18.0,
so `[meta] required_version = ">=0.18.0"`, `govern.yml`, `AGENTS.md` and
`README.md` are untouched here.

## Verification

```verify:cli
scripts/spec-dag.sh
spec-spine verify 000-hqgit-bootstrap
make gate
```
