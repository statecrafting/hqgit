---
id: "073-sandbox-executor"
title: "Sandbox executor: the Go worker with namespace and microVM tiers"
status: approved
kind: "feature"
domain: "l3-evaluation"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 5
depends_on:
  - "072-execution-service"
establishes:
  - "executor/go.mod"
  - "executor/go.sum"
  - "executor/Makefile"
  - "executor/cmd/hq-executor/main.go"
  - "executor/internal/reapi/worker.go"
  - "executor/internal/reapi/cas.go"
  - "executor/internal/sandbox/tier.go"
  - "executor/internal/sandbox/report.go"
  - "executor/internal/sandbox/namespaces_linux.go"
  - "executor/internal/sandbox/seccomp_linux.go"
  - "executor/internal/sandbox/microvm.go"
  - "executor/internal/sandbox/sandbox_test.go"
  - "executor/proto/"
  - "crates/hqgit-eval/src/sandbox.rs"
extends:
  - { spec: "070-reapi-types", unit: "crates/hqgit-eval/src/lib.rs", nature: additive }
  # A guarded `go` job joins the CI gate for the executor module.
  - { spec: "001-agentic-harness", unit: ".github/workflows/govern.yml", nature: additive }
summary: >
  The one language boundary in the platform (thesis D14): a Go worker that
  leases actions from the execution service (072), stages their inputs
  from CAS, runs them in one of two sandbox tiers, uploads the outputs, and
  reports exactly which isolation it applied. The Trusted tier is Linux
  namespaces plus a seccomp allowlist, no network, read-only inputs, an
  unprivileged uid. The Untrusted tier is a microVM (Firecracker or Cloud
  Hypervisor behind one driver interface) booted from a rootfs whose hash
  is pinned, with no network device unless the action declared one. Fork
  contributions and agent principals always get the Untrusted tier; the
  Rust side owns that rule and the tier vocabulary, so the domain model
  never crosses into Go. The executor's sandbox report is what spec 074
  attests, which is why a missing report fails the action.
---

# 073: Sandbox executor

## 1. Purpose

Thesis §4.4 names two sandbox tiers and the rule that fork contributions
and agent execution get the stronger one. The design analysis (§5)
concedes the execution plane to Go, where the container and microVM SDKs
live, on the condition that the domain model stays on the Rust side. This
spec draws that seam precisely: Go receives REAPI messages and a tier
name, Rust decides which tier a principal deserves and validates the
report that comes back. The report matters because provenance (074) is
only as true as the isolation it describes; an executor that cannot say
what it did cannot have its results trusted.

## 2. Territory

The `executor/` Go module (`github.com/statecrafting/hqgit/executor`):
the binary under `cmd/hq-executor`, the REAPI and Worker clients under
`internal/reapi`, the sandbox tiers under `internal/sandbox`, vendored
proto descriptors under `executor/proto/` generated from spec 070's and
072's protos, and the module's `Makefile` (`build`, `vet`, `test`,
`lint`). On the Rust side, `crates/hqgit-eval/src/sandbox.rs`: the
`SandboxTier` vocabulary, the tier assignment rule, and the report parser.
Additively: a guarded `go` job in the CI workflow. The scheduler that
hands out leases is spec 072; the attestation over the report is spec 074.

## 3. Behavior

- **B-1 (tier vocabulary, Rust).** `enum SandboxTier { Trusted, Untrusted
  }` with `Ord` (`Untrusted > Trusted`) and the wire spellings `trusted`
  and `untrusted` used in the platform property `hqgit.sandbox-tier`.
  `SandboxDeclaration { tier, network: NetworkPolicy::{None,
  Declared(BTreeSet<String>)}, rootfs: Option<Hash> }` is what an action
  declares (075 fills it from the build manifest).
- **B-2 (assignment rule, Rust).** `required_tier(principal: PrincipalKind,
  origin: ChangeOrigin::{Member, Fork}) -> SandboxTier` returns `Untrusted`
  for `PrincipalKind::Agent` and for `ChangeOrigin::Fork` regardless of
  principal, and `Trusted` otherwise. `check_lease(worker_tiers, required)
  -> Result<(), Error>` refuses a lease when the worker's registered tiers
  (071 B-5) do not include the required one. Nothing in Go may lower a
  tier: the tier travels in the action's platform properties and the
  worker either honors it or refuses the lease.
- **B-3 (report, both sides).** `SandboxReport { tier: SandboxTier,
  isolation: Vec<String> (the primitives actually applied, e.g.
  `user-ns`, `mount-ns`, `pid-ns`, `net-ns-empty`, `seccomp:v1`,
  `firecracker:1.x`), rootfs: Option<Hash>, network: NetworkPolicy,
  executor_version: String }` is serialized by Go as the
  `hqgit.eval.v1.SandboxReport` message into
  `ExecutedActionMetadata.auxiliary_metadata` and parsed on the Rust side
  by `parse_report(result: &ActionResult) -> Result<SandboxReport, Error>`;
  a result without a report, or whose reported tier is lower than the
  action's required tier, is `Error::Validation` and the completion is
  failed (072 B-8 hook error path).
