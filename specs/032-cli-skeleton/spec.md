---
id: "032-cli-skeleton"
title: "The hq binary: clap frame, exit codes, JSON output, init, status, log"
status: approved
kind: "kernel"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "021-local-repository"
establishes:
  - "crates/hqgit-cli/Cargo.toml"
  - "crates/hqgit-cli/src/main.rs"
  - "crates/hqgit-cli/src/cli.rs"
  - "crates/hqgit-cli/src/cmd_init.rs"
  - "crates/hqgit-cli/src/cmd_status.rs"
  - "crates/hqgit-cli/src/cmd_log.rs"
  - "crates/hqgit-cli/src/config.rs"
  - "crates/hqgit-cli/src/output.rs"
  - "crates/hqgit-cli/tests/"
extends:
  # clap, serde_json, toml, and the assert_cmd dev-dependency join the table.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The hq binary is the first client of the ledger and, by thesis §5, runs
  the same ledger implementation the server will. This spec founds
  hqgit-cli: a clap frame whose subcommands are one module each, exit codes
  mapped in exactly one place through Error::exit_code, a --json mode on
  every read verb that emits canonical sorted-key JSON, layered
  configuration (user and repository), and the three verbs that prove the
  local repository works: hq init creates .hq/ with a local ed25519
  identity and the genesis entry, hq status reports heads and identity,
  and hq log renders entries in total order. Later specs add verbs by
  extending main.rs and cli.rs; nothing here talks to a network or to git.
---

# 032: The hq binary

## 1. Purpose

Thesis §5: single-binary embedding means the CLI and the server run the
same ledger implementation, which is the only way to get genuine
offline-first without two implementations drifting apart (constitution
XIII). The CLI therefore arrives before the server and exercises spec 021's
`Repository` directly. This spec is the frame every later verb hangs on:
one place for exit codes, one output discipline, one configuration model,
and a test harness that drives the real binary against temporary
directories.

## 2. Territory

`crates/hqgit-cli` as founded here: the manifest (binary name `hq`,
depending on `hqgit-types`, `hqgit-object`, and `hqgit-ledger` within the
workspace), `main.rs` (dispatch and the single exit-code mapping),
`cli.rs` (the clap definitions), `cmd_init.rs`, `cmd_status.rs`,
`cmd_log.rs`, `config.rs`, `output.rs`, and the `tests/` subtree. Every
later CLI spec (033, 034, 042, 067, 080, 093, 103, 112) `extends` `main.rs`
and `cli.rs` and establishes its own `cmd_*.rs`.

## 3. Behavior

- **B-1 (frame).** `cli.rs` declares `Hq { #[command(subcommand)] cmd:
  Command, #[arg(long, global = true)] json: bool, #[arg(long, global =
  true)] repo: Option<PathBuf>, #[arg(long, global = true)] quiet: bool }`.
  `--repo` overrides discovery; otherwise the repository is the nearest
  ancestor directory containing `.hq/`, and a verb that needs one and finds
  none exits `1` with `no hqgit repository found (run hq init)`.
- **B-2 (exit codes).** `main.rs` calls `run(args) -> Result<(), Error>`
  and maps the result through spec 010's `Error::exit_code()` in exactly
  one `std::process::exit` call: `0` ok, `1` validation, not found, drift,
  crypto, or policy, `2` stale, `3` I/O, parse, schema, or config. Clap
  usage errors keep clap's `2`; no other code is ever produced.
- **B-3 (output).** `output.rs` exposes `Out { json: bool, quiet: bool }`
  with `emit<T: Serialize>(&self, value: &T, human: impl FnOnce(&T) ->
  String)`. With `--json` every read verb prints one JSON document with
  keys sorted, two-space indentation, and a trailing newline (the same
  canonicalization spec-spine uses), and nothing else on stdout.
  Diagnostics go to stderr. Hashes render as 64 hex characters, Cids as
  `<codec>:<hex>`, principals as `<kind>:<hex>`.
