# hqgit constitution

Durable principles that govern this corpus. This document is **tier 2**: it is
subordinate to the bootstrap spec (`specs/000-hqgit-bootstrap/spec.md`), whose
`unamendable` anchors it may not contradict, and it governs all ordinary specs
(`001`+).

**Normative hierarchy (highest wins):**

1. `specs/000-hqgit-bootstrap/spec.md`: the bootstrap spec. Non-overridable.
2. `standards/spec/constitution.md`: this document.
3. `standards/spec/contract.md`: a normative summary of the bootstrap spec.
4. `specs/002-platform-thesis/spec.md`: the architectural thesis. It owns no
   code; it fixes the layer model and the build order every other spec
   operates inside.
5. Ordinary specs (`010`+): feature-level claims within this envelope.

When two specs conflict, resolve in this order, then by the typed authority
graph.

The first five principles are spec-spine's own and apply to the corpus. The
principles from VI onward are hqgit's and apply to the system the corpus
describes. Both halves bind every spec and every build session equally.

---

## I. Markdown-only authored truth

Authored truth lives only in markdown with YAML frontmatter. There is no
authoritative hand-authored JSON, YAML, or TOML data file that governs the
system. If a fact governs the system, it is written in a `spec.md` (or a
`standards/` document), never in a derived artifact. *(Bootstrap anchor:
`markdown-truth-boundary`.)*

## II. Compiler-owned JSON machine truth

All machine-consumable truth about the corpus is emitted by `spec-spine` into
`.derived/` and is read only through `spec-spine` subcommands. Hand-editing a
derived artifact is a workflow violation; ad-hoc parsing of one is equally
forbidden. *(Bootstrap anchor: `json-truth-boundary`.)*

## III. Spec-first development

A change to behavior begins with a change to a spec. The spec defines the
territory (the units it owns) and the relationships (the typed edges) before
the code is written. The coupling gate enforces this at PR time. The escape
valve is a named, scoped waiver in the PR body, never a silent edit to an
owner spec. In this repository the ownership ratchet is on: every source file
inside a crate must be specifically claimed by a spec, so a build session
that adds a file adds it to the `establishes` list of the spec it is
implementing, in the same change.

## IV. Determinism and validation

Every artifact-producing function in the corpus toolchain is a pure function
of `(config, file contents)`. Validation is mechanical. *(Bootstrap anchor:
`determinism-requirement`.)* The same principle is the design rule of the
system itself (see VIII).

## V. Legacy as evidence

Code that predates a governing spec is evidence, not a violation. hqgit is
greenfield, so only the bootstrap spec carries `origin.retroactive: true`;
every ordinary spec is a forward claim. Should the corpus ever adopt code it
did not author (a vendored executor, a mirrored protocol implementation), that
code is specced as found, defects recorded under a `## Known defects` heading,
never blessed.

---

## VI. Canonical objects; everything else is derived

The canonical state of a repository is a set of signed, content-addressed
objects forming a per-repository DAG that covers code, collaboration, and
evidence (layers L0 through L4 in spec 002). Every index, timeline, search
result, dashboard, queue, and feed is a projection that MUST be rebuildable
from zero. No projection may hold an authoritative row that is not in the
log. One violation of this principle recreates the system this project
exists to replace. *(Bootstrap anchor: `canonical-derived-boundary`.)*

## VII. Facts are immutable; only derived state converges

A fact is an immutable, signed event: a revision was submitted, an attestation
was issued, a comment was anchored. Facts never conflict; concurrent facts
merge by set union under one deterministic total order. Only derived state
(open or closed, labels, assignee, title) needs convergence, and last-writer-wins
over a hybrid logical clock is the default instrument. Sequence CRDTs are
reserved for genuinely collaborative text and nothing else. A spec that moves a
noun from the fact side to the CRDT side must say why in its body. *(Bootstrap
anchor: `facts-immutable`.)*

## VIII. Hash stability is the one unrecoverable boundary

The canonical encoding of every L0 and L1 object (spec 011) and the hash of
every ledger entry (spec 017) are frozen the moment the first signed entry
exists. Serialization is canonical and deterministic; unknown fields are
preserved, never dropped; fields are never reordered or retyped inside a
schema MAJOR; and no clock, environment read, or map iteration order reaches
a hashed byte. Golden vectors under `crates/hqgit-types/testdata/vectors/`
are the frozen record: a change that alters any vector's hash is a schema
MAJOR, a spec amendment, and a human decision, in that order. *(Bootstrap
anchor: `hash-stability`.)*

## IX. One evidence primitive

Every form of evidence (human approval, build provenance, test result, static
finding, license scan, policy evaluation, agent action, mirrored external
state) is an `Attestation { subject, predicate, issuer, claim, sig }` (spec
027). One storage path, one verification path, one policy input, one audit
trail. Requests to special-case a predicate are refused; new evidence kinds
register a predicate, never a new noun. *(Bootstrap anchor:
`single-evidence-primitive`.)*

## X. Erasure by tombstone, never by rewrite

The signed log holds commitments (content identifiers), never user content.
Content lives in the object store, encrypted per namespace where required.
Deletion removes the blob and appends a tombstone over the commitment; the
chain stays verifiable and the content is genuinely gone. Signed history is
never rewritten. *(Bootstrap anchor: `erasure-by-tombstone`.)*

## XI. Trust is checkable, not decorative

Identity is a keypair with a rotation chain recorded in the ledger. Approvals
are attestations over a specific revision hash. "Requires two approvals" is a
predicate over the evidence graph, evaluated by a hash-pinned, deterministic
policy module whose verdict is itself an attestation. Repository settings as
mutable toggles are an anti-pattern the design makes impossible. A cache that
gates a merge is a trust boundary: an unattested cache hit is a miss.

## XII. Agents are a distinct principal class

`Principal` is `Human | Agent | Service | Org` at the type level. An agent
never authenticates as a human holding a human token. Its credential carries
its delegation chain (which human, under which policy version, expiring
when), its sandbox is declared, and every artifact it produces carries
provenance. Verification throughput, not authoring convenience, is what the
system optimizes for. *(Bootstrap anchor: `agent-principal-class`.)*

## XIII. Layer boundaries are one-directional

L5 and above read from L0 through L4 and never write authoritatively.
Crates depend downward only: `hqgit-types` has no workspace dependency, and
`hqgit-server` and `hqgit-cli` depend on everything beneath them but on each
other never. The CLI and the server run the same ledger implementation; that
is what makes offline-first true rather than aspirational. *(Bootstrap anchor:
`layer-direction`.)*

## XIV. Absorption over replacement

Git compatibility is a hard requirement and the GitHub mirror is the wedge.
hqgit builds the verification and review plane over existing repositories
and lets hosting commoditize underneath. A spec that requires a user to
migrate before receiving value must justify that in its Purpose section.

## XV. Untrusted by default

Contributions from unverified principals, mirrored external state, and agent
output land in a quarantine namespace and are promoted by capability, never
accepted by default. Abuse in an append-only replicated store is designed
against from the first spec, not patched later.

---

## Amendment

This constitution may be amended by an ordinary spec that `amends` it and is
approved, **provided** the amendment does not contradict a `specs/000`
`unamendable` anchor. The bootstrap spec's freeze surface is the hard
boundary; everything else in this document is revisable through the normal
governed flow.