- **B-4 (worker loop, Go).** `hq-executor` registers with the Worker
  service (072 B-7) presenting its executor identity (a Service key issued
  by the operator, stored on disk with mode 0600) and its supported tiers,
  then loops: lease, fetch the `Action`, `Command`, and input `Directory`
  tree from CAS into a fresh staging directory (files read-only, symlinks
  refused when absolute, executables marked), run the command under the
  tier, collect declared output paths, upload outputs and stdout/stderr
  to CAS, and `Complete` with the `ActionResult` and the report.
  Heartbeats run on a ticker at half the lease interval. Any failure is
  reported as a completion with a non-zero exit and the error in
  `stderr`, never a silent drop.
- **B-5 (Trusted tier, Linux).** `namespaces_linux.go` creates a child in
  new user, mount, pid, net, ipc, and uts namespaces (`CLONE_NEW*`), maps
  the caller to an unprivileged uid inside, mounts the staging directory
  read-only at `/work/in`, a tmpfs at `/work/out` and `/tmp` with a size
  cap, `/proc` fresh, and nothing else from the host; the net namespace
  has only loopback and stays down; all capabilities are dropped;
  `no_new_privs` is set; rlimits bound cpu time, memory, file size, and
  process count from the action's timeout and platform properties.
  `seccomp_linux.go` installs a default-deny BPF allowlist (via
  `libseccomp-golang`) of the syscalls a toolchain needs, explicitly
  denying `ptrace`, `mount`, `umount2`, `pivot_root`, `reboot`, `kexec_*`,
  `bpf`, `io_uring_*`, `perf_event_open`, `keyctl`, `add_key`, and
  `userfaultfd`; the profile is versioned (`seccomp:v1`) and its hash is
  part of the report's `isolation`.
- **B-6 (Untrusted tier).** `microvm.go` defines `type VmmDriver interface
  { Boot(ctx, spec) (VM, error) }` with Firecracker (`firecracker-go-sdk`)
  and Cloud Hypervisor (its REST API over a unix socket) implementations
  selected by configuration; the rootfs image is opened, hashed with
  BLAKE3, and compared to the action's declared `rootfs` (or the
  executor's configured default) before boot, a mismatch refusing the
  lease; the VM gets a vsock agent that receives the staged inputs as a
  read-only virtio block image, runs the command, and returns outputs as
  a block image; no network device is attached unless the action's
  `NetworkPolicy` is `Declared`, in which case a tap with an egress
  allowlist of the declared hosts is attached and the report records it.
  The VM is destroyed after every action; nothing persists between
  actions.
- **B-7 (platform and portability).** The Linux tier files carry
  `//go:build linux` tags; on other platforms the worker builds, refuses
  to register any tier, and exits 3, so a misconfigured host cannot
  silently run unsandboxed. There is no tier that runs a command on the
  host directly.
- **B-8 (Makefile and CI).** `executor/Makefile` targets `build`, `vet`,
  `test`, `lint` (`staticcheck` when present); the CI workflow gains a
  `go` job guarded on `hashFiles('executor/go.mod') != ''` that runs `go
  vet ./...` and `go test ./...` with `-race`.

## 4. Functional requirements

- **FR-001.** `sandbox_test.go` runs without root: tier parsing, report
  serialization round trip through the proto, seccomp profile compiles
  and its hash is stable, rootfs hash check refuses a mismatch, the
  no-tier platform path exits 3. Tests that need namespaces are tagged
  and skipped unless `HQ_SANDBOX_TESTS=1` and the caller is root.
- **FR-002.** Rust tests in `hqgit-eval` cover `required_tier` for every
  principal kind and origin, `check_lease`, `parse_report` on a fixture
  result, and refusal of a report whose tier is below the requirement.
- **FR-003.** The Go module vendors no Rust; its only contract with the
  workspace is the proto descriptors under `executor/proto/`, regenerated
  by `make -C executor proto` from `crates/hqgit-eval/proto/`.
- **FR-004.** `go.mod` pins Go 1.23 or later and every dependency by
  version; `go.sum` is committed.

## 5. Acceptance criteria

- **AC-1.** `cd executor && go vet ./... && go test ./...` passes.
- **AC-2.** `cargo test -p hqgit-eval --locked sandbox` passes.
- **AC-3.** Against the 072 fixture server, `hq-executor` in Trusted mode
  on a Linux host completes an `echo` action with a report naming
  `user-ns`, `net-ns-empty`, and `seccomp:v1`.

## 6. Out of scope

Provenance over the report (074); the build manifest that declares
network hatches (075); executor fleet management and autoscaling; Windows
and macOS sandbox tiers (the worker refuses on those hosts, B-7); GPU
passthrough.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cd executor && go vet ./... && go test ./...
cargo test -p hqgit-eval --locked sandbox
```
