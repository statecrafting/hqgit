---
id: "041-github-mirror-export"
title: "GitHub mirror export and reconciliation: local facts back to GitHub, loop-safe and idempotent"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 2
depends_on:
  - "040-github-mirror-import"
establishes:
  - "crates/hqgit-mirror/src/github/export.rs"
  - "crates/hqgit-mirror/src/reconcile.rs"
  - "crates/hqgit-mirror/tests/export.rs"
extends:
  - { spec: "040-github-mirror-import", unit: "crates/hqgit-mirror/src/lib.rs", nature: additive }
  # The client seam gains its write methods.
  - { spec: "040-github-mirror-import", unit: "crates/hqgit-mirror/src/github/client.rs", nature: additive }
summary: >
  The other direction of the wedge: comments, thread resolutions,
  approvals, and issue field changes made in the ledger are pushed to
  GitHub through the same client seam, so a reviewer who works offline in
  hq still shows up on the pull request. Reconciliation is ordered by the
  hybrid logical clock, idempotent through the id map, and loop-safe: an
  item the exporter created is recognized by its external id on the next
  import and produces no new fact. Where GitHub and the ledger disagree on
  a derived field, the newer observation wins the field and both sides are
  recorded as facts, so nothing is lost and the disagreement is auditable.
  A dry-run mode prints the plan without writing.
---

# 041: GitHub mirror export and reconciliation

## 1. Purpose

Thesis D16 requires the mirror to be bidirectional: absorption fails if
using hqgit makes a contributor invisible on GitHub. Export closes the loop
without compromising constitution VII: facts remain immutable and derived
state converges by the same last-writer-wins rule the ledger uses
internally, extended to an external system whose clock is only observed.
The design goal is a fixed point: import after export produces nothing
new, and export after import produces nothing new.

## 2. Territory

`github/export.rs` and `reconcile.rs` in `crates/hqgit-mirror`, plus
`tests/export.rs`. Additively: the crate's `lib.rs` re-exports and the
write half of the `GitHubClient` seam in `github/client.rs`. The sync loop
that orders import and export, cursor persistence across runs, and the CLI
are spec 042.

## 3. Behavior

- **B-1 (client writes).** `GitHubClient` gains `fn create_issue_comment(
  &self, number, body) -> Result<ExternalId>; fn create_review_comment(
  &self, pr, commit_sha, path, line, side, body, in_reply_to: Option<
  ExternalId>) -> Result<ExternalId>; fn submit_review(&self, pr,
  commit_sha, event: ReviewEvent { Approve | Comment }, body) ->
  Result<ExternalId>; fn resolve_thread(&self, thread: ExternalId,
  resolved: bool) -> Result<()>; fn update_issue(&self, number, patch:
  IssuePatch { title?, state?, labels?, assignees?, milestone? }) ->
  Result<()>`. `FixtureClient` records every write into an in-memory
  journal the tests inspect and reflects it in subsequent reads, so a
  round trip can be asserted without a network.
- **B-2 (what exports).** Only facts in the `main` namespace issued by a
  non-mirror principal export: `review.comment_posted` (as an issue comment
  or a review comment depending on whether the thread has an anchor),
  `review.thread_resolved` (as a thread resolution), an `hqgit/approval/v1`
  attestation (as an approving review on the matching head sha),
  `issue.field_set` on title, state, labels, assignee, milestone (as an
  issue patch). Quarantined facts never export: exporting an observation
  back to its source would be a loop by construction.
- **B-3 (ordering and idempotency).** `plan_export(repo, idmap) ->
  ExportPlan` selects unexported facts (no `internal_to_external` mapping)
  in spec 018 total order and produces `Vec<ExportItem>`; `apply(plan,
  client, idmap) -> ExportReport` performs each item, records the returned
  external id in the map in the same transaction as the write's local
  acknowledgement, and continues past a failed item, listing it. Re-running
  `plan_export` after a complete `apply` yields an empty plan.
- **B-4 (loop safety).** Every export records the external id; on the next
  import (040) an item whose external id is mapped to a local fact produces
  no new fact and no new `mirror.observed`. The exporter also stamps the
  comment body with a trailing invisible marker line `<!-- hqgit:<fact-hash-prefix> -->`
  so a lost id map can still recognize its own writes (`recognize_own(body)
  -> Option<Hash>`), which import consults before mapping lookup.
- **B-5 (conflict rule).** `reconcile.rs` compares, per derived field, the
  ledger's `LwwRegister` (019) with the observed GitHub value and its
  `updated_at`: when GitHub's observation is newer than the ledger's write,
  the importer appends an `issue.field_set` from the mirror principal (so
  the ledger converges to GitHub) and the exporter does not push the older
  local value; when the ledger's write is newer, export pushes it. Both
  values remain in the ledger as facts; `reconcile_report(repo) ->
  Vec<Disagreement { field, local, remote, winner }>` lists every
  disagreement seen in the last run. Time comparison uses the HLC wall
  component against GitHub's timestamp converted to milliseconds; a tie
  goes to the ledger.
- **B-6 (dry run).** `apply(plan, client, idmap)` with `DryRun` performs no
  write and returns the plan rendered as `ExportReport { would: Vec<
  ExportItem> }`; spec 042 exposes it as `--dry-run`.
- **B-7 (bodies and erasure).** Comment bodies are read from the object
  store at export time; an erased body (020) is never exported, and a
  previously exported comment whose body is later erased is edited on
  GitHub to the text `[erased]` through `update_issue_comment` (added to
  the seam) when the token permits, else reported.

## 4. Functional requirements

- **FR-001.** `tests/export.rs` covers: each B-2 mapping through the
  `FixtureClient` journal; quarantined facts never export; export then
  import is a fixed point (zero new facts, zero new writes); a plan
  re-planned after apply is empty; a failed write is reported and the rest
  proceed; own-write recognition by the marker line when the id map is
  wiped; the B-5 conflict rule in both directions and on a tie; dry run
  writes nothing; an erased body is replaced on GitHub.
- **FR-002.** `plan_export` and `reconcile` are pure over `(fold state,
  id map snapshot, observations)`; the client and the map are injected.
- **FR-003.** Export never issues an `hqgit/approval/v1` attestation and
  never writes to a namespace; it only calls the client and the id map.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-mirror --locked --test export` passes.
- **AC-2.** On the spec 040 `basic` fixture, after importing and then
  appending a local comment and an approval, `apply` writes exactly two
  items and a subsequent import appends zero facts.

## 6. Out of scope

The sync loop, cursor persistence, backoff, and the CLI (042); promotion of
mirrored facts (094); exporting changes as new pull requests (a later spec
once the git endpoint, 092, exists); any source other than GitHub.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-mirror --locked --test export
```
