---
id: "040-github-mirror-import"
title: "GitHub mirror import: issues, pull requests, reviews, and checks become quarantined facts"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 2
depends_on:
  - "028-issues-and-derived-state"
  - "026-review-threads"
  - "027-attestation-primitive"
  - "031-git-object-bridge"
establishes:
  - "crates/hqgit-mirror/Cargo.toml"
  - "crates/hqgit-mirror/src/lib.rs"
  - "crates/hqgit-mirror/src/github/mod.rs"
  - "crates/hqgit-mirror/src/github/client.rs"
  - "crates/hqgit-mirror/src/github/import.rs"
  - "crates/hqgit-mirror/src/github/model.rs"
  - "crates/hqgit-mirror/src/quarantine.rs"
  - "crates/hqgit-mirror/src/idmap.rs"
  - "crates/hqgit-mirror/tests/"
  - "crates/hqgit-mirror/testdata/github/"
extends:
  # reqwest (rustls) and serde_json join the shared dependency table.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
  # The mirror.observed variant is filled in with its body schema.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  The wedge in code (thesis D16, constitution XIV): value for users who
  migrate nothing. This spec founds hqgit-mirror and its GitHub import: a
  client seam over the REST API with a recorded-fixture implementation for
  tests, and an importer that turns issues, pull requests, review comments,
  approvals, check conclusions, and commits into facts in the repository's
  quarantine namespace. Pull requests become Changes with one Revision per
  head commit through the git bridge; review comments become threads
  anchored by path and line and then re-anchored semantically; approvals
  and check results become mirror attestations whose claims name the
  external source. An id map makes re-import idempotent. Nothing mirrored
  is trusted: promotion to the main namespace is spec 094's capability
  path.
---

# 040: GitHub mirror import

## 1. Purpose

Design §1.2: federate over existing GitHub repositories and mirror
collaboration state bidirectionally, because the network effect is the
product and migration cost is paid by the wrong party. Import is the half
that turns a user's existing repository into a ledger they can clone
offline (design §1.1 point 1). Everything imported is an observation about
an external system, so it lands quarantined (constitution XV) and is
recorded as evidence with provenance (constitution IX), never as fact the
repository asserts on its own authority.

## 2. Territory

`crates/hqgit-mirror` as founded here: the manifest (depending on
`hqgit-types`, `hqgit-object`, `hqgit-ledger`, `hqgit-domain`, and
`hqgit-git` within the workspace, plus `reqwest` with rustls and
`serde_json`), `lib.rs`, the `github/` module (client seam, wire model,
importer), `quarantine.rs`, `idmap.rs`, the `tests/` subtree, and recorded
fixtures under `testdata/github/`. Export is spec 041; the sync loop and
the CLI verbs are spec 042.

## 3. Behavior

- **B-1 (client seam).** `github/client.rs` declares `trait GitHubClient {
  fn repository(&self, owner, name) -> Result<RepoMeta>; fn issues(&self,
  page: Cursor) -> Result<Page<Issue>>; fn pull_requests(&self, page) ->
  Result<Page<PullRequest>>; fn reviews(&self, pr) -> Result<Vec<Review>>;
  fn review_comments(&self, pr) -> Result<Vec<ReviewComment>>;
  fn check_runs(&self, sha) -> Result<Vec<CheckRun>>; fn commit(&self, sha)
  -> Result<Commit>; fn issue_comments(&self, number) ->
  Result<Vec<IssueComment>> }` over the wire types in `model.rs` (serde
  structs mirroring the REST v3 JSON, unknown fields ignored). `HttpClient`
  implements it with reqwest, a bearer token from the caller, conditional
  requests (`If-None-Match`), and rate-limit headers surfaced as
  `Error::Stale` carrying the reset instant. `FixtureClient` replays
  recorded JSON from `testdata/github/<repo>/` and is the only client tests
  use.
- **B-2 (quarantine target).** `quarantine.rs` resolves the repository's
  quarantine namespace (021) and the `Service` principal the mirror runs as
  (`MirrorPrincipal`, an identity created on first run and recorded by an
  `identity.created` fact with kind `Service`). Every fact the importer
  appends is issued by that principal into that namespace; the importer
  refuses to write to `main` (`Error::Policy`).
