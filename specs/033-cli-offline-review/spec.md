---
id: "033-cli-offline-review"
title: "Offline review from the CLI: changes, revisions, anchored threads, approvals"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "032-cli-skeleton"
  - "031-git-object-bridge"
  - "026-review-threads"
  - "027-attestation-primitive"
establishes:
  - "crates/hqgit-cli/src/cmd_change.rs"
  - "crates/hqgit-cli/src/cmd_review.rs"
  - "crates/hqgit-cli/tests/review.rs"
  - "crates/hqgit-cli/testdata/review/"
extends:
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
  # hqgit-git and hqgit-domain join the CLI's dependencies.
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/Cargo.toml", nature: additive }
summary: >
  The wave 1 milestone (thesis §6, step 1): prove offline review against a
  plain git repository. hq change new opens a Change with a stable id; hq
  change submit snapshots the working tree through the git bridge into a
  Revision whose base is the imported HEAD tree; hq review comment anchors
  a thread to a semantic location that survives rebase; hq review approve
  issues an approval Attestation signed by the local identity; hq review
  show re-anchors every thread against the latest revision and marks what
  moved or was lost. No network, no server, no git ref moves. The evidence
  this produces is what spec 034 verifies, and the transcript it leaves is
  the fixture every later client must reproduce.
---

# 033: Offline review from the CLI

## 1. Purpose

Design §1.1 points 1 and 2: clone the repo, get the argument that produced
it; a change has stable identity with ordered revisions; comments anchor to
semantic locations. This spec makes those three claims usable from a shell
with nothing but a working directory and the local identity. It is the
first place the domain model (024, 025, 026, 027), the bridge (031), and
the repository (021) meet in one user-facing flow, and it defines the
golden transcript that fixes what "offline review works" means.

## 2. Territory

Two new command modules in `crates/hqgit-cli` (`cmd_change.rs`,
`cmd_review.rs`), their integration tests (`tests/review.rs`), and the
fixture and golden transcript under `testdata/review/`. Additively: the
dispatch in `main.rs`, the clap tree in `cli.rs`, and the crate manifest
(gaining `hqgit-git` and `hqgit-domain`). Attestation issuance for
arbitrary predicates and chain verification are spec 034.

## 3. Behavior

- **B-1 (`hq change new`).** `hq change new [--title <text>]` appends a
  `change.opened` fact (024) whose author is the local identity and prints
  `{ "change": <ChangeId>, "title": <text> }`. The title is a derived LWW
  field; `hq change retitle <id> <text>` appends a `change.field_set`.
- **B-2 (`hq change submit`).** `hq change submit <id> [-m <message>]
  [--base <tree-cid>]` snapshots the working tree through spec 031
  `snapshot_worktree`, refuses with exit `1` when the snapshot equals the
  previous revision's tree (`nothing changed since revision N`), takes the
  base from `--base`, else from the git `HEAD` tree when the directory is a
  git worktree, else from the previous revision's tree, and appends a
  `change.revision_submitted` fact producing `Revision { number: N+1, tree,
  base, parent_revision }` with the git commit oid, when present, recorded
  in `extra` under `git.commit`. Output `{ "change", "revision": <RevisionId>,
  "number", "tree", "base" }`.
- **B-3 (`hq change list|show|abandon`).** `list [--state open|merged|
  abandoned|all]` prints one row per change from a `ChangeView` fold
  (024): id, state, title, revision count, open thread count, approval
  count. `show <id>` prints the change, its revisions in order, each
  thread with its current resolution, and every attestation whose subject
  is one of its revisions. `abandon <id>` appends `change.abandoned`.
  Ids accept an unambiguous hex prefix of at least 8 characters.
- **B-4 (`hq review comment`).** `hq review comment <change>
  <path>:<line>[-<line>] -m <body> [--revision N]` resolves the location
  against the named revision's tree (latest by default), computes the
  `Anchor` through spec 025 (`anchor_at` on the parsed file, text fallback
  for unsupported languages, reported as `"anchor_kind": "text"`), stores
  the body as an object (constitution X: content in the store, the fact
  holds a Cid), and appends `review.thread_opened` plus
  `review.comment_posted` (026). Output `{ "thread", "comment", "anchor":
  { "path", "node_path", "kind" } }`.
- **B-5 (`hq review reply|resolve|reopen`).** `reply <thread> -m <body>`
  appends a comment to an existing thread; `resolve <thread>` and `reopen
  <thread>` set the thread's LWW resolution (026). A thread id accepts a
  prefix like a change id.
- **B-6 (`hq review approve`).** `hq review approve <change> [--revision N]
  [--note <text>]` issues an Attestation (027) with predicate
  `hqgit/approval/v1`, subject the RevisionId (latest by default), issuer
  the local principal, claim `{ "change", "revision", "note" }`, signed with
  the local seed, and appends `attestation.issued` referencing it. Approving
  the same revision twice from the same identity is refused with exit `1`.
  An approval is never a comment (026 B-rule); the verb does not accept a
  body.
- **B-7 (`hq review show`).** `hq review show <change> [--revision N]`
  re-resolves every thread's anchor against the named revision's tree
  through spec 025 `resolve` and renders each thread with one of `exact`,
  `moved (confidence)`, `text`, or `lost`, its comments in HLC order, its
  resolution, and, for `lost`, the original path and line so the reviewer
  can find it by hand. JSON mode emits the same as structured data. An
  erased comment body renders `"body": null, "erased": true`.
- **B-8 (offline).** No verb here opens a socket or spawns a process. A
  repository that is not a git worktree still supports every verb; only the
  default base of B-2 changes.
- **B-9 (determinism).** Two runs of the scripted fixture session produce
  ledgers whose `hq log --json` output is identical after masking `hlc`
  fields and the identity-derived ids, which is what the golden transcript
  asserts.

## 4. Functional requirements

- **FR-001.** `testdata/review/fixture.toml` scripts a small Rust and
  TypeScript git repository (built at test time with `gix`, spec 031
  FR-002) and `testdata/review/session.sh` lists the verbs the transcript
  test runs; `testdata/review/transcript.golden.json` is the masked
  expected `hq log --json`.
- **FR-002.** `tests/review.rs` drives the binary through the session and
  asserts: the transcript matches the golden file modulo masks; a second
  `submit` with no working-tree change exits `1`; a comment on a Rust
  function survives a rename of the function above it and a body edit
  below it (`exact`), a deletion yields `lost`, and a `.txt` file yields
  `text`; a duplicate approval exits `1`; `show` after erasing a comment
  body (through spec 020's local capability) renders `erased`.
- **FR-003.** The anchor and approval logic lives in `hqgit-domain`
  (025, 026, 027); the command modules only parse arguments, call domain
  functions, append facts through `Repository::append_fact` (021), and
  format output.
- **FR-004.** Every change, thread, and comment id printed by these verbs
  is the content-derived id of spec 023 `ids.rs`; no counter is minted.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-cli --locked --test review` passes.
- **AC-2.** On the fixture repository, the scripted session (`new`,
  `submit`, `comment`, edit, `submit`, `show`, `approve`) exits 0 at every
  step and the final `show` reports the comment as `exact` on revision 2.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0 with the
  new modules claimed here.

## 6. Out of scope

Arbitrary-predicate attestations and chain verification (034), stacked
changes and interdiff (050), semantic delta views (051), mirrored review
state (040, 041), any remote (093), and merging (076, 092).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-cli --locked --test review
```
