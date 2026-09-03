---
id: "092-git-endpoint"
title: "Git smart HTTP endpoint: refs as a projection of changes, push as revision submission, gated main"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 6
depends_on:
  - "090-server-skeleton"
  - "031-git-object-bridge"
  - "024-change-and-revision"
  - "068-policy-in-repo"
establishes:
  - "crates/hqgit-server/src/git/mod.rs"
  - "crates/hqgit-server/src/git/refs.rs"
  - "crates/hqgit-server/src/git/upload_pack.rs"
  - "crates/hqgit-server/src/git/receive_pack.rs"
  - "crates/hqgit-server/src/git/gate.rs"
  - "crates/hqgit-server/tests/git_endpoint.rs"
extends:
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/lib.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/app.rs", nature: additive }
  # hqgit-git, hqgit-policy, and flate2 join the server's dependencies.
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/Cargo.toml", nature: additive }
summary: >
  Git compatibility is a hard requirement (constitution XIV), so the
  server speaks the git smart HTTP protocol without becoming a git host:
  refs are computed from the ledger, packs are built from the object
  store through the spec 031 bridge, and a push is a revision submission
  rather than a pointer move. Each open change exposes refs/changes/<id>/
  <n>; main is the merged lineage rendered as deterministic commits; a
  push to a change ref imports the tree and appends
  change.revision_submitted; a push to main is accepted only when a
  policy-eval attestation with an Allow verdict exists for that revision
  under the policy pinned in the repository, and then appends
  change.merged. Every fact lands where the namespace router says
  (quarantine for unverified pushers), the endpoint never spawns git,
  and the tests drive a real git client against the ephemeral server.
---

# 092: Git smart HTTP endpoint

## 1. Purpose

Design §1.1 point 2: the mutable branch pointer is the wrong unit of
change, but every developer's tools speak git. This spec makes the hosted
ledger reachable from `git clone` and `git push` by translating at the
boundary: what git calls a ref is a view over Changes and Revisions
(024), what git calls a push is a fact append, and what git calls a merge
is a verdict already recorded as evidence (067, 068; constitution XI). No
branch pointer is stored anywhere; the refs advertised are a projection
and can be recomputed from zero (constitution VI).

## 2. Territory

The `git` module of `hqgit-server`: `mod.rs` (routes, content types,
the per-repo git object database), `refs.rs` (the ref projection and
synthetic commits), `upload_pack.rs` (protocol v2 `ls-refs` and
`fetch`), `receive_pack.rs` (pack ingestion and per-ref commands),
`gate.rs` (the pure merge gate), and `tests/git_endpoint.rs`. Additively:
the router mount in `app.rs`, `lib.rs`, and the manifest (090). The bridge
itself is 031; the merge queue that merges through evaluation is 076.

## 3. Behavior

- **B-1 (routes).** `GET /{ns}.git/info/refs?service=git-upload-pack|
  git-receive-pack`, `POST /{ns}.git/git-upload-pack`, `POST /{ns}.git/
  git-receive-pack`, where `{ns}` is the 64-hex namespace of a hosted
  repository (090 B-3); any other `{ns}` is `404`. Content types follow
  the smart HTTP protocol (`application/x-git-<service>-advertisement`,
  `-request`, `-result`); gzip request bodies are accepted. Upload-pack
  honors `Git-Protocol: version=2` and serves v2 only (a v0 fetch is
  answered `400` with the header named); receive-pack speaks v1 with
  capabilities `report-status`, `side-band-64k`, `ofs-delta`, `quiet`.
- **B-2 (git odb is a cache).** Each hosted repository keeps a bare gix
  object database at `<data>/repos/<ns>/git/objects` populated on demand
  by 031 `export_tree` and the synthetic commits of B-3, with the 031
  `GitMap` at `<data>/repos/<ns>/.hq/gitmap.redb`. Deleting the directory
  costs a re-export, never correctness; nothing in it is authority.
- **B-3 (refs are a projection).** `refs.rs` computes, from the 024
  `ChangeView` fold of the namespace the caller may read (main, plus
  quarantine for a caller the router of 094 admits): `refs/changes/<change-
  id-hex>/<n>` for every revision `n` of every open change, and
  `refs/heads/main` as the merged lineage: one synthetic commit per
  `change.merged` in total order (018), each with tree `export_tree(
  revision.tree)`, parent the previous merged commit, author `<display>
  <<principal-hex>@hqgit>` from the submitting principal, committer the
  server identity (090 B-4), both timestamps the fact's `hlc.wall_ms` in
  UTC, and message the revision message plus a trailer `Hqgit-Revision:
  <id>`. When the revision's `extra["git.commit"]` names a commit whose
  object the odb holds, that commit is advertised instead, so a tree that
  entered through git keeps its oid. Two requests against an unchanged
  ledger advertise byte-identical ref lists. `HEAD` is a symref to
  `refs/heads/main`, absent until the first merge.
