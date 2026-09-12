# 02: Portable evidence integration with the Statecraft family

Author: Bartek Kus. Written 2026-09-11 against HEAD `936eb6c`.

**Status: design record, not a spec.** Nothing here is approved, nothing
here mints a spec ordinal, and nothing here amends a spec. It answers the
September 11 hqgit handoff packet (actions 1, 2, 3, 4, 7, 8), separates what
was verified from what is recommended and what is still undecided, and
proposes the exact spec changes a human would have to make to adopt any of
it. The hosted topology and transport questions (actions 5 and 6) are in
`03-hosted-topology-and-transport.md`.

The thesis (`specs/002-platform-thesis/spec.md`) is not revised by this
document. Section 2 concludes that it does not need to be.

---

## 1. Verified baseline

Read-only, 2026-09-11, `spec-spine 0.18.0`:

| Fact | Evidence |
|---|---|
| `spec-registry: fresh`, `codebase-index: fresh`, exit 0 | `spec-spine check` |
| 68 specs, all `status: approved`, 0 draft | `spec-spine registry status-report --json` |
| 64 `implementation: pending`, 1 complete (001), 3 `n-a` (000, 002, 003) | frontmatter of `specs/*/spec.md` |
| ready set is exactly `010-workspace-and-core-types`; 63 blocked | `spec-spine registry plan` |
| no `crates/`, `fuzz/`, `executor/`, `web/` on disk | `ls` |
| `coverage: no source files under any discovered package` | `spec-spine index coverage` |

The packet's baseline (HEAD `b93767b`, 64 pending, registry and index fresh)
is **confirmed**. HEAD has since moved to `936eb6c`, a harness chore
(`chore(001): adopt the kit's shepherd severity triage`), so the code
baseline is unchanged: hqgit still has no application code.

Facts verified in the sibling repositories, also read-only:

- `statecraft-cli` receipts are canonical JSON with SHA-256 over the
  canonical bytes. `members/src/orchestrator/journal.ts` canonicalizes
  (code-point key order, integers only, well-formed strings only), serializes
  without whitespace, and hashes with `sha256Hex`. `recordHash` covers
  `{seq, ts, kind, payload, prevHash}`.
- **`statecraft-cli` evidence carries no cryptographic signature.** A
  repository-wide search for `ed25519`, `createSign`, `generateKeyPair`,
  `sigstore` and `minisign` matches only prose: `specs/039-attested-export`
  (`implementation: complete`) states it explicitly, "Ed25519 sealing stays
  out of scope: key custody is an operator decision no export path should
  default." The word *seal* in that repository means a hash-chain append, not
  a signature. The family realignment's phrase "the CLI's separate
  seal/signing pass already exist" conflates the two; this is a correction,
  not a defect in the CLI.
- `spec-spine` already separates a reproducible payload from a detached
  signature: `CorpusAttestation` is a pure function of `(config, file
  contents)` carrying `inputsManifestHash` and `registryHash` (SHA-256), and
  `LedgerSeal { alg: "ed25519", keyId, signedAt, sig }` signs the 32-byte
  attestation hash out of band. That is the shape hqgit should reference,
  not re-encode.
- Licences as declared on disk: hqgit AGPL-3.0 (`LICENSE`, `README.md:92`,
  and `specs/010` B-1 pins `license = "AGPL-3.0-only"` for the whole
  workspace); `statecraft-cli`, `spec-spine` and `rahi` Apache-2.0.

### 1.1 A measured property of the current export

`statecraft-cli/docs/evidence/journal-bundle.json` is a real committed
bundle (`format: observatory-journal-export`, `formatVersion: 1`,
`policyVersion: 1`, project `claude-observatory`, 1038 work records and 52
decision records). Recomputing every record hash from the bundle alone:

```
verbatim recomputed ok: 727   mismatched: 0   skipped (redacted/withheld): 363
```

All 727 verbatim records re-bind to the chain offline. The other 363 cannot,
by construction: `export.ts` says so in its own header comment, because
`recordHash` covers the whole payload and a stripped payload can never be
re-hashed. **One third of the real bundle is privacy-redacted and therefore
outside offline verification.** Section 4.3 returns to this; it is the
sharpest measurable thing hqgit would change.

The committed bundle predates spec 121, so it contains no
`acceptance.receipt` and no `attestation` block. The receipt shape below is
read from source, not from that file.

---

