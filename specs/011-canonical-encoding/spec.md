---
id: "011-canonical-encoding"
title: "Canonical encoding: deterministic DAG-CBOR, the Value model, envelopes, unknown-field preservation"
status: approved
kind: "kernel"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "010-workspace-and-core-types"
establishes:
  - "crates/hqgit-types/src/codec/mod.rs"
  - "crates/hqgit-types/src/codec/cbor.rs"
  - "crates/hqgit-types/src/codec/envelope.rs"
  - "crates/hqgit-types/src/codec/value.rs"
  - "crates/hqgit-types/testdata/vectors/"
  - "crates/hqgit-types/tests/codec.rs"
extends:
  # The codec module is re-exported from the crate root 010 founded.
  - { spec: "010-workspace-and-core-types", unit: "crates/hqgit-types/src/lib.rs", nature: additive }
  # The crate manifest gains the serde and CBOR dependencies.
  - { spec: "010-workspace-and-core-types", unit: "crates/hqgit-types/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The one serialization every hashed and signed byte in hqgit passes
  through. This spec fixes canonical DAG-CBOR (RFC 8949 deterministic
  encoding under the IPLD DAG-CBOR restrictions: definite lengths, shortest
  integers, length-then-bytes key order, no floats, no indefinite items, no
  tags except the link tag), the in-memory Value model it encodes, the
  versioned Envelope every object is wrapped in, and the unknown-field
  preservation rule that lets a newer writer's fields survive an older
  reader byte for byte. It establishes the golden vector corpus that spec
  012 gates and every later release must reproduce. Nothing here reads a
  clock or the environment; decode of encode is the identity and encode of
  decode is the identity on canonical bytes, and both are frozen at tier 1.
---

# 011: Canonical encoding

## 1. Purpose

Constitution VIII and bootstrap anchor `hash-stability`: any nondeterminism
in canonicalization silently invalidates every signature downstream, and a
signed history can never be rewritten. Thesis §4.2 chose DAG-CBOR with
forward-compatible unknown-field preservation (D7). This spec is where that
choice becomes bytes. It is deliberately the second spec built, before any
object or entry exists, so that the first signed entry (017) is already
encoded under the rules that will hold for the life of the ledger. Every
later spec that says "canonical bytes" means the output of this module.

## 2. Territory

`crates/hqgit-types/src/codec/` inside the crate 010 founded: `mod.rs` (the
`Canonical` trait and the public entry points), `cbor.rs` (the encoder and
the strict decoder), `value.rs` (the `Value` model), and `envelope.rs` (the
versioned wrapper). The golden vector corpus under
`crates/hqgit-types/testdata/vectors/` is established here and extended by
later specs (017 adds `ledger/`, 027 adds `attestation/`). The codec test
file is `tests/codec.rs`; the whole-corpus golden test is spec 012's
`tests/golden.rs`.

## 3. Behavior

- **B-1 (`Value`).** `enum Value { Null, Bool(bool), Int(Int), Bytes(Vec<u8>),
  Text(String), Array(Vec<Value>), Map(BTreeMap<String, Value>), Link(Cid) }`
  where `Int` is `enum Int { Neg(u64), Pos(u64) }` (`Neg(n)` denotes the
  integer `-1 - n`, CBOR major type 1) so every 64-bit integer is
  representable without a float. `Map` keys are text only, held in a
  `BTreeMap` so iteration is deterministic in memory; encoding re-sorts by
  the canonical key order of B-2, which differs from `BTreeMap`'s
  lexicographic order. There is no float variant anywhere in the model.
- **B-2 (canonical encoding rules).** `encode(&Value) -> Vec<u8>` MUST
  produce: definite-length items only; integers in the shortest form that
  holds the value (RFC 8949 §4.2.1); text as UTF-8 major type 3, bytes as
  major type 2; map keys sorted first by encoded length then by bytes
  (RFC 8949 §4.2.1 core deterministic order, which the IPLD DAG-CBOR
  specification requires); no duplicate keys; `Link` as CBOR tag 42 over a
  byte string of `0x00` followed by the CIDv1 binary form of the `Cid`
  (`0x01`, the multicodec varint, `0x1e` for BLAKE3-256, `0x20`, the 32
  hash bytes), which is the only tag the encoder emits; `Null`, `Bool` as
  the simple values `0xf6`, `0xf4`, `0xf5`. There is no float encoding path.
- **B-3 (strict decoding).** `decode(&[u8]) -> Result<Value, Error>` MUST
  reject, as `Error::Parse` naming the byte offset: indefinite-length items,
  a non-shortest integer, a map key that is not text, a duplicate key, keys
  out of canonical order, any tag other than 42, a tag 42 payload that is
  not a well-formed BLAKE3-256 CIDv1 with a `DagCbor` or `Raw` codec, any
  float (major type 7 with additional information 25, 26, or 27), any
  simple value other than null and the two booleans, invalid UTF-8 in text,
  trailing bytes after the top-level item, and nesting deeper than 128. A
  decoder that accepts a non-canonical form is a hash-stability defect.
- **B-4 (round trip).** For every `v: Value`, `decode(encode(v)) == v`, and
  for every byte string `b` that `decode` accepts, `encode(decode(b)) == b`.
  These two identities are the contract 012's fuzz targets check.
- **B-5 (`Canonical`).** `trait Canonical: Sized { fn to_value(&self) ->
  Value; fn from_value(v: Value) -> Result<Self, Error>; fn to_canonical
  (&self) -> Vec<u8> { encode(&self.to_value()) } fn from_canonical(b: &[u8])
  -> Result<Self, Error> { Self::from_value(decode(b)?) } fn canonical_hash
  (&self) -> Hash { Hash::of(&self.to_canonical()) } }`. Types implement
  `to_value` and `from_value` by hand or through a serde bridge
  (`serde_value::to_value` and `from_value`, provided in `mod.rs`, which
  rejects floats at the bridge); the serde bridge is a convenience, never a
  second encoding: only `cbor.rs` turns a `Value` into bytes. The core
  types of spec 010 (`Hash`, `Cid`, `Principal`, `KeyId`, `Signature`,
  `Hlc`) implement `Canonical` here with the wire forms 010 fixed.
- **B-6 (unknown-field preservation).** Every evolvable struct carries
  `extra: BTreeMap<String, Value>` and implements `from_value` so that any
  map key it does not recognize lands in `extra` verbatim, and `to_value`
  emits `extra` back into the same map; keys of `extra` MUST NOT collide
  with the struct's own keys (`Error::Validation` on construction). A
  reader therefore re-encodes a newer writer's object byte for byte and
  hashes it identically. A struct without `extra` is a frozen leaf type
  (the spec 010 value types) and MUST be documented as such.
- **B-7 (`Envelope`).** `Envelope { v: SchemaVersion, kind: String, body:
  Value, extra }` is the wrapper for every versioned object (013 objects,
  019 facts, 027 attestations). `SchemaVersion { major: u16, minor: u16 }`
  encodes as a two-element array; `kind` is a namespaced lowercase string
  (`"object.tree"`, `"fact.change.opened"`); the map keys are `body`,
  `kind`, `v`, plus `extra`. A reader MUST accept any `minor` of a known
  `major`, MUST refuse an unknown `major` as `Error::Schema`, and MUST
  preserve fields it does not know (B-6). `Envelope::open(expected_kind,
  max_major) -> Result<Value, Error>` is the checked accessor.
- **B-8 (golden vectors).** `testdata/vectors/<area>/<name>.json`, one JSON
  document per vector with the keys `description`, `input` (a JSON encoding
  of the `Value` using the convention `{"$bytes": hex}`, `{"$link":
  "<codec>:<hex>"}`, `{"$int": "-9223372036854775809"}` for values JSON
  numbers cannot carry), `canonical_hex`, and `hash` (the BLAKE3 hex of the
  canonical bytes). This spec establishes the `codec/` area with at least:
  every integer boundary (0, 23, 24, 255, 256, 65535, 65536, 2^32 - 1, 2^32,
  2^64 - 1, -1, -24, -25, -2^64); key ordering by length then bytes; nested
  arrays and maps; a link; empty containers; a text vector with multi-byte
  and combining UTF-8; a bytes vector; an envelope. Vectors are frozen
  (constitution VIII): a change to any `canonical_hex` or `hash` is a
  schema MAJOR and a human decision (012 B-5).
- **B-9 (no ambient input).** The module reads no clock, no environment,
  and iterates no `HashMap`; it allocates no global state. Spec 010 FR-003's
  source guard covers it.

## 4. Functional requirements

- **FR-001.** The encoder and decoder are pure functions over their
  arguments with no `unsafe` and no dependency on the host's endianness
  or pointer width; integer widths are explicit.
- **FR-002.** Tests cover: every B-3 rejection with the offset asserted;
  the B-4 identities on a hand-written corpus; every 010 value type's wire
  form against the vectors; unknown fields surviving `from_value` then
  `to_value` on an evolvable fixture struct with the hash unchanged; a
  colliding `extra` key refused; `Envelope::open` on a wrong kind, an
  unknown major, and a newer minor; the serde bridge refusing a float.
- **FR-003.** A test walks `testdata/vectors/codec/` and, for each vector,
  decodes `input`, encodes it, and asserts `canonical_hex` and `hash`; then
  decodes `canonical_hex` and asserts equality with the decoded input.
- **FR-004.** The third-party dependency set added here is at most `serde`
  and one CBOR primitive crate (`ciborium-ll` or a minimal in-tree
  encoder); the encoder's canonical rules are implemented in `cbor.rs`
  rather than trusted to a library's defaults, and a test pins the
  dependency versions used.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-types --locked` passes, including the
  vector walk of FR-003.
- **AC-2.** Encoding the same `Value` on two different platforms in CI
  (spec 012's matrix) yields identical bytes; this spec's own AC is the
  local half: `cargo test -p hqgit-types --locked codec` passes twice with
  identical output.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0 on the
  branch.

## 6. Out of scope

The fuzz targets and the CI matrix that gate these bytes (012); the object
kinds encoded through this codec (013); the ledger entry's specific key set
and signing preimage (017); any streaming or incremental encoder (a whole
object is encoded in memory; large content is chunked by 014, never encoded
as one CBOR item).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-types --locked codec
cargo test -p hqgit-types --locked
```