- **B-4 (upload-pack).** `ls-refs` (with `ref-prefix` and `symrefs`) and
  `fetch` (with `want`, `have`, `done`, `thin-pack` off, `ofs-delta`) are
  served by gix's pack generation over the odb; a `want` outside the
  advertised set is refused per protocol. Reads are allowed for
  `CallerTrust::Anonymous` only when the config `anonymous_read` (090 B-1)
  is true; otherwise `401` with `WWW-Authenticate: Bearer`.
- **B-5 (receive-pack).** The pack is indexed into the odb through gix
  (thin packs resolved against the odb; a missing base is `ng` for every
  ref in the command list); packs above `[git] max_pack_bytes` (default
  512 MiB) are `413`. Commands are handled independently, each with its
  own `ok <ref>` or `ng <ref> <reason>` in `report-status`: a push to
  `refs/for/<change-id-hex>` or `refs/changes/<change-id-hex>/new` imports
  the commit through 031 `import_commit` and appends
  `change.revision_submitted` (024 B-3 `submit_revision`) with `extra
  ["git.commit"]`, `extra["via"] = "git-receive-pack"`, and `extra
  ["on_behalf_of"]` the caller principal, signed by the server identity
  (090 B-4) into the namespace the router returns (090 B-6); a push to
  `refs/for/main` with no change id opens a change (`change.opened`,
  title the first line of the commit message) and submits revision 1; a
  push to `refs/heads/main` runs B-6; a delete command, a tag, or any other
  ref is `ng <ref> unsupported`. Non-fast-forward is not a concept here: a
  forced push to a change ref is the next revision (design §1.1 point 2)
  and nothing is destroyed. A pusher without a principal is `401`.
- **B-6 (the gate).** `gate.rs`: `fn gate(revision: &Revision, active:
  &Cid, attestations: &[Attestation]) -> GateVerdict` is pure. It finds an
  attestation with predicate `hqgit/policy-eval/v1` (067), subject the
  `RevisionId`, claim `policy == active`, and verdict `Allow`, returning
  `GateVerdict::Allow { attestation: AttestationId }`; otherwise
  `Deny(GateReason::NoVerdict | PolicyMismatch { found: Cid } |
  Denied(reasons) | SubjectMismatch)`. `receive_pack` resolves the pushed
  commit to a revision through the `GitMap` (tree cid) and the
  `ChangeView`, takes `active` from 068 `active_policy(repo, revision.at,
  main)`, passes only attestations whose signature verifies through the
  repository's resolver, and on `Allow` appends `change.merged` (024
  `mark_merged`) in main, then answers `ok refs/heads/main`. Any `Deny`
  answers `ng refs/heads/main policy: <reason>`. The endpoint never
  evaluates a policy itself (constitution XI): the verdict is evidence it
  reads. A repository with no pinned policy denies with `NoVerdict`.
- **B-7 (no shelling out, no ambient input).** The module never spawns
  `git`; every pack, tree, and ignore decision goes through gix and 031.
  Commit timestamps come from ledger `Hlc` values, never the wall clock.

## 4. Functional requirements

- **FR-001.** `tests/git_endpoint.rs` skips (printing `git absent`) when
  no `git` binary is on `PATH`; otherwise it drives the real client
  against 090's `TestServer` with `LocalControlPlane` (091) and a
  `StaticTokenAuthenticator`, covering: clone of a fresh repository
  yields no refs; push to `refs/for/main` creates a change and revision 1
  visible in the `ChangeView`; a second push of an amended commit to
  `refs/changes/<id>/new` yields revision 2 and both refs advertise; push
  to `refs/heads/main` without a verdict is `ng ... NoVerdict`; after a
  fixture `policy.pinned` fact (068) and a signed `hqgit/policy-eval/v1`
  Allow attestation for revision 2, the push is `ok` and `change.merged`
  appears in main; a clone after the merge checks out a tree byte-
  identical to the pushed one; an Allow verdict for a different policy
  cid is `PolicyMismatch`; a Deny verdict lists its reasons; an anonymous
  push is `401`; an anonymous clone with `anonymous_read = false` is
  `401`; a pack over the cap is `413`; two `info/refs` responses are
  byte-identical; an unverified pusher's facts carry the quarantine tag
  (021 B-6) while a `Verified` pusher's land in main.
- **FR-002.** `gate` has unit tests for every `GateReason` with no server.
- **FR-003.** Deleting `<data>/repos/<ns>/git/` and cloning again
  reproduces the same ref list and tree oids.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-server --locked git_endpoint` passes
  (or skips with `git absent`).
- **AC-2.** `git clone http://<addr>/<ns>.git` followed by `git push origin
  HEAD:refs/for/main` prints `ok` in report-status and `hq change list`
  (033) on the server's repository directory shows the change.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

SSH transport, protocol v0 and v1 fetch, LFS endpoints (chunked blobs are
already the general path, 014), tags, merge through speculative
evaluation (076), capability-checked routing and quarantine limits (094),
and credential validation (061, 102).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-server --locked git_endpoint
cargo test -p hqgit-server --locked
```
