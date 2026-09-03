---
id: "091-per-repo-control-plane"
title: "Per-repo control plane: one Raft group per repository over hiqlite, proposal, apply, placement"
status: approved
kind: "kernel"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 6
depends_on:
  - "090-server-skeleton"
establishes:
  - "crates/hqgit-server/src/control/mod.rs"
  - "crates/hqgit-server/src/control/raft.rs"
  - "crates/hqgit-server/src/control/placement.rs"
  - "crates/hqgit-server/src/control/apply.rs"
  - "crates/hqgit-server/tests/control.rs"
extends:
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/lib.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/Cargo.toml", nature: additive }
  # hiqlite (embedded Raft-replicated SQLite) joins the dependency table, pinned.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Thesis §4.2, last paragraph: repositories are independent consistency
  domains, so the hosted server replicates each one in its own Raft group
  rather than through a shared database tier. This spec adds the control
  plane to hqgit-server: a ControlPlane seam with a hiqlite-backed
  implementation and an in-process one for tests; a per-namespace group
  whose replicated state is the append order of signed entries and the
  head set, never payload content and never a signature of the cluster's
  own; a proposal path that validates before forwarding and commits
  through the leader; an applier that feeds committed entries into the
  local spec 021 store in order with the payload present first; and
  consistent-hash placement of groups onto nodes with rebalancing as an
  operator command. A single node is a one-member group on the same path.
---

# 091: Per-repo control plane

## 1. Purpose

Two servers hosting one repository must agree on the order in which
concurrent appends arrived, or their head sets diverge and every client
sees a different "latest". The ledger itself tolerates that (017 D4: a
DAG, not a log), and federation (112) reconciles it across hosts, but
inside one hosting cluster a client expects linearizable appends: propose,
get a hash back, and every node serves it. Raft provides exactly that
ordering, and because repositories never share state the group can be as
small as one repository. Raft is not the truth. The signed DAG is; Raft is
how a cluster of hqgit-server nodes stops racing on it (constitution VI,
XIII).

## 2. Territory

The `control` module of `hqgit-server`: `mod.rs` (the `ControlPlane`
trait, `LocalControlPlane`, the cluster config), `raft.rs` (the hiqlite
group per namespace and the `_cluster` meta group), `placement.rs`
(the ring and the rebalance plan), `apply.rs` (the applier and the
`PayloadFetcher` seam), and `tests/control.rs`. Additively: `lib.rs` and
the crate manifest (090). The remote object backend a cluster shares is
016; reconciliation between clusters is 110 and 112.

## 3. Behavior

- **B-1 (groups).** A `GroupId` is a namespace `Hash` (021 B-6). Every
  namespace of every hosted repository is its own Raft group; a `main` and
  a `quarantine` namespace of one repository are two groups. One extra
  group, `_cluster`, has every node as a member and holds the node table
  and the placement version (B-6). There is no transaction across groups.
- **B-2 (replicated state).** Each group's state machine is a hiqlite
  database with tables `log(seq INTEGER PRIMARY KEY, entry_hash BLOB
  UNIQUE, entry_bytes BLOB NOT NULL, proposer TEXT NOT NULL)`, `heads(
  entry_hash BLOB PRIMARY KEY)`, and `meta(key TEXT PRIMARY KEY, value
  BLOB)` holding `namespace`, `genesis`, and `schema`. `entry_bytes` are
  spec 017 canonical bytes with the issuer's signature intact; the cluster
  signs nothing and payload objects are never replicated through Raft
  (they travel through the object store, 013 and 016, or B-5's fetcher).
  A group can be rebuilt from any member's 021 store by replaying
  `iter_all` in total order (018), and a 021 store from the group log, so
  neither is the sole copy.
- **B-3 (seam).** `trait ControlPlane: Send + Sync { fn propose(&self,
  group: &GroupId, append: ProposedAppend) -> Result<Committed, Error>;
  fn heads(&self, group: &GroupId) -> Result<(Vec<EntryHash>, u64),
  Error>; fn status(&self, group: &GroupId) -> Result<GroupStatus, Error>;
  fn ensure_group(&self, group: &GroupId, genesis: &Entry) -> Result<(),
  Error>; }` with `ProposedAppend { entry: Entry, payload_present: bool }`,
  `Committed { seq: u64, hash: EntryHash }`, and `GroupStatus { leader:
  Option<NodeId>, term: u64, members: Vec<NodeId>, commit_seq: u64,
  applied_seq: u64 }`. `HiqliteControlPlane` is the production
  implementation; `LocalControlPlane` (in-memory, one member, same
  validation and apply path) is what 092 through 094 test against.
- **B-4 (proposal).** The receiving node runs the 017 B-6 checks against
  its local DAG and the signature through the repository's resolver (060
  B-7 once present, `StaticResolver` before) BEFORE forwarding; a failure is
  the caller's error and never reaches the leader. The leader re-checks
  against the replicated `heads` and `log` (every parent in `log`, hash not
  already present) and commits. A duplicate hash is `Ok(Committed)` with
  the existing `seq`. A parent the local node lacks but the log holds is
  `Error::Stale` with the missing hash; the caller retries after the
  applier catches up. `propose` returns only after the entry is committed
  and applied locally (B-5), so a subsequent local read observes it.
  Proposal timeout is `cluster.propose_timeout_ms` (default 5000).