## 2. Scope comparison: the roadmap versus the smallest experiment

### 2.1 The full roadmap

68 specs, eight waves (thesis §6): ledger and CLI (wave 1), the GitHub
mirror (2), stacked changes and semantic review (3), trust plane and policy
engine (4), the evaluation plane (5), projections and the hosted edge (6),
agent principals (7), federation (8).

### 2.2 The smallest experiment

The experiment of section 4 needs, transitively and exactly:

```
010 011 013 014 017 018 019 020 021 023 024 025 026 027 031 032 033 034
```

That is the `depends_on` closure of `034-cli-attest-and-verify`, computed
from spec frontmatter. Add `012-hash-stability-gate`: no `depends_on` edge
demands it, but `023` and `027` both run `cargo test -p hqgit-types --locked
golden` in their `## Verification` block, and `crates/hqgit-types/tests/golden.rs`
is established by `012`. **Nineteen specs.** Section 8 proposes recording
that latent edge.

Deferred by the experiment: 015, 016 (verified streaming, remote objects),
028 (issues), the whole of waves 3 through 8. `040` through `042` are not
required, though section 5 of this document reuses `040`'s trust shape.

### 2.3 The finding that matters

**The experiment requires no departure from the approved thesis and no
change to any `depends_on` edge.** Its nineteen specs are a prefix of the
ordinal order the orchestrator already walks, in the order it already walks
it. The packet asked which dependencies must be changed; the answer is none.

What the experiment adds is one new spec *after* `034` (section 3.5) and two
governance amendments that are independent of it (document 03).

This is a real result and it cuts both ways. It means integration costs
hqgit nothing in design churn. It also means the price of entry is the whole
of wave 1, and no amount of scope trimming makes that smaller, because
signature, revision-bound approval and a rebuildable view each sit below
`034`. Section 10 recommends accordingly.

---

## 3. The import and reference contract

### 3.1 The constraint, stated exactly

hqgit's `Hash` is BLAKE3-256 and nothing else (`010` B-4: a
`repr(transparent)` newtype over `[u8; 32]`, "the BLAKE3-256 output",
`Hash::of` the only constructor from content). `Cid { codec, hash }` carries
a multicodec but no hash-algorithm field (`010` B-5). `Attestation.subject`
is a `Hash` (`027` B-1). There is therefore **no field in the frozen wave-1
types that can hold a foreign SHA-256 digest as an identifier**, and
inventing one would be a schema MAJOR.

`027` B-7 already refuses the obvious wrong answer: `from_in_toto` "accepts
a statement whose subject carries a `blake3` digest and rejects one that does
not (`Error::Validation`); any other digests are kept in `extra` under
`digests`." A Statecraft receipt has no BLAKE3 digest, so it cannot enter
hqgit through the in-toto door as written. That is correct behaviour, not a
bug: it is the type system refusing to pretend two identifiers are
interchangeable.

### 3.2 The contract

Three rules, all additive, none touching a frozen byte layout.

**R-1. The original bytes are the object.** The exact bytes the CLI
serialized (the canonical JSON of the journal record, or of the whole
bundle) are stored verbatim as a spec 013 `Raw` object. hqgit's handle on
them is `Cid { codec: Raw, hash: Hash::of(bytes) }`, a BLAKE3 cid over bytes
it did not author and does not reinterpret. Nothing is re-serialized, no key
is reordered, no field is dropped.

**R-2. The foreign identity travels in the claim, never in `subject`.** A
new predicate carries the source's own algorithm and digest as data:

```
hqgit/external-evidence/v1 {
  source:        "statecraft-cli" | "spec-spine" | String,
  schema:        String,            // e.g. "acceptance.receipt@1"
  digest_alg:    "sha-256",         // the source's algorithm, named
  digest:        String,            // the source's own identifier, lowercase hex
  bytes:         Cid,               // R-1: the preserved bytes, Raw, BLAKE3
  observed_by:   Principal,         // always Service; see section 5
  binding:       Option<Binding>,   // R-3
}
Binding { kind: "git-commit", value: String }   // e.g. candidateSha
```

`digest` is the CLI's `recordHash` (or spec-spine's `attestationHash`), byte
for byte, labelled with the algorithm that produced it. A reader that does
not understand `digest_alg` must refuse, never coerce. `subject` stays a
BLAKE3 `Hash`: the `RevisionId` the evidence is about.

