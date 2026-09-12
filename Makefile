# hqgit: the one source of truth for what CI validates (spec 001 B-2).
#
# The shape is the spec-spine kit's composite (kit v18, spec-spine spec 064):
#
#   make gate                 read-only: the whole governed loop, in order
#   make refresh              writing: recompute the committed shard trees
#   make verify SPEC=017-...  one spec's declared acceptance (spec-spine 049)
#
# and two compatibility aliases this corpus's specs name by hand:
#
#   make spine                refresh + gate (spec 000 section 8, spec 003 AC-1)
#   make ci                   spine + the stack gates (spec 010 AC-2)
#
# Every target is guarded so the composite is green on the specify-only tree:
# before spec 010 lands there is no Cargo.toml, before spec 012 no fuzz/.
# `make ci` locally means a green CI run.
#
# The language targets are guarded on a MANIFEST PROBE, not a command probe.
# A tree with cargo installed and no Cargo.toml is the specify-first case, and
# probing for the tool answers the wrong question.

SHELL := /bin/bash
.DEFAULT_GOAL := ci

# The gate chain is ordered, and `spine: refresh gate` states that order as
# two prerequisites. Under `-j` make would run independent prerequisites
# concurrently, so `gate` could read the committed shards while `refresh`
# rewrites them and report a torn or spurious verdict. Nothing here gains
# from parallelism (the cargo targets parallelize internally), so serialize
# the whole file and make the ordering a guarantee rather than a timing
# accident.
.NOTPARALLEL:

SPEC_SPINE ?= spec-spine
# Spec-spine 072 3.3: the coupling base follows the branch this repository
# actually has. The same three steps the push gate resolves with, in the same
# order: $SPEC_SPINE_DEFAULT_BRANCH (make imports the environment, so `?=`
# leaves an exported value alone), then the remote's own HEAD, then `main`.
# An explicit `BASE=` on the command line still wins.
SPEC_SPINE_DEFAULT_BRANCH ?= $(shell git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
BASE ?= origin/$(or $(SPEC_SPINE_DEFAULT_BRANCH),main)
FUZZ_SECONDS ?= 20

# The unresolved-unit refusal is opt-in and OFF on this corpus (spec 001 D-8).
# `check --fail-on-unresolved` refuses while any spec declares a file no code
# has created yet, which on a specify-first corpus of 68 specs is 558 units
# today and stays non-zero until the last wave lands. It is NOT the coverage
# guard below: coverage becomes satisfiable the moment one package carries
# source files, this one only when the corpus builds everything it claims.
# Flip to 1 then, or pass UNRESOLVED_GATE=1 to see where the corpus stands.
UNRESOLVED_GATE ?= 0

.PHONY: gate refresh spine spec-dag ci build test lint fmt deny fuzz coverage attest verify help

## gate: the governed loop, read-only throughout
# A gate that writes repairs what it is meant to judge (spec-spine 046), so
# this uses `check` and never a bare `compile` or `index`.
gate:
	$(SPEC_SPINE) check --fail-on-warn
	@if [ "$(UNRESOLVED_GATE)" = "1" ]; then $(SPEC_SPINE) check --fail-on-unresolved; else echo "check: --fail-on-unresolved off, the corpus does not yet build what it claims (spec 001 D-8)"; fi
	$(SPEC_SPINE) lint --fail-on-warn
	$(SPEC_SPINE) index coverage
	@if [ -f Cargo.toml ]; then $(SPEC_SPINE) index coverage --fail-on-untraced; else echo "coverage: no Cargo.toml yet, reported above and not refused (spec 001 D-7)"; fi
	$(SPEC_SPINE) couple --base $(BASE) --head HEAD
	scripts/spec-dag.sh

## refresh: the writing half, for a session that can commit the shards it regenerates
refresh:
	$(SPEC_SPINE) compile
	$(SPEC_SPINE) index

## spine: refresh + gate (the name spec 000 section 8 and spec 003 AC-1 use)
spine: refresh gate

## spec-dag: depends_on is acyclic and only names lower-numbered specs
spec-dag:
	scripts/spec-dag.sh

## ci: everything CI runs, in order
ci: spine
	$(MAKE) build
	$(MAKE) test
	$(MAKE) lint
	$(MAKE) fmt
	$(MAKE) deny

## build: cargo build (guarded on Cargo.toml)
build:
	@if [ -f Cargo.toml ]; then cargo build --workspace --locked; else echo "build: no Cargo.toml yet (lands with spec 010)"; fi

## test: cargo test (guarded on Cargo.toml)
test:
	@if [ -f Cargo.toml ]; then cargo test --workspace --locked; else echo "test: no Cargo.toml yet (lands with spec 010)"; fi

## lint: clippy with warnings denied (guarded on Cargo.toml)
lint:
	@if [ -f Cargo.toml ]; then cargo clippy --workspace --all-targets --locked -- -D warnings; else echo "lint: no Cargo.toml yet (lands with spec 010)"; fi

## fmt: rustfmt check (guarded on Cargo.toml)
fmt:
	@if [ -f Cargo.toml ]; then cargo fmt --all --check; else echo "fmt: no Cargo.toml yet (lands with spec 010)"; fi

## deny: cargo-deny supply-chain check (guarded on deny.toml and the tool)
deny:
	@if [ -f deny.toml ]; then \
	  if command -v cargo-deny >/dev/null 2>&1; then cargo deny check; \
	  else echo "deny: cargo-deny not installed (cargo install cargo-deny --locked); skipped locally, CI runs it"; fi; \
	else echo "deny: no deny.toml yet (lands with spec 010)"; fi

## fuzz: a short smoke run of every fuzz target (guarded on fuzz/ and cargo-fuzz)
fuzz:
	@if [ -f fuzz/Cargo.toml ]; then \
	  if command -v cargo-fuzz >/dev/null 2>&1; then \
	    for t in $$(cargo fuzz list); do cargo fuzz run "$$t" -- -max_total_time=$(FUZZ_SECONDS) || exit 1; done; \
	  else echo "fuzz: cargo-fuzz not installed (cargo install cargo-fuzz --locked); skipped"; fi; \
	else echo "fuzz: no fuzz/ yet (lands with spec 012)"; fi

## coverage: which source files no spec specifically claims
coverage:
	$(SPEC_SPINE) index coverage

## attest: the corpus attestation (spec-spine's ledger seal), never committed
# The verb writes the attestation itself to
# `.derived/attestation/attestation.json`, which is the path
# `verify-attestation` reads by default; stdout carries a human summary, not
# the document. Redirecting stdout captures the summary and leaves the
# attestation behind, so this target runs the verb and names the file it wrote.
attest:
	$(SPEC_SPINE) attest --with-coupling
	@echo "attestation at .derived/attestation/attestation.json (verify with: spec-spine verify-attestation --recompute)"

## verify: one spec's declared acceptance, e.g. make verify SPEC=017-ledger-entry-dag
# The verb runs what the corpus declares (spec-spine 049), which is why it is
# deliberately not part of `gate`. `--plan` prints the commands and runs none.
verify:
	@test -n "$(SPEC)" || { echo "usage: make verify SPEC=<spec-id>"; exit 3; }
	$(SPEC_SPINE) verify $(SPEC)

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'
