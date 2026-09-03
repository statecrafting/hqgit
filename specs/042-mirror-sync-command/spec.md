---
id: "042-mirror-sync-command"
title: "hq mirror: the sync loop with cursors, backoff, and reports"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 2
depends_on:
  - "041-github-mirror-export"
  - "032-cli-skeleton"
establishes:
  - "crates/hqgit-mirror/src/sync.rs"
  - "crates/hqgit-cli/src/cmd_mirror.rs"
  - "crates/hqgit-cli/tests/mirror.rs"
extends:
  - { spec: "040-github-mirror-import", unit: "crates/hqgit-mirror/src/lib.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/main.rs", nature: additive }
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/src/cli.rs", nature: additive }
  # hqgit-mirror joins the CLI's dependencies.
  - { spec: "032-cli-skeleton", unit: "crates/hqgit-cli/Cargo.toml", nature: additive }
summary: >
  The user-facing end of wave 2: hq mirror add registers a GitHub
  repository as a source, hq mirror sync runs import then export once or
  in a watch loop, and hq mirror status shows cursors and the last report.
  The sync driver persists cursors in the id map database so every run
  resumes where the last one stopped, backs off exponentially on rate
  limits and transient errors and never busy-loops, and prints a report of
  facts imported, items exported, items skipped, and disagreements
  reconciled. The token comes from the environment or the user config and
  never enters the ledger, the repository config, or any output.
---

# 042: hq mirror

## 1. Purpose

Specs 040 and 041 are libraries; this spec makes the mirror a thing a
person runs. The loop's discipline matters more than its verbs: cursors so
a run is incremental, backoff so a rate-limited run parks instead of
hammering, and a report so the operator sees what moved and what did not
(the honesty posture claude-observatory's own thesis names: unknown is
displayed as unknown). Wave 2 ends when a GitHub repository can be kept in
sync from a laptop with one command.

## 2. Territory

`sync.rs` in `crates/hqgit-mirror` (the driver) and `cmd_mirror.rs` plus
`tests/mirror.rs` in `crates/hqgit-cli`. Additively: the mirror crate's
`lib.rs`, the CLI dispatch and clap tree, and the CLI manifest gaining
`hqgit-mirror`. Promotion of mirrored facts to `main` is spec 094; a
server-side scheduled mirror is a later spec over the same driver.

## 3. Behavior

- **B-1 (sources).** `hq mirror add github <owner>/<name> [--clone <path>]`
  records `MirrorSource { source: "github", owner, name, clone: Option<
  PathBuf> }` in `.hq/config.toml` under `[[mirror.sources]]` and creates
  the mirror principal (040 B-2) if absent. `hq mirror remove github
  <owner>/<name>` deletes the config entry; facts and the id map are kept.
  At most one source per `(source, owner, name)`.
- **B-2 (token).** The token is read from `HQ_GITHUB_TOKEN`, else from
  `$XDG_CONFIG_HOME/hq/credentials.toml` (`[github] token = ...`, mode
  `0600`, refused with exit `3` when group or world readable). It is never
  written to `.hq/`, never printed, and never included in any report or
  fact.
- **B-3 (`hq mirror sync`).** `hq mirror sync [--once] [--watch [--interval
  <secs>]] [--dry-run] [--source github:<owner>/<name>]` runs
  `SyncDriver::run_once` for each configured source (or the named one):
  import (040) from the persisted cursor, then export (041), then
  reconcile, persisting the new cursor only after a successful import so a
  failed run re-imports the same window. `--once` is the default. `--watch`
  repeats every `interval` seconds (default 60) until interrupted, with the
  backoff of B-4 layered on top. `--dry-run` runs the import against a
  transaction that is rolled back and the export in dry-run mode, printing
  the plan.
- **B-4 (backoff).** On `Error::Stale` carrying a rate-limit reset the
  driver sleeps until the reset instant plus one second; on a transient
  transport error it retries with exponential backoff (base 5 s, factor 2,
  cap 300 s, at most 6 attempts per run) and then reports the failure; on
  any other error it stops the run and reports. The driver never spins:
  every wait is journaled to stderr with its reason and duration.
- **B-5 (cursors).** `sync.rs` stores per-source `Cursor { issues_since,
  pulls_since, etag_by_url: BTreeMap<String, String>, last_run: Hlc,
  last_report_hash: Hash }` in the id map's `cursors` table (040 B-7).
  `hq mirror status` prints every source with its cursor, the last report,
  and the count of quarantined facts awaiting promotion.
- **B-6 (report).** `SyncReport { source, imported: BTreeMap<String, u32>,
  exported: u32, skipped: Vec<...>, disagreements: Vec<Disagreement>,
  waited_ms: u64, cursor_advanced: bool }` per source, printed in human
  mode as a short table and in JSON mode as an array; the report's hash is
  stored in the cursor so `status` can show whether anything changed since.
- **B-7 (exit codes).** Exit `0` when every source completed (even with
  skipped items), `1` when any source ended in a reported failure, `3` on
  configuration or credential errors.

## 4. Functional requirements

- **FR-001.** `SyncDriver` takes the client, the clock (a `ClockSource`
  from 018 for waits), and a `Sleeper` seam so tests observe backoff
  without real delays.
- **FR-002.** `tests/mirror.rs` drives the binary against the spec 040
  fixtures: `add` then `sync --once` imports `basic`; a second `sync
  --once` imports and exports nothing (`cursor_advanced: false`); a
  simulated rate limit produces the documented wait and then completes; a
  world-readable credentials file exits `3`; `status --json` shows the
  cursor and the report hash; `--dry-run` leaves the ledger unchanged.
- **FR-003.** No test and no code path prints or stores the token; a test
  greps every output and every file under `.hq/` for the fixture token.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-cli --locked --test mirror` passes.
- **AC-2.** Against the recorded fixtures, `hq mirror sync --once` run
  twice appends zero facts the second time and reports it.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0 with the
  new modules claimed here.

## 6. Out of scope

Promotion out of quarantine (094), a server-hosted mirror schedule (later,
over this driver), webhooks, and sources other than GitHub.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-cli --locked --test mirror
cargo test -p hqgit-mirror --locked sync
```