- **B-5 (apply).** `apply.rs` consumes each group's committed sequence in
  `seq` order and calls the local 021 `EntryStore::append`. Per 021 B-3
  the payload object MUST be present before the entry is appended: the
  applier checks the store, else fetches through `trait PayloadFetcher {
  fn fetch(&self, cid: &Cid, hint: &NodeId) -> Result<Vec<u8>, Error>; }`
  (the proposer node, then any member, verified by hash on receipt, 013
  B-4), else parks the entry as `pending_payload` and retries with backoff
  while later entries wait (order is never skipped). `applied_seq` is
  written in the same 021 transaction as the append, so a restart resumes
  at the last applied entry and a re-apply is a no-op.
- **B-6 (placement).** `Placement { version: u64, nodes: BTreeMap<NodeId,
  NodeAddr>, replication_factor: u8 }` with a consistent-hash ring of 64
  virtual points per node at `Hash::of(b"hqgit/v1/ring" || node_id ||
  point_index)`. `members_for(&self, group: &GroupId) -> Vec<NodeId>` is
  the first `replication_factor` distinct nodes clockwise from the group's
  hash, deterministic for a given `Placement`. `plan(from: &Placement, to:
  &Placement) -> RebalancePlan` lists per group the members to add (as
  learners first) and remove; `apply_plan` promotes a learner only after
  it has caught up and never removes a member while the group would drop
  below quorum. Placement changes are committed to `_cluster` and only
  through the operator subcommands `hqgit-server placement show | plan
  --add <id>=<addr> | --remove <id> | apply <plan.json>`.
- **B-7 (config and single node).** `[cluster] node_id = <u64>, raft_addr,
  api_addr, peers = [{ id, raft_addr, api_addr }], replication_factor = 3,
  election_timeout_ms = 1500, heartbeat_ms = 300, propose_timeout_ms` with
  the shared secret from `HQGIT_CLUSTER_SECRET` only. With no `[cluster]`
  table the server is node `1`, every group has one member, and the same
  `propose` and apply path runs, so single-node and clustered deployments
  differ in membership only.
- **B-8 (independence).** A group's leader loss, election, or stalled
  applier affects no other group; the applier is one task per group and
  the hiqlite instances are one per group under `<data>/control/<group-hex>/`.
- **B-9 (no ambient input).** Raft timers are the only clock reads and
  never touch an entry; every `Hlc` is the issuer's. `BTreeMap` only.

## 4. Functional requirements

- **FR-001.** `tests/control.rs` starts three nodes in one process on
  ephemeral ports with distinct temp data directories and covers: a
  proposal on a follower commits and is readable on all three; the leader
  is killed and a proposal on a survivor succeeds within twice the election
  timeout; twelve concurrent proposers across the three nodes on one group
  yield an identical `log` on every node, every parent preceding its
  child, and one 018 total order; partitioning group A's leader leaves
  proposals on group B unaffected; a duplicate proposal is idempotent; an
  entry with a missing parent is refused before forwarding; an entry
  whose payload is absent on a follower is fetched before append, and with
  the fetcher failing is parked and applied after the object arrives; a
  node restarted mid-sequence resumes from `applied_seq` with no duplicate
  rows; `LocalControlPlane` passes the same single-group assertions.
- **FR-002.** Placement tests: `members_for` is stable across two
  constructions; adding a node to `N` moves at most `ceil(groups / (N+1))`
  groups; a plan never proposes a removal that breaks quorum.
- **FR-003.** No function in `placement.rs` performs I/O; `apply.rs` and
  `raft.rs` reach the ledger only through 021 `EntryStore` and
  `Repository`.
- **FR-004.** `hiqlite` is pinned exact in `[workspace.dependencies]` and
  the manifest gains it behind the default feature `cluster`; `cargo test
  -p hqgit-server --no-default-features` still builds with
  `LocalControlPlane` alone.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-server --locked control` passes.
- **AC-2.** With the three-node fixture, `hqgit-server placement show`
  on each node prints the same membership for every group.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Reconciliation between clusters and with CLIs (110, 112), sharing objects
between nodes beyond the fetch seam (016 provides the shared backend),
authorization of a proposal (094), projections on each node (080 rebuilds
locally), and any multi-group transaction.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-server --locked control
cargo test -p hqgit-server --locked
```
