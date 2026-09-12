# 03: Hosted topology and transport

Author: Bartek Kus. Written 2026-09-11 against HEAD `936eb6c`.

**Status: design record, not a spec.** It answers actions 5 and 6 of the
September 11 hqgit handoff packet: reconcile `003-chassis-alignment` with
`090-server-skeleton` and `091-per-repo-control-plane`, and resolve the
Connect versus tonic transport choice that `003` B-3 leaves open and `003`
FR-004 makes a precondition of building `090`.

Both questions are **unresolved integration design**, not observed defects.
No hosted deployment exists; `090` and `091` are `implementation: pending`
and there is no code under `crates/`. Nothing below reports a running-system
bug, because there is no running system.

The companion record for the portable evidence work is
`02-portable-evidence-integration.md`.

---

## 1. What the specs actually say

Read verbatim, 2026-09-11.

**`003` B-2.** `hqgit-server` implements rahi's `Cell` trait and composes
`rahi-edge` for the HTTP frame, `rahi-idp` for sessions and bearer
authorization, `rahi-kernel` for the capability ceiling, **`rahi-store` for
operational state**, and `rahi-ops` for the verbs and packaging. `090`'s
`config.rs`, `auth.rs`, `telemetry.rs`, `health.rs` and shutdown "shrink to
adapters over the chassis".

**`003` B-4.** "hqgit's ledger is content-addressed, hash-linked, per
repository, and portable by construction. rahi's store is a replicated
SQLite group for operational state. The server may keep session state, the
repository registry, quarantine queues, and job state in the chassis store;
it puts **no ledger entry, no object, and no fact** there. Frozen."

**`003` B-7.** In this repository *ledger* means the spec 017 evidence DAG
and nothing else; rahi's hash-chained record of operational choices is *the
chassis decision chain*.

**`091` B-1.** Every namespace of every hosted repository is its own Raft
group. A `main` and a `quarantine` namespace of one repository are two
groups. One extra group, `_cluster`, has every node as a member and holds
the node table and the placement version.

**`091` B-2.** Each group's state machine is a hiqlite database with tables
`log(seq, entry_hash, entry_bytes, proposer)`, `heads(entry_hash)` and
`meta(key, value)`. `entry_bytes` are spec 017 canonical bytes with the
issuer's signature intact. The cluster signs nothing and payload objects are
never replicated through Raft. A group can be rebuilt from any member's spec
021 store and a 021 store from the group log, "so neither is the sole copy."

**`091` frontmatter.** `extends` spec `010`'s `[workspace.dependencies]`
with hiqlite, pinned.

**`091` B-3.** `HiqliteControlPlane` is the production implementation;
`LocalControlPlane` (in-memory, one member, **same validation and apply
path**) is what `092` through `094` test against.

---

## 2. Are they separate? Yes, and that is the problem

### 2.1 The reconciliation

`091` does **not** violate `003` B-4. B-4 forbids putting ledger entries in
*rahi's* store; `091`'s groups are hqgit-owned, per namespace, and hold
entry bytes with the issuer's signature intact. Two different stores, two
different owners. Read strictly, the specs are consistent.

Read as a deployment, they are not yet coherent. **`003` B-4 draws a
two-store boundary, and `091` introduces a third store that `003` never
names.** A hosted hqgit process as currently specified contains:

| Store | Owner | Holds | Authoritative? |
|---|---|---|---|
| chassis operational store (`rahi-store`, hiqlite) | rahi | sessions, repo registry, quarantine queues, job state, the chassis decision chain | for operations only |
| hqgit control-plane groups (hiqlite, one per namespace plus `_cluster`) | hqgit `091` | append order, head set, signed entry bytes | **no**: an ordering mechanism |
| the spec 021 repository store (redb) plus the object store | hqgit `021`, `013` | the evidence DAG and its objects | **yes** |

Nothing on disk says that. A reader of `003` alone concludes there are two
stores; a reader of `091` alone never learns `rahi-store` exists.

### 2.2 The concrete risk

Both hqgit's control plane and rahi's operational store are **hiqlite**.
Neither spec says whether the hosted binary embeds one hiqlite instance
hosting many Raft groups, or two independent hiqlite deployments with two
node identities, two sets of ports, two election timeouts and two version
pins. `091`'s `_cluster` group (node table plus placement version) is a
second copy of cluster membership that rahi's own store already has.

`003` FR-001 does not catch this: it asserts that no crate *below*
`hqgit-server` names a rahi crate, hiqlite or rauthy. `hqgit-server` itself
is allowed to name both, and `091` explicitly does.

