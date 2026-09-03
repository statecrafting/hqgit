---
id: "072-execution-service"
title: "Execution service: REAPI Capabilities, CAS, ByteStream, ActionCache, Execution, and the scheduler"
status: approved
kind: "feature"
domain: "l3-evaluation"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 5
depends_on:
  - "071-action-cache"
establishes:
  - "crates/hqgit-eval/proto/hqgit/eval/v1/worker.proto"
  - "crates/hqgit-eval/src/service/mod.rs"
  - "crates/hqgit-eval/src/service/capabilities.rs"
  - "crates/hqgit-eval/src/service/cas.rs"
  - "crates/hqgit-eval/src/service/bytestream.rs"
  - "crates/hqgit-eval/src/service/action_cache.rs"
  - "crates/hqgit-eval/src/service/execution.rs"
  - "crates/hqgit-eval/src/service/worker.rs"
  - "crates/hqgit-eval/src/scheduler.rs"
  - "crates/hqgit-eval/tests/service.rs"
extends:
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/src/lib.rs", nature: additive }
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/build.rs", nature: additive }
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/Cargo.toml", nature: additive }
  # tokio, tokio-stream, uuid: the async runtime and operation ids.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The listening half of the evaluation plane: tonic implementations of the
  four REAPI services (Capabilities, ContentAddressableStorage with
  ByteStream, ActionCache, Execution with long-running operations) over the
  spec 070 adapter and the spec 071 cache, plus the scheduler that turns an
  Execute request into a leased unit of work for an external worker.
  Nothing executes in this process: workers (073) register, lease, heartbeat,
  and complete through a small hqgit-owned Worker service, because REAPI
  standardizes the client side and not the worker side. Identical in-flight
  actions coalesce, lost leases requeue, the sandbox tier is a platform
  property the scheduler matches, and every completion passes through a
  hook seam that spec 074 fills with provenance before the cache sees it.
---

# 072: Execution service

## 1. Purpose

Thesis D9 says interoperate on day one: any REAPI client (Bazel, Buck2,
`reclient`, a `hq` CLI) must be able to point at hqgit and get execution
and caching without a translation layer. This spec is that surface. It
also draws the line thesis D14 requires: the Rust side schedules and
stores, the Go side (073) executes, and the two meet at a worker protocol
that carries the REAPI messages unchanged.

## 2. Territory

The `service/` module of `crates/hqgit-eval`: `capabilities.rs`, `cas.rs`,
`bytestream.rs`, `action_cache.rs`, `execution.rs`, `worker.rs`, and the
`mod.rs` that assembles them into a `tonic::transport::Server` router;
`scheduler.rs`; the hqgit-owned `hqgit.eval.v1.Worker` proto and its build
step; `tests/service.rs`. Additively: the crate manifest (tokio,
tokio-stream, uuid) and `build.rs`. Executors themselves are spec 073; the
provenance hook implementation is spec 074; the merge queue that drives
this service is spec 076; embedding the router into `hqgit-server` is
wired by spec 090's app when both exist.

## 3. Behavior

- **B-1 (Capabilities).** `GetCapabilities` returns `ServerCapabilities`
  with `cache_capabilities.digest_functions = [BLAKE3]`,
  `action_cache_update_capabilities.update_enabled = true`,
  `max_batch_total_size_bytes = 4 MiB`, `symlink_absolute_path_strategy =
  DISALLOWED`, `execution_capabilities.digest_function = BLAKE3`,
  `exec_enabled = true`, `execution_priority_capabilities` covering `-10`
  to `10`, `supported_node_properties = []`, and `low_api_version =
  high_api_version = 2.3`. A request naming another instance than the
  configured ones is `NOT_FOUND`.
- **B-2 (CAS).** `FindMissingBlobs`, `BatchUpdateBlobs`,
  `BatchReadBlobs`, and `GetTree` delegate to spec 070's
  `ContentAddressable`; a blob whose bytes do not hash to the declared
  digest is `INVALID_ARGUMENT` and never stored; batch limits are enforced
  from B-1; `GetTree` pages breadth-first with an opaque cursor.
- **B-3 (ByteStream).** `Read` streams `{instance}/blobs/{hash}/{size}`
  in 64 KiB chunks from the store, honoring `read_offset` and
  `read_limit`; `Write` accepts
  `{instance}/uploads/{uuid}/blobs/{hash}/{size}`, buffers to a spooled
  temporary file, verifies the hash at `finish_write`, and commits through
  the adapter; `QueryWriteStatus` reports committed size. A digest whose
  size exceeds the configured maximum (default 2 GiB) is
  `RESOURCE_EXHAUSTED`.
