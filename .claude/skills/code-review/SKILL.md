---
name: code-review
description: "Review the current diff for correctness bugs and spec drift with make spine as the gate, delegate L0/L1 and trust-plane paths to ledger-guardian and trust-reviewer, and emit an evidence-oriented findings list"
allowed-tools: Read, Grep, Glob, Agent, Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git fetch:*), Bash(spec-spine:*), Bash(make:*), Bash(cargo:*), Bash(grep:*)
argument-hint: "[scope] - e.g. \"branch\", \"working tree\", \"crates/hqgit-ledger\""
---

# /code-review: correctness, spec drift, frozen invariants

Reviews the current diff against three questions: does the change have
correctness or edge-case bugs, does it still match its owning spec's
contract, and can it alter a hashed byte or let something unverified
count as verified. Output is an evidence-oriented findings list, each
line citing `file:line`. Nothing authored is modified; `make spine`
regenerates `.derived/` deterministically, and a diff it leaves is itself
evidence (stale shards).

## Step 0: scope the diff

```sh
git fetch origin main
git status --short && git diff --stat && git log --oneline -10
git diff origin/main...HEAD --stat    # committed delta
git diff HEAD --stat                  # uncommitted delta
git diff origin/main...HEAD --name-only; git diff HEAD --name-only
```

Note which classes changed: crate source (`crates/**`, `fuzz/**`,
`executor/**`, `web/**`), specs (`specs/**/spec.md`), standards
(`standards/**`), the harness (`.claude/**`, `AGENTS.md`, `CLAUDE.md`,
`Makefile`, `.github/**`), scripts, docs.

## Step 1: the gate stays green

```sh
make spine                  # compile, index, lint --fail-on-warn, index check, couple, spec-dag
spec-spine index coverage   # ownership: zero unclaimed, zero floor-only
```

- A `couple` failure is the headline finding: cite the file the gate
  named and the owning spec whose declared edges fail to cover it.
- An unclaimed file from `coverage` is a finding against the implementing
  spec's `establishes`.
- A `lint`, `index check`, or `spec-dag` failure is a corpus finding:
  cite the diagnostic verbatim.
- A `.derived/` diff after the run means the shards were stale: a
  finding whose fix is to commit them.

## Step 2: spec-contract match

For each changed source file, confirm the change is consistent with the
contract of its owning spec rather than only with the gate's mechanical
pass. Governed reads, through the CLI:

```sh
spec-spine registry show <spec-id> --json          # declared surface and edges
spec-spine registry relationships <spec-id>        # its typed neighborhood
```

- Does the code do what B-n says and nothing B-n forbids? Cite the label.
- Are the AC-n satisfied verbatim and is `## Verification` runnable?
- If a spec was edited: only `establishes` growth, dated `D-n` entries, a
  dated Status note, and the `implementation` flip are legitimate
  mid-build edits. Anything that changes what the spec requires is a
  coherence-guard finding (`.claude/rules/adversarial-prompt-refusal.md`),
  severity CRITICAL.
- Flag drift where code does something the spec's narrative does not
  describe even when `couple` passes (an over-broad edge).

## Step 3: correctness pass

Read the changed source and look for each of the following, with a
`file:line` and a one-sentence evidence claim:

- Logic and edge-case bugs (off-by-one, unhandled `None` or `Err`, empty
  input, boundary values, integer overflow on untrusted lengths).
- Error-path correctness: the right `Error` variant and the right exit
  code (`0` ok, `1` validation failure or drift, `2` stale, `3` I/O,
  parse, schema, or config; `hq` adopts the same four).
- Rust hygiene the lints enforce: no `unsafe`; no `unwrap`, `expect`, or
  slice indexing in library code; owned data at public boundaries;
  dependencies point downward only; a new crate carries
  `[package.metadata.spec-spine] spec = "<id>"`.
- Determinism hazards anywhere: `HashMap` or `HashSet` iteration reaching
  output, locale- or platform-dependent behavior, unstable ordering in
  emitted JSON.
- Hygiene: stray debug prints, commented-out code, dead branches, secrets
  or seeds in logs.
- House style in authored text: no em dash (`grep -rn $'\xe2\x80\x94'`
  over the changed files), no session links, no AI attribution.

## Step 4: frozen-invariants pass (delegate)

Decide from the changed paths in Step 0. Spawn the specialists with the
`Agent` tool, both in one message when both apply, each given the branch,
the base (`origin/main`), and the owning spec id:

- Any path under `crates/hqgit-types/`, `crates/hqgit-object/`,
  `crates/hqgit-ledger/`, or `fuzz/`: spawn `ledger-guardian`
  (`subagent_type: ledger-guardian`). It runs the vector check, the
  canonical-encoding rules, the ambient-input grep, and the entry, fact,
  tombstone, and object-store rules.
- Any path under `crates/hqgit-trust/`, `crates/hqgit-policy/`,
  `crates/hqgit-policy-sdk/`, `crates/hqgit-agent/`,
  `crates/hqgit-eval/src/cache.rs`, `crates/hqgit-eval/src/provenance.rs`,
  `crates/hqgit-server/src/agent_auth.rs`, or
  `crates/hqgit-server/src/quarantine.rs`: spawn `trust-reviewer`
  (`subagent_type: trust-reviewer`). It checks verification order, key
  windows, transparency inclusion, policy determinism, Biscuit
  attenuation, cache-as-trust-boundary, and self-approval.

Fold their findings into the report under `### Specialists`, keeping each
verdict (`SAFE`, `SAFE WITH NOTES`, `UNSAFE`) and every CRITICAL as a
headline finding with its `file:line`. A changed golden vector under
`crates/hqgit-types/testdata/vectors/` is CRITICAL regardless of what
the diff says about it: a schema MAJOR is a human decision.

Neither path class touched: say "not applicable" under `### Specialists`;
do not skip the section silently.

## Step 5: findings report

```
## Review: <scope>
Base: origin/main | Head: <branch> | Files: <n> | +<a>/-<d>
Gate: make spine <ok|FAIL at target> | coverage <n unclaimed> | derived <clean|stale>
Owning spec: <id> | Mid-build spec edits: <legitimate|coherence-guard finding>

### Findings (severity-ordered)
- [CRITICAL|CORRECTNESS|SPEC-DRIFT|GATE|HYGIENE] <claim> at `file:line`
  Evidence: <one sentence, cited>
  Fix: <specific recommendation>

### Specialists
- ledger-guardian: <verdict | not applicable>; <findings folded above by number>
- trust-reviewer: <verdict | not applicable>; <findings folded above by number>

### Clean
- <dimensions checked with nothing found>
```

If nothing is found, say so plainly and report the gate result and the
specialist verdicts as the evidence. To proceed with fixes, the user (or
`/ship`) names the findings to apply.