- **B-3 (issues).** Each GitHub issue becomes an `issue.opened` fact (028)
  plus one `issue.field_set` per field (title, state, labels, assignee,
  milestone) and one `review.comment_posted` (026, threads without anchors)
  per issue comment, with the comment body stored as an object. A
  `mirror.observed` fact (023, filled here: `{ source: "github", kind,
  external_id, url, etag, observed_at }`) is appended for every imported
  item so the observation itself is a fact.
- **B-4 (pull requests).** Each pull request becomes a `change.opened`
  (024) and, per distinct head commit seen (from the PR's commits list,
  oldest first), one `change.revision_submitted` whose tree is imported
  through spec 031 `import_commit` from a local clone the caller supplies
  (`ImportSource::Clone(path)`), with the head sha in `extra.git.commit`.
  A PR whose commits are not present in the clone is reported, not
  imported (`ImportReport.skipped` with the reason).
- **B-5 (review comments).** Each review comment becomes a thread (026)
  anchored first by `(path, line, side)` as a text anchor (025 fallback),
  then re-anchored semantically against the revision's tree where the
  language is supported; replies join the thread in `in_reply_to` order.
- **B-6 (approvals and checks).** A review with state `APPROVED` becomes an
  Attestation with predicate `hqgit/mirror/v1`, subject the RevisionId of
  the reviewed head, claim `{ "source": "github", "kind": "review",
  "state": "approved", "external_id", "author_login", "url" }`, issued by
  the mirror principal. A check run with a conclusion becomes the same
  predicate with `"kind": "check_run"`, `"name"`, `"conclusion"`,
  `"details_url"`. Neither is an `hqgit/approval/v1`: the mirror observes,
  it does not approve.
- **B-7 (id map).** `idmap.rs` keeps `<repo>/.hq/mirror.redb` with tables
  `external_to_internal` (`(source, kind, external_id) -> id`) and
  `internal_to_external`, plus a `cursors` table (`(source, stream) ->
  Cursor`). `import` consults the map before every append: an item already
  mapped whose `etag` or `updated_at` is unchanged produces no fact; a
  changed item produces only the delta facts (a new `issue.field_set`, a
  new revision). Re-running import on unchanged fixtures appends nothing.
- **B-8 (report).** `import(repo, client, source, since: Option<Cursor>)
  -> Result<ImportReport, Error>` where `ImportReport { imported: BTreeMap<
  String, u32>, skipped: Vec<{ kind, external_id, reason }>, cursor:
  Cursor, rate_limit: Option<{ remaining, reset } > }`; the report is
  serializable and is what spec 042 prints.
- **B-9 (no trust).** Nothing here verifies anything about GitHub's claims;
  the attestations record what was observed and who observed it. Promotion
  out of quarantine (094) and verification (064) are later specs.

## 4. Functional requirements

- **FR-001.** The importer is a function of `(client, repository, id map,
  source)`; `FixtureClient` and a `MemoryStore`-backed repository drive
  every test with no network.
- **FR-002.** Fixtures under `testdata/github/basic/` cover: two issues
  (one with labels and two comments), one pull request with two commits
  and a review comment thread with a reply, one approving review, two
  check runs (success and failure); `testdata/github/updated/` is the same
  repository after one issue retitle and one new commit.
- **FR-003.** Tests cover: every B-3 to B-6 mapping on `basic`; idempotent
  re-import on `basic` appends zero facts; import of `updated` after
  `basic` appends exactly the delta; a PR with a missing commit is skipped
  with reason; a rate-limit response yields `Error::Stale` with the reset
  instant; every appended fact lands in the quarantine namespace and is
  issued by the mirror principal.
- **FR-004.** `reqwest` is built with `rustls-tls` and without the default
  native TLS feature; no crate in this workspace links OpenSSL.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-mirror --locked` passes.
- **AC-2.** After importing `basic`, `hq log --namespace quarantine --json`
  (032) lists the expected fact kinds in HLC order and `hq attest list
  <revision>` (034) shows the mirror attestations.
- **AC-3.** `spec-spine index` discovers `hqgit-mirror` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Export to GitHub (041), the sync loop, cursors across runs, and the CLI
verbs (042), promotion out of quarantine (094), GitLab or Gerrit sources
(later specs following this shape), and any webhook receiver.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-mirror --locked
```