This is the unresolved question, and it must be settled before `090` is
built rather than discovered while building `091`.

### 2.3 What replicates where

Stated so it can be checked later:

- **Payload objects never go through Raft** (`091` B-2, explicit). They
  travel through the object store (`013`, `016`) or `091` B-5's
  `PayloadFetcher`.
- **Signed entry bytes go through Raft** for ordering within one cluster,
  and are applied into the local `021` store in `seq` order. Raft is not the
  truth (`091` §1, explicit); the signed DAG is.
- **Nothing about a repository goes into the chassis store.** Sessions, the
  repository registry, quarantine queues and job state do.
- **Across clusters**, nothing replicates through Raft at all: that is `110`
  set reconciliation over `111` QUIC, and `112` federation.

### 2.4 Recommended amendment

**A-1 (`003` B-4, widen to name three stores).** Replace the two-store
sentence with the table of §2.1: the chassis operational store, the hqgit
control-plane groups, and the 021 repository and object store, saying which
is authoritative (the third) and that the second is an ordering mechanism
that is never the sole copy. This *clarifies* the existing boundary rather
than moving it; the frozen sentence "no ledger entry, no object, and no fact
in the chassis store" survives verbatim.

**A-2 (`091`, a `D-n` required before it is built).** Record whether the
hosted binary runs one hiqlite instance or two, and if two, why rahi's node
table and `091`'s `_cluster` group both exist. `003` FR-004 already
establishes the precedent of a decision that must be on record before a spec
flips to `in-progress`; this is the same class of question.

Both are amendments a human makes. Neither has been made.

---

## 3. Placement: what it is for, and when it is needed

`091` B-6 specifies consistent-hash placement of groups onto nodes with
rebalancing as an operator command. The packet asks why the additional
placement machinery is needed.

**Verified answer:** it is needed only for a multi-node cluster hosting more
namespaces than one node holds. `091` §1 justifies the *Raft group* (two
servers hosting one repository must agree on append order); it does not
separately justify *placement*, which is the scale story for many groups
across many nodes.

**And `091` already ships the smaller thing.** `LocalControlPlane` is
in-memory, one member, and runs the same validation and apply path. A
single-host deployment uses it and touches no placement code, no
consistent-hash ring and no `_cluster` group.

**Recommendation:** a bounded single-host evidence deployment runs
`LocalControlPlane` on one node. It is a candidate starting point, as the
packet says, and explicitly **not** an approved replacement of the
distributed design: `091` stays as specified, and the multi-node path stays
available. Recovery for the single-host case is already covered by `091`
B-2's round trip (a group rebuilds from the 021 store, a 021 store from the
group log) plus ordinary backup of `.hq/`.

This position requires no spec change. It is a deployment choice, and it
should be recorded as such when `091` is built.

---

## 4. The transport decision

### 4.1 State on disk

`003` B-3 names the question, the preferred resolution (the Connect protocol
over plain HTTP, which axum serves natively and which `093` already names,
so no multiplexing is required and rahi is unchanged), and the fallback (a
spec in rahi that mounts a tonic service into its router). `003` FR-004: the
decision "is recorded as a D-n entry in 090 before 090 is flipped to
`implementation: in-progress`."

`090` §7 Resolved decisions currently reads **"None yet."** The decision is
genuinely open.

Meanwhile `090` B-2 still specifies the thing `003` prefers to remove: one
axum router that "merges every HTTP router, mounts every tonic service
through `tonic::service::Routes`, and dispatches by `Content-Type`
(`application/grpc*` to tonic, everything else to axum)". `093` specifies
five protobuf services "served as gRPC and as Connect-compatible JSON over
plain HTTP on the same listener".

### 4.2 Recommendation: take the preferred resolution, with one carve-out

**Adopt Connect over plain HTTP for the human-facing edge. Remove tonic from
`hqgit-server`. Keep gRPC for REAPI on its own listener.**

Reasons, each grounded in the corpus:

1. **`003` B-2 and FR-003 make multiplexing awkward on purpose.** The server
   composes `rahi-edge` for the HTTP frame, and FR-003 requires that
   `hqgit-server` contain no axum `Router::new` outside its `Cell`
   implementation. Mounting `tonic::service::Routes` into rahi's router means
   either changing rahi (the named fallback, a whole spec in another
   repository) or reaching around `rahi-edge`. Connect needs neither: it is
   ordinary HTTP POST with a JSON body on routes axum already serves.
2. **`093` loses nothing.** It already specifies the Connect JSON form on
   the same listener, and `095` (the web review client) consumes exactly
   that form. Dropping the gRPC half costs the UI nothing.
