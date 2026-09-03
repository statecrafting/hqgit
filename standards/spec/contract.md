# hqgit spec contract (normative summary)

A one-page operational summary of the bootstrap spec
(`specs/000-hqgit-bootstrap/spec.md`) and the corpus conventions the thesis
(`specs/002-platform-thesis/spec.md`) fixes. The bootstrap spec and the
constitution are authoritative; where this summary is terser, they govern.

## Inputs (authored truth: markdown only)

- `specs/NNN-slug/spec.md`: one spec per directory; directory name equals
  `id`; `NNN` is a unique three-digit ordinal that is also the build order.
- `standards/spec/`: the constitution, this contract, and templates.
- `spec-spine.toml`: the repo's configuration (owned by spec 001).
- `docs/design/`: design analysis cited from specs with non-owning
  `references` edges. Prose, not authority.

## Outputs (machine truth: compiler-owned JSON, read via `spec-spine` only)

- `.derived/spec-registry/by-spec/<id>.json`: spec-as-source shards.
- `.derived/codebase-index/by-spec/<id>.json` and `.../by-package/<slug>.json`:
  code-as-source shards.
- `.derived/**/build-meta.json`: wall-clock metadata, gitignored.

Both shard trees are committed. `spec-spine compile --check` and
`spec-spine index check` compare the working tree against them.

## Required frontmatter

`id`, `title`, `status` (`draft` / `approved` / `superseded` / `retired`),
`created` (`YYYY-MM-DD`), `summary`. In this corpus every ordinary spec also
carries `kind` (closed enum), `domain` (the layer, closed enum),
`implementation`, `risk`, `authors`, `wave` (build-order wave, 1 to 8), and
`depends_on` (never empty except on the bootstrap spec).

## Typed edges (8; `references` is the only non-owning one)

`establishes`, `extends`, `refines`, `supersedes`, `amends`, `co_authority`,
`constrains`, `references`. `origin` is a bootstrap marker, not an edge.

## Authority units

`file` (bare string shorthand; trailing slash is a subtree), `section`
(`{file, anchor}`), `symbol` (`{id}`), `directory`, `crate`, `module`.
This corpus claims a crate's manifest and each source file explicitly; test
and fixture directories are claimed as subtrees.

## Lifecycle as scheduling

- `status: approved` + `implementation: pending`: a work order. The
  orchestrator (claude-observatory) schedules the lowest-numbered one whose
  `depends_on` are all shipped.
- `status: draft`: never schedulable, visible as a blocker. Approval is a
  human act.
- `implementation: n-a` (thesis, bootstrap) and `complete` count as shipped,
  pinned at the sha256 of their `spec.md`. Amending a shipped spec invalidates
  every transitive dependent until it re-verifies.
- `depends_on` MUST be acyclic and MUST only name lower-numbered specs.

## The gate chain

`compile` → `index` → `lint --fail-on-warn` → `couple`, plus
`index coverage --fail-on-untraced` in CI. `[coupling] require_ownership` is
on: a changed source file no spec specifically claims is `C-002`. Cargo
gates (`build`, `test`, `clippy`, `fmt`, `deny`) run whenever `Cargo.toml`
exists. A spec's `## Verification` block is what the verify stage runs after
merge.

## Determinism

Pure function of `(config, file contents)`; byte-identical output; staleness
by content hash alone. The same rule governs the system's own L0/L1 encoding
(constitution VIII).
