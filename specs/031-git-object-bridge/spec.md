---
id: "031-git-object-bridge"
title: "Git object bridge: gix import and export, the bidirectional oid map, worktree snapshots"
status: approved
kind: "kernel"
domain: "l0-objects"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "014-content-defined-chunking"
establishes:
  - "crates/hqgit-git/Cargo.toml"
  - "crates/hqgit-git/src/lib.rs"
  - "crates/hqgit-git/src/import.rs"
  - "crates/hqgit-git/src/export.rs"
  - "crates/hqgit-git/src/mapping.rs"
  - "crates/hqgit-git/src/worktree.rs"
  - "crates/hqgit-git/src/mode.rs"
  - "crates/hqgit-git/tests/"
  - "crates/hqgit-git/testdata/"
extends:
  # gix (gitoxide) joins the shared dependency table; never libgit2 (thesis D3).
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Git compatibility is a hard requirement of the wedge (thesis D16), so the
  object store must speak git without becoming git. This spec founds
  hqgit-git, the pure-Rust bridge over gix: import a git commit's tree and
  blobs into hqgit objects (blobs through the chunking path so large files
  are the general case), export an hqgit tree back as git objects, keep a
  bidirectional oid map for both SHA-1 and SHA-256 repositories, and
  snapshot a working tree into a tree Cid without touching git's index. Git
  commits are not hqgit objects: a Revision references a tree, and the git
  commit oid rides along as provenance. Everything here is deterministic,
  never shells out, and never writes a git ref.
---

# 031: Git object bridge

## 1. Purpose

Thesis §4.1 and D3: git compatibility through `gix`, never libgit2, because
the trusted core admits no C boundary. Thesis D16 makes the bridge the
first user-facing seam: the CLI (033) reviews a plain git repository by
snapshotting its working tree, and the mirror (040) imports pull-request
heads by commit oid. Both need one mapping between git's object identity
(SHA-1 or SHA-256 over git's own framing) and hqgit's (BLAKE3 over
canonical objects), maintained in both directions so a tree can round trip
without loss.

## 2. Territory

`crates/hqgit-git` as founded here: the manifest (depending on
`hqgit-types` and `hqgit-object` within the workspace, plus `gix` and
`redb`), `lib.rs`, `import.rs` (git to hqgit), `export.rs` (hqgit to git),
`mapping.rs` (the persisted oid map), `worktree.rs` (snapshots), `mode.rs`
(the mode translation table), and the `tests/` and `testdata/` subtrees.
The git smart protocol endpoint is spec 092; the mirror is spec 040; the
CLI verbs are spec 033.

## 3. Behavior

- **B-1 (modes).** `mode.rs` defines `EntryMode { Regular, Executable,
  Symlink, Submodule, Directory }` and the bijection to git's `100644`,
  `100755`, `120000`, `160000`, `040000`. `Tree` entries (013) carry the
  `EntryMode`; a git mode outside the five is `Error::Validation` naming
  the path. Submodules import as a `Submodule` entry whose target is the
  recorded commit oid as opaque bytes; nothing is fetched.
- **B-2 (import).** `import_tree(repo: &gix::Repository, tree_oid, store:
  &dyn ObjectStore, map: &mut GitMap) -> Result<Cid, Error>` walks the git
  tree depth first in git's byte order, imports every blob through spec
  014's `put_blob` (so blobs above one chunk become manifests), builds 013
  `Tree` objects bottom up, and records every `(git oid, Cid)` pair in the
  map. A blob already present in the map is not re-read. `import_commit(
  repo, commit_oid, store, map) -> Result<ImportedCommit, Error>` imports
  the commit's tree and returns `ImportedCommit { tree: Cid, commit_oid:
  GitOid, parents: Vec<GitOid>, author, committer, message }` so the caller
  (024 via 033 or 040) can record the commit oid in a revision's `extra`
  under the key `git.commit` as provenance. Commits are never stored as
  hqgit objects.
- **B-3 (export).** `export_tree(cid, store, repo: &gix::Repository, map:
  &mut GitMap) -> Result<GitOid, Error>` writes an hqgit tree and its blobs
  into the git object database (chunked blobs are reassembled through 014
  `get_blob`), producing byte-identical git objects for a tree that was
  imported from git (round-trip property). Export writes objects only; it
  never moves a ref.
- **B-4 (mapping).** `GitOid { format: GitHashFormat { Sha1 | Sha256 },
  bytes: Vec<u8> }`. `GitMap` is a redb database at `<repo>/.hq/gitmap.redb`
  with two tables, `git_to_hq` and `hq_to_git`, both written in one
  transaction; `lookup_git(oid) -> Option<Cid>`, `lookup_hq(cid) ->
  Option<Vec<GitOid>>` (one Cid may correspond to a SHA-1 and a SHA-256
  oid), `record(oid, cid)`. The map is a cache: losing it costs a re-import,
  never correctness, because both identities are content-derived.
- **B-5 (worktree snapshot).** `snapshot_worktree(root: &Path, store,
  map) -> Result<Snapshot, Error>` walks a working directory honoring
  `.gitignore`, `.git/info/exclude`, and global excludes through gix's
  ignore stack, skips `.git/` and `.hq/`, imports blobs and builds trees
  exactly as B-2, and returns `Snapshot { tree: Cid, base: Option<Cid> }`
  where `base` is the imported tree of `HEAD` when the directory is a git
  worktree. Symlinks are recorded, never followed. The snapshot never
  touches the git index or any ref.
- **B-6 (determinism).** Given the same git objects or the same directory
  bytes and modes, import and snapshot produce identical Cids on every
  platform: entries are sorted by git's tree ordering, file modes are
  normalized through B-1, and no timestamp, uid, or filesystem order enters
  an object. Line endings are bytes; nothing is normalized.
- **B-7 (no shelling out).** The crate never spawns `git`. Repository
  discovery, object reads, and ignore handling go through `gix` APIs only.

## 4. Functional requirements

- **FR-001.** `ObjectStore` (013) and `GitMap` are injected; tests run
  against `MemoryStore` and a temp-dir map.
- **FR-002.** Fixtures under `testdata/` are built by tests with `gix` at
  runtime from a scripted tree description (`testdata/repo-basic.toml`,
  `testdata/repo-large-blob.toml`), never committed as `.git` directories.
- **FR-003.** Tests cover: every mode round trips; an executable bit
  survives export; a symlink survives; a nested tree imports in sorted
  order; a blob above one chunk imports as a manifest and exports byte
  identical; import then export yields the original git tree oid for both
  SHA-1 and SHA-256 repositories; the map records both directions and
  survives reopen; a snapshot honors `.gitignore` and skips `.hq/`; a
  snapshot of an unchanged tree yields the same Cid twice.
- **FR-004.** `gix` is pinned exact in `[workspace.dependencies]` (its
  ignore semantics are part of the determinism contract).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-git --locked` passes.
- **AC-2.** Importing the fixture repository's `HEAD` tree then exporting
  it produces the same git tree oid, asserted for both hash formats.
- **AC-3.** `spec-spine index` discovers `hqgit-git` bound to this spec and
  `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Serving the git protocol (092), pull-request import (040), the CLI verbs
that call the bridge (033), submodule content, and git history rewriting
of any kind.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-git --locked
```