3. **The CLI gets simpler and stays chassis-free.** `093`'s `client.rs`
   becomes an HTTP client over the generated JSON types. `tonic` leaves
   `hqgit-cli`'s manifest; `prost` and `pbjson` stay for codegen, which is
   fine. `003` B-1's frozen property (waves 1 to 5 take no chassis
   dependency) gets cheaper to hold, not harder.
4. **Thesis D9 is preserved by the carve-out.** "REAPI, not a new protocol"
   is non-negotiable, and REAPI is gRPC. `072` already assembles its own
   `tonic::transport::Server` router and its §6 already speaks of "this
   listener" as distinct from `093`'s ("the API in 093 fronts humans; this
   listener serves clients and executors"). So the carve-out is not a new
   idea; it is what `072` already assumes. REAPI keeps gRPC on a second bind
   address, reached by executors and build clients, never by a browser.

### 4.3 What adopting it would change

| Spec | Change | Nature |
|---|---|---|
| `090` B-2 | drop `with_grpc`, `tonic::service::Routes` and the `Content-Type` dispatch; the builder merges HTTP routers only | narrows what the spec requires |
| `090` B-7 | drop the `tonic-health` gRPC health service; `/healthz` and `/readyz` remain | narrows |
| `090` frontmatter | `tonic` and `tonic-health` leave the dependency `extends` | narrows |
| `090` §7 | add the `D-n` that `003` FR-004 demands | additive, required either way |
| `093` | serve Connect JSON only; `client.rs` is an HTTP client | narrows |
| `072` (wave 5) | unchanged; add an `extends` edge on `090`'s config for a second bind address when it lands | additive, later |

**These are changes to what `090` and `093` require, so they are not a
session's to make.** `.claude/rules/adversarial-prompt-refusal.md` is
explicit that changing what a spec requires mid-build is never an agent's
call, and this is the same class of edit made before any build. Recorded
here as a proposal; `090` and `093` are untouched.

### 4.4 What the decision must preserve, either way

- **Chassis-free offline operation.** `003` B-1 is frozen: `hqgit-cli` and
  every crate below wave 6 take no rahi, hiqlite or rauthy dependency. The
  whole of wave 1 through `034` runs on a laptop with no server and no
  network (`034` AC-3 asserts exactly this with networking disabled).
- **Cryptographic identity independent of the IdP.** `003` B-5 and D-2 are
  already right and must not drift: hqgit's durable identity is the keypair
  whose rotation history is a sequence of signed facts (`060`), rauthy's
  `sub` is an authentication subject bound to an `IdentityId` through `061`'s
  `identity.binding_added` fact, and the reason is stated in D-2:
  "Attestations must verify offline, years later, by someone who has never
  contacted this deployment's IdP, and an OIDC subject cannot carry that."
  No transport choice touches this, and no transport choice may be allowed
  to.

---

## 5. Proposed spec changes

Each needs a human. None has been made.

**P-5 (`003` B-4).** Widen to name three stores, per §2.4 A-1. Clarifying;
the frozen sentence survives.

**P-6 (`091`, `D-n` before `in-progress`).** One hiqlite instance or two,
and the fate of the duplicated node table, per §2.4 A-2.

**P-7 (`090` §7, `D-n`).** The transport decision that `003` FR-004 already
requires. Recommended value: Connect over plain HTTP, no tonic in
`hqgit-server`, REAPI gRPC on its own listener under `072`.

**P-8 (`090` B-2, B-7, frontmatter; `093`).** The narrowing that P-7 implies,
per the table in §4.3. Only if P-7 takes the recommended value.

**P-9 (`091`, deployment note when built).** A single-host deployment runs
`LocalControlPlane`; placement and the ring are the multi-node path and stay
specified. Additive.

---

## 6. Open decisions

1. **One hiqlite or two in the hosted binary** (P-6). The load-bearing one:
   it determines whether `091` is a tenant of the chassis store's runtime or
   an independent deployment beside it.
2. **Connect only, or Connect plus gRPC** (P-7). Recommended: Connect only,
   with the `072` carve-out. The cost of the recommendation is gRPC-native
   interop for the *human* API surface, which no consumer in the corpus
   asks for.
3. **Whether the REAPI carve-out needs its own bind address in `090`'s
   `Config` now or when `072` lands.** Recommend later: `072` is wave 5 and
   `090` should not carry configuration for a service that does not exist.
4. **Whether `003` FR-002's grep test (the word *ledger* never refers to the
   chassis decision chain) should also cover the three-store vocabulary of
   §2.1.** Cheap to add when the workspace exists; noted so it is not
   forgotten.