**R-3. Revision binding is checked, not asserted.** A receipt names
`repo.candidateSha`. The importer resolves that git commit through spec 031
`import_commit` to a tree `Cid`, finds the `Revision` whose `tree` equals it,
and uses that `RevisionId` as `subject`. If no such revision exists, the
import refuses with `Error::Validation` naming the sha. This is the same rule
`103` B-2 already applies to `evidence.attached` ("every named attestation's
`subject` MUST equal `revision`"), applied at the boundary instead of at
assembly.

### 3.3 What is *not* preserved, said plainly

- A redacted or withheld record cannot be re-bound to its chain offline.
  That is a property of the CLI's export policy (measured in §1.1), and
  importing it into hqgit does not repair it. The import records
  `withheldPayload` and `withheldFields` verbatim and the evidence view
  shows them as *not offline-checkable*, never as verified.
- hqgit's BLAKE3 cid and the CLI's SHA-256 `recordHash` are two identifiers
  for the same bytes. They are not interchangeable, they are not derivable
  from each other, and no view may print one where the other is meant.

### 3.4 A preserved-byte example, recomputed

From the real committed bundle, work chain, `seq: 484`. Canonical bytes as
`stableStringify` produces them (285 bytes, no whitespace, code-point key
order):

```
{"kind":"stage.verify.result","payload":{"needsHuman":false,"outcome":"not-declared","sha":"046916f4c2c31189dc03387bd806ab8032ed5e06","specId":"026-standby-daemon"},"prevHash":"66ef6d92043a0ddbc65daee840df8083f49eabc7d03f59458b3d2d95186bf862","seq":484,"ts":"2026-08-01T19:36:12.013Z"}
```

Recomputed independently (Python, not the CLI's own code):

```
sha256(canonical bytes) = f81cd90a280acac3478dea5e645b474e252e168bf6446f5b8a658e26af10497b
  matches the bundle's  recordHash
sha256(canonical payload) = eeca05f415f4a9966a3d4e9a68f9c1e001180123bfdb49180d64f7ef53bddbc7
  matches the bundle's  payloadHash
```

Under R-1 and R-2 hqgit would store those 285 bytes as a `Raw` object and
issue one `hqgit/external-evidence/v1` attestation with `digest_alg:
"sha-256"`, `digest: "f81cd90a..."`, `bytes: raw:<blake3 of the 285 bytes>`.

The BLAKE3 side is deliberately **left uncomputed here**. `Hash::of` does not
exist yet (spec 010 is the ready set, not the built set), and this repository
does not publish digests it cannot reproduce with its own frozen encoder.
The fixture corpus of §3.5 is where those values get frozen, once there is
an encoder to freeze them with.

### 3.5 Where this contract would live

A new spec, proposed ordinal **043** (`040` through `042` are taken, `043`
through `049` are free), wave 2, `depends_on: 034-cli-attest-and-verify`,
`kind: feature`, `domain: l7-edge`. It would `extend` `027`'s `predicate.rs`
with the claim schema (the mechanism `103` already uses) and `032`'s clap
tree with `hq import statecraft <bundle.json>`.

**Minting that ordinal is a human act.** The September 11 realignment says
in terms that it does not "assign new spec IDs", and this repository's
process says a spec is born `draft` and approval is a human flip. The
proposal is recorded here; the spec is not written.

---

## 4. The experiment

One bounded experiment, stated so it can be refused on its merits.

### 4.1 Steps

1. **Ingest.** `hq import statecraft <bundle.json>` into a repository
   initialised over the customer's existing git worktree. Every record lands
   in the **quarantine namespace** (`021` B-6), issued by a `Service`
   principal, exactly as `040` B-2 requires for mirrored state and
   constitution XV requires for everything unverified.
2. **Bind.** For each `acceptance.receipt`, resolve `repo.candidateSha`
   through `031`, find or open the `Change`, and issue one
   `hqgit/external-evidence/v1` attestation whose `subject` is that
   `RevisionId` (R-3).
3. **Review.** A human runs `hq review approve <change> --revision N`
   (`033` B-6): an `hqgit/approval/v1` attestation over that exact
   `RevisionId`, signed by the reviewer's own key, in `main`, not quarantine.
4. **Export.** The repository itself is the export. `.hq/` is content
   addressed and clonable; there is no second bundle format to invent.
5. **Verify offline.** `hq verify` (`034` B-3) with networking disabled:
   walks the whole DAG, checks every entry's hash links and signature against
   keys the ledger itself records, checks every attestation's signature and
   claim shape, and reports *every* failure rather than the first.
6. **Rebuild.** `hq change show` folds `ChangeView`, `ThreadView` and
   `ApprovalView` from the ordered fact sequence with no database of
   Statecraft's present, and reports the approval as `Current` or
   `Stale { latest }` (`026` B-5).

### 4.2 Negative cases the experiment must demonstrate

The packet's acceptance criteria, mapped onto mechanisms that already exist
in the corpus:

| Case | Expected behaviour | Mechanism |
|---|---|---|
| Tampering | one byte flipped in the preserved bytes: import refuses; post hoc, `hq verify` reports the claim object failing | `013` content addressing, `034` B-3 |
| Wrong revision | `candidateSha` resolves to no revision of this change: refuse, exit 1, naming the sha | R-3, `Error::Validation` |
| Replay | the same record imported twice: second import is a no-op naming the existing attestation id | id map keyed `(source, schema, digest)`, `040` B-7's shape |
| Untrusted issuer | importer key absent from `identity.created` / `identity.key_rotated`: listed under `unknown_keys`, fails only under `--strict` | `034` B-3 |
| Unsupported schema | `schemaVersion != 1`, `formatVersion != 1`, or `digest_alg` unknown: refuse with `Error::Schema`, exit 3 | `010` B-9 |
| Redacted record | carried, shown as not offline-checkable, never counted as verified | §3.3 |
| Erased content | claim object tombstoned: `"claim": "erased"`, signature still verifies, exit 0 | `034` B-6, `020` |

### 4.3 What is gained over the current export

Measured or spec-grounded, not asserted:

1. **Attribution.** Every entry and every attestation is Ed25519-signed over
   frozen signing bytes with domain separation (`017`, `027` B-2), verifiable
   by someone who never contacted the producer. The current bundle has no
   signature at all (§1): it proves a file is internally consistent with
   itself, which anyone can manufacture.
2. **Revision binding as an object, not a boolean.** `receiptCovers(receipt,
   headSha)` compares one sha. hqgit gives a `Change` with an ordered
   `Revision` sequence (`024` B-2, numbers derived from the total order so
   every replica numbers identically) and approval staleness as a query over
   it. "Approved at revision 3, revision 4 has landed since" is not
   expressible today.
3. **A view rebuilt from evidence alone.** The CLI's `foldState` is, in its
   own comment, "a placeholder (spec 011's honest minimum)" that groups
   records by kind. `ChangeView`/`ThreadView`/`ApprovalView` are total folds
   with a defined convergence rule and a warning vocabulary that never
   silently drops a fact (`024` B-4).
4. **Erasure without losing verifiability.** This is the measurable one.
   Today, privacy costs offline verification: 363 of 1090 records in the real
   bundle cannot be re-bound. Under constitution X the log holds commitments,
   content lives in the object store, and erasure is a tombstone: `034` B-6
   reports `"claim": "erased"` and **still exits 0**. Same privacy, chain
   intact.
5. **One evidence primitive that carries foreign evidence intact.** Section 3
   adds a predicate, not a noun (constitution IX).

### 4.4 What is *not* gained, and must not be claimed

- Signing an import does not make the CLI's observations true. It attests
  that a named `Service` principal observed these exact bytes at this point
  in the chain. Whether `make gate` really ran on a customer-controlled
  machine is outside every signature in this design.
- Importing does not retroactively sign the CLI's history. The CLI's records
  remain unsigned; hqgit signs its *observation* of them.
- hqgit does not verify spec-spine's corpus verdict. A carried
  `CorpusAttestation` is recomputable only by spec-spine against the
  repository, exactly as CLI spec `039` already reports it.

---

## 5. Trust, stated truthfully

The packet's fourth action is the one most likely to be got wrong under
product pressure, so it is written as rules.

**T-1. An issuer signature is not an authorization.** A valid signature
establishes attribution and integrity of bytes. It establishes nothing about
whether the signer was permitted to make the claim, nor whether the claim is
true. Authorization is `065`/`067`'s deterministic predicate over verified
evidence, and it is a separate, later question.

**T-2. An importer observation is not the reviewer's act.** The corpus
already gets this right and it must stay right: `040` B-6 turns a GitHub
`APPROVED` review into predicate `hqgit/mirror/v1` with a claim naming the
external source, issued by the mirror principal, and says in terms
"**Neither is an `hqgit/approval/v1`: the mirror observes, it does not
approve.**" `hqgit/external-evidence/v1` inherits that rule verbatim: an
imported Statecraft receipt or a GitHub approval is never an
`hqgit/approval/v1`, and the importer is always `Principal::Service`, never
the human whose name appears in the source payload.

**T-3. Four independent outcomes, never one boolean.** Every evidence view
reports, separately: byte integrity (does the preserved object hash match),
signature validity (does the issuer's key verify the preimage), issuer trust
(is that key one the ledger records, and under `--strict` does an unknown key
fail), and subject binding (does `subject` equal the revision under review).
`034` B-3's `VerifyReport` already has the shape; `--strict` already
separates issuer trust from signature validity; `027` B-5's
`ClaimVerdict::Unregistered` already refuses to collapse "unknown" into
"invalid". Nothing here needs inventing, only holding.

**T-4. Three verifiers, three responsibilities.** They share fixtures and
must not ship three different "proof valid" booleans:

| Verifier | Answers | Never answers |
|---|---|---|
| neutral, permissive | envelope well-formed, subject references resolve, evidence linkage consistent, declared algorithms supported | whether an issuer is trusted, whether a corpus verdict is right |
| spec-spine | recomputes `CorpusAttestation` against the repository at the same `tool.version` | anything about hqgit signatures or review history |
| hqgit | entry chain, signing bytes, attestation signature and claim shape, identity and rotation (`060`, `064`), the projected change view | whether the observed commands really ran |

**T-5. The evidence view names its source.** Every rendered item carries
`source`, `digest_alg`, `observed_by`, and its four T-3 outcomes. A reader
must be able to see, without reading code, that an item is an importer's
observation of an unsigned third-party record.

---

## 6. Imported GitHub facts: ownership and synchronization

The packet asks for explicit ownership and a minimal starting posture.

**Verified:** `040` (import) is `implementation: pending`, wave 2, and
already quarantines everything it writes (`040` B-2 refuses to write to
`main`, `Error::Policy`). `041` (export and reconciliation) and `042` (the
sync loop) are separate, later specs.

**Recommendation (no spec change required):** for any pilot, build `040`
only. Import is observation; it is loop-safe because it never writes back.
Bidirectional mirroring (`041`) introduces the reconciliation and
loop-avoidance problem and should not be on a first paying workflow's path.
The ordinal order already produces this outcome; the recommendation is to
*stop* after `040` rather than continue, and to record that as a scope note
when `040` is built.

**Ownership rule:** an imported GitHub fact is owned by the mirror `Service`
principal and lives in quarantine until `094` (wave 6) promotes it by
capability. Until `094` exists there is no promotion, and that is the correct
state, not a gap: a pilot that needs promoted GitHub facts is asking for
wave 6.

---

## 7. Licensing and packaging boundary

**Verified, and it is a hard constraint.** `010` B-1 pins
`license = "AGPL-3.0-only"` in `[workspace.package]` for the whole hqgit
workspace, `hqgit-types` included. `statecraft-cli`, `spec-spine` and `rahi`
are Apache-2.0. `003` B-8 records the sanctioned direction: Apache-2.0 into
AGPL-3.0, never the reverse, and "no hqgit code moves into rahi without that
relicensing being explicit in the contributing change."

Therefore:

- **A permissive neutral verifier cannot link any hqgit crate.** Not
  `hqgit-types`, not the codec. This is not a packaging inconvenience to
  route around; it is the licence the repository declares.
- **What hqgit can offer instead is a specification.** The canonical encoding
  (`011`), the entry signing preimage (`017`), the attestation preimage and
  domain separation (`027` B-2) and the golden vectors (`011`, `012`) are
  sufficient for an independent implementation. A neutral verifier
  re-implements them; it does not import them.
- **The golden vectors are data and their licence is not settled.** They sit
  under `crates/hqgit-types/testdata/vectors/` and would inherit AGPL with
  the crate. Publishing them under a permissive licence so a neutral verifier
  can use them as conformance fixtures is a **copyright-holder decision**, not
  an engineering one, and it is listed as an open decision in section 9.
- **No legal promise is made here.** This section records declarations found
  on disk and the boundary they imply. It is not legal advice, and "AGPL
  internals can simply move into Apache CLI/Rahi packages" is exactly the
  assumption the packet warned against and that the declarations refuse.

The practical consequence for the family: the neutral verifier's home in the
CLI workspace (the realignment's proposal) works for CLI and spec-spine
records. For hqgit records it can verify only what an independent
implementation of the frozen formats can verify, and the fixtures it
verifies against need the licence decision above before they can be shipped
with it.

---

## 8. Proposed spec changes

Each one needs a human. None has been made.

**P-1 (new spec, ordinal 043, `draft`).** The import and reference contract
of section 3. Wave 2, `depends_on: 034`, extending `027`'s `predicate.rs`
and `032`'s clap tree. Fixture corpus with the negative cases of §4.2.
*Blocked on: a human minting the ordinal.*

**P-2 (`023` and `027`, frontmatter).** Add `012-hash-stability-gate` to
`depends_on`. Both run `cargo test -p hqgit-types --locked golden` in their
`## Verification` block, and that test file is established by `012`, so
neither can satisfy its own acceptance without it. The edge is latent today
and only invisible because ordinal order happens to build `012` first.
Acyclic and lower-numbered, so `scripts/spec-dag.sh` stays green.
*Severity: low. It is a correctness gap in the DAG, not a blocker.*

**P-3 (`033` B-6 versus `027` B-4, a contradiction to resolve, not to
patch).** `027` B-4 fixes the approval claim schema as
`{ revision: RevisionId, verdict: Approve | RequestChanges, comment:
Option<String> }`. `033` B-6 says `hq review approve` issues a claim
`{ "change", "revision", "note" }`: no `verdict`, `comment` renamed `note`,
and an extra `change` key. Under `027` B-5's registered validator, `033`'s
claim is malformed. Related: `026` B-5's `Approval` has no verdict field, so
`RequestChanges` has no fold and no CLI verb anywhere in wave 1.

This is surfaced, not resolved. Per
`.claude/rules/adversarial-prompt-refusal.md` the choice between "widen `027`'s
schema", "change `033`'s claim to match", and "drop `RequestChanges` from
wave 1" changes what a spec *requires*, and that is not a session's to make.
It will bite whoever implements `033`.

**P-4 (`040`, scope note when built).** Record that a pilot stops at import
and does not build `041`. Additive, a dated `D-n`, no contract change.

---

## 9. Open decisions

Listed because they are genuinely undecided, not because they are hard.

1. **Ordinal 043, and whether the import spec is written at all.** Follows
   the integrate/postpone decision in section 10.
2. **Licence of the golden vectors.** Whether
   `crates/hqgit-types/testdata/vectors/` is dual-licensed permissively so a
   neutral verifier can ship conformance fixtures. Copyright holder only.
3. **`digest_alg` vocabulary.** `sha-256` alone, or a registry with an
   explicit refusal path for unknown values. Recommend: start with exactly
   one value and refuse everything else, because a registry with one entry is
   a registry that has never been tested against a second.
4. **Whether the preserved bytes are per record or per bundle.** Per record
   is finer and lets a single receipt be referenced directly; per bundle is
   one object and preserves the chain context. Recommend per record, with the
   bundle's `anchorHash`, `recordCount` and `headRecordHash` carried in the
   claim so truncation stays detectable.
5. **P-3 above.** Which of `027` and `033` moves.

---

## 10. Recommendation

**Postpone the integration; do not reject it; do the design work now.**

The value beyond the existing export is real and, in the case of erasure
versus redaction, measurable (§4.3). The cost is the whole of wave 1:
nineteen specs, and no honest trimming makes it smaller, because signature,
revision identity and the rebuildable fold all sit below `034`. Statecraft's
first paying workflow should not wait on that.

The recommendation is therefore three-part:

1. **Do not make hqgit a launch dependency.** Nothing in the family's first
   commercial workflow needs it. Section 4.4 is explicit about what a
   signature does not buy.
2. **Change nothing in the thesis or the build order.** Section 2.3: the
   experiment is a prefix of the order hqgit already walks. The cheapest
   possible integration posture is to keep building `010` onward exactly as
   specified and let the integration become a small delta at `034`.
3. **Adopt the contract of section 3 as a design record now**, so that when
   wave 1 lands the import is one spec and a fixture corpus rather than an
   argument about whether BLAKE3 and SHA-256 identifiers are interchangeable.
   They are not, and writing that down costs nothing today.

The one thing that would change this recommendation is a customer who needs
portable, independently attributable review history *before* they need
anything else. That customer does not appear in the family assessment.