- **B-4 (config).** `config.rs` loads, in precedence order, `.hq/config.toml`
  inside the repository, then `$XDG_CONFIG_HOME/hq/config.toml` (default
  `~/.config/hq/config.toml`), then built-in defaults, into `Config {
  identity: IdentitySection { display: Option<String> }, output:
  OutputSection { json: bool } }`. Unknown keys are a `Config` error naming
  the key. `HQ_CONFIG` overrides the user path. No secret ever lives in a
  config file: the identity seed is under `.hq/identity/` (021).
- **B-5 (`hq init`).** `hq init [--display <name>] [--node-id <hex16>]`
  refuses with exit `1` when `.hq/` already exists, otherwise generates a
  fresh ed25519 seed into `.hq/identity/seed` (mode `0600`), derives the
  `HumanId` as spec 060 will (the hash of an `identity.created` fact,
  which this verb also appends as the first fact after genesis), calls
  `Repository::init` (021) with that identity, and prints `{ "repo":
  <path>, "namespace": <hex>, "identity": <principal>, "genesis":
  <entry-hash> }`. When the directory is a git worktree the config records
  `git.worktree = true`; nothing reads git here (033 wires the bridge).
- **B-6 (`hq status`).** Prints `{ "repo", "namespace", "identity",
  "heads": [<entry-hash>], "entries": <count>, "objects": <count>,
  "namespaces": [<name>] }` from spec 021's `Repository` reads only. Exit
  `0` always when a repository is found.
- **B-7 (`hq log`).** `hq log [--limit N] [--namespace <name>]
  [--kind <fact-kind>]` renders entries in spec 018's total order, newest
  first, one line per entry in human mode (`<hash[..12]> <hlc> <issuer[..8]>
  <fact-kind>`) and an array of `{ "hash", "hlc": { "wall_ms", "logical",
  "node" }, "issuer", "kind", "payload": <cid>, "parents": [...] }` in JSON
  mode. An erased payload (020) renders `"kind": "erased"`; the verb never
  fails because content is gone.
- **B-8 (never git).** The crate does not depend on `hqgit-git` and never
  spawns `git`. Spec 033 adds the bridge dependency by extending this
  crate's manifest.
- **B-9 (no ambient input on hashed paths).** The only clock read is the
  one spec 018's `HlcGenerator` performs when a verb appends a fact; no
  verb formats a timestamp from the system clock into output.

## 4. Functional requirements

- **FR-001.** Each `cmd_*.rs` exposes `pub fn run(ctx: &Ctx, args: &XArgs)
  -> Result<(), Error>` where `Ctx { repo: Option<Repository>, config:
  Config, out: Out }` is built once in `main.rs`; commands never call
  `process::exit`.
- **FR-002.** `tests/cli.rs` drives the built binary with `assert_cmd`
  against temporary directories: `init` creates the layout and refuses a
  second time; `status --json` parses and carries the genesis head; `log
  --json` lists the genesis and the identity fact in order; a verb outside
  a repository exits `1` with the documented message; an unknown config key
  exits `3`.
- **FR-003.** A contract test asserts the exit code of every `Error`
  variant through the binary (one fixture per variant), pinning B-2.
- **FR-004.** JSON output of every read verb is byte-identical across two
  runs on an unchanged repository.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-cli --locked` passes.
- **AC-2.** In a fresh directory, `hq init && hq status --json && hq log
  --json` exits 0 three times and the status head equals the log's newest
  entry.
- **AC-3.** `spec-spine index` discovers `hqgit-cli` bound to this spec and
  `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Changes and review (033), attestation and verification verbs (034), mirror
verbs (042), policy verbs (067), projection verbs (080), remote targets
(093), evidence verbs (103), sync verbs (112), and any server.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-cli --locked
cargo run -p hqgit-cli --locked -- --help
```
