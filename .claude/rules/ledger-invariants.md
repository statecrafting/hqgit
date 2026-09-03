---
paths:
  - "crates/hqgit-types/**"
  - "crates/hqgit-object/**"
  - "crates/hqgit-ledger/**"
  - "fuzz/**"
---

# Ledger invariants (constitution VIII, bootstrap anchor `hash-stability`)

You are touching L0 or L1: the bytes here are hashed, signed, and
replicated. Hash stability is the one mistake the project cannot recover
from.

- Never let a clock, `std::env`, a random source, a `HashMap` or `HashSet`
  iteration, or a float reach a byte that is encoded, hashed, or signed.
  `BTreeMap` is the only map type in these crates; the HLC generator in
  `crates/hqgit-ledger/src/clock.rs` is the one place a clock is read, and
  it is never on a hashing path.
- Canonical DAG-CBOR only (spec 011): definite lengths, shortest integer
  encoding, map keys sorted by (length, bytes), no floats, no indefinite
  items, no tags except the Cid link tag, reject non-canonical input on
  decode. `decode(encode(x)) == x` and `encode(decode(b)) == b`.
- Preserve unknown fields: every evolvable struct carries an `extra` map
  that survives decode and encode and is included in the hash. Never
  reorder, rename, or retype a field inside a schema MAJOR.
- Golden vectors under `crates/hqgit-types/testdata/vectors/` are frozen.
  A failing golden test means the code is wrong, not the vector. Never
  regenerate a vector to make a test pass; a vector change is a schema
  MAJOR, a spec amendment, and a human decision: stop and report.
- Entries (spec 017): `parents` sorted ascending and deduplicated; the
  signing preimage is the canonical bytes without `sig` under the
  `ledger.entry` domain; the entry hash covers the signature; `hlc` is
  strictly greater than every parent's.
- Facts are immutable and merge by set union (spec 019); only derived
  state uses an LWW register. Do not add a CRDT outside `crdt/sequence.rs`.
- The log holds commitments, never content (spec 020): an entry payload is
  a `Cid`; deletion is a tombstone plus a blob erase, never a rewrite;
  chain verification must still pass after erasure.
- Run `cargo test -p hqgit-types --locked golden` and `make fuzz` (when
  cargo-fuzz is installed) before claiming the change is done, and ask the
  `ledger-guardian` agent to review.