- **B-4 (ActionCache service).** `GetActionResult` performs a spec 071
  `lookup` with `Purpose::Advisory` and the caller-presented verified set
  (empty unless the request metadata carries attestation ids the server
  can verify through the 064 seam), returning `NOT_FOUND` on a miss; the
  response `ActionResult` carries the grade in
  `execution_metadata.auxiliary_metadata` as a `hqgit.eval.v1.CacheGrade`
  message so a client can see `Unattested`. `UpdateActionResult` is
  accepted only from a caller authenticated as a registered executor
  (`ExecutorRegistry`, 071 B-5) and stores through `put`; any other caller
  is `PERMISSION_DENIED`. Gating lookups never happen over this service:
  the merge queue (076) calls the cache in process.
- **B-5 (Execution).** `Execute` validates the `Action` (digests present
  in CAS, platform property `hqgit.sandbox-tier` present and one of
  `trusted`, `untrusted`), consults the cache with `Advisory` unless
  `skip_cache_lookup`, and otherwise enqueues, returning a stream of
  `google.longrunning.Operation` whose metadata is
  `ExecuteOperationMetadata` with stages `CACHE_CHECK`, `QUEUED`,
  `EXECUTING`, `COMPLETED`; `WaitExecution` reattaches to an operation by
  name. Identical action digests already queued or executing coalesce onto
  one execution; every attached operation completes with the same result.
- **B-6 (scheduler).** `Scheduler` is a pure state machine over
  `SchedulerEvent`s (`Enqueue`, `RegisterWorker`, `Lease`, `Heartbeat`,
  `Complete`, `Tick`) with a `Clock` seam for lease expiry: a queue ordered
  by `(priority, enqueue sequence)`; workers register with an
  `ExecutorIdentity` (071) and platform properties; `lease(worker)` hands
  out the highest-priority queued action whose platform properties are all
  satisfied by the worker's, with a lease of 60 s renewed by heartbeat; a
  lease that misses two heartbeats is revoked and the action requeued at
  the head with an `attempt` counter; the third failed attempt completes
  the operation with `FAILED_PRECONDITION` and the last worker's error.
  The tier property is matched exactly: an `untrusted` action never leases
  to a worker that registered only `trusted`.
- **B-7 (Worker service).** `hqgit.eval.v1.Worker` (`worker.proto`) has
  `Register(RegisterRequest) returns (RegisterResponse)`,
  `Lease(LeaseRequest) returns (stream LeaseAssignment)`,
  `Heartbeat(HeartbeatRequest) returns (HeartbeatResponse)`, and
  `Complete(CompleteRequest) returns (CompleteResponse)`; assignments carry
  the REAPI `Action` digest and instance name only (the worker fetches the
  rest from CAS); `Complete` carries the REAPI `ActionResult` and a
  `SandboxReport` (073) and is authenticated as the leasing executor.
- **B-8 (completion hook).** `trait CompletionHook { fn on_complete(&self,
  ctx: &CompletionContext, result: ActionResult) -> Result<CacheEntry,
  Error> }` receives the action key, the executor identity, the sandbox
  report, and the result, and returns the entry to store. The default
  `UnattestedHook` builds an entry with `attestation: None` (advisory
  only); spec 074 supplies the hook that mints provenance first. A hook
  error fails the operation with the reason and stores nothing.
- **B-9 (observability and limits).** Every state transition is a
  structured log line with operation id, action key, worker id, and stage;
  queue depth and lease counts are gauges; a configured maximum queue depth
  refuses new work with `RESOURCE_EXHAUSTED`.

## 4. Functional requirements

- **FR-001.** Every service is generic over the store, cache, registry,
  and hook seams, and tests instantiate them with in-memory
  implementations and a `FakeWorker` that speaks the Worker service in
  process.
- **FR-002.** Scheduler tests, pure over events: priority order, platform
  matching including tier exactness, coalescing of identical digests,
  lease expiry and requeue, third-attempt failure, heartbeat renewal.
- **FR-003.** Service tests: a full Execute round trip through the fake
  worker ending in a stored advisory entry; `UpdateActionResult` refused
  for a non-executor; ByteStream write with a bad hash refused;
  `GetActionResult` surfacing the `Unattested` grade; `WaitExecution`
  reattachment.
- **FR-004.** An interop smoke test drives the server with an
  independent REAPI client binary when one is on `PATH`, marked
  `#[ignore]` otherwise.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-eval --locked service` passes.
- **AC-2.** In the fixture flow, two concurrent `Execute` calls for one
  action digest produce exactly one lease and two completed operations
  with identical results.

## 6. Out of scope

Executing anything (073); provenance minting (074); the build manifest
and affected targets (075); the merge queue (076); authentication of human
principals on this listener (the API in 093 fronts humans; this listener
serves clients and executors); multi-node scheduling (091 places repos,
not workers, in v1).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-eval --locked service
```
