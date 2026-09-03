---
id: "095-web-review-ui"
title: "The web review client: change list, change detail with semantic deltas first, threads, the evidence panel"
status: approved
kind: "feature"
domain: "l7-edge"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 6
depends_on:
  - "093-connect-api"
  - "081-change-and-review-views"
establishes:
  - "web/package.json"
  - "web/tsconfig.json"
  - "web/vite.config.ts"
  - "web/index.html"
  - "web/src/main.tsx"
  - "web/src/api.ts"
  - "web/src/format.ts"
  - "web/src/views/ChangeList.tsx"
  - "web/src/views/ChangeDetail.tsx"
  - "web/src/views/DeltaPanel.tsx"
  - "web/src/views/LineDiff.tsx"
  - "web/src/views/EvidencePanel.tsx"
  - "web/src/views/ThreadPanel.tsx"
  - "web/test/"
  - "crates/hqgit-server/src/static_files.rs"
extends:
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/lib.rs", nature: additive }
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/src/app.rs", nature: additive }
  # include_dir (embedded dist behind a feature) joins the manifest and the table.
  - { spec: "090-server-skeleton", unit: "crates/hqgit-server/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The minimal review client (thesis §9: a UI beyond review is a later
  client). A TypeScript, React, and Vite single-page application under
  web/ that speaks only the Connect JSON form of the spec 093 API and
  renders four things: a paginated change list; a change detail whose
  order is the argument of design §1.1 point 3 (policy verdict, then the
  semantic delta views for API surface, dependencies, and capabilities,
  then threads, then the line diff last and collapsed); threads with
  their per-revision exact, moved, text, lost, and unavailable markers;
  and an evidence panel listing every attestation over the revision with
  its verification status. Every view prints which ledger entry it is
  projected as of. The server serves web/dist from static_files.rs, the
  package carries its spec-spine binding, and no tsconfig exists at the
  repository root (spec 001 D-1).
---

# 095: The web review client

## 1. Purpose

Design §1.1 point 3: the line diff is the lowest-value view of a change,
and point 7: a human should review the argument rather than the diff.
Every incumbent UI puts the diff first because its data model has nothing
else. This client exists to prove the ledger has something else, and to
be honest about it: when no semantic delta has been attested for a
revision the panel says so, when an attestation failed verification the
badge says why, and when a thread's anchor was lost the marker says lost.
It is deliberately small: a review surface, served by the same binary,
reading the same API the CLI uses (constitution XIII).

## 2. Territory

The whole of `web/` as founded here: `package.json` (with `"spec-spine":
{ "spec": "095-web-review-ui" }`), `tsconfig.json` (the only one in the
repository), `vite.config.ts` (build and vitest config), `index.html`,
`src/main.tsx` (router and shell), `src/api.ts` (the typed Connect JSON
client), `src/format.ts` (hash, cid, principal, and Hlc rendering), the
six views, and the `test/` subtree with recorded fixtures. On the Rust
side, `static_files.rs` in `hqgit-server` and, additively, `app.rs`,
`lib.rs`, and the manifest (090). Login is 061; in-browser signing is a
later spec.

## 3. Behavior

- **B-1 (toolchain).** TypeScript in `strict` mode, React 18, Vite 6,
  vitest with jsdom and Testing Library, `engines.node = ">=22"`, every
  dependency pinned exact, `package-lock.json` committed, `npm ci` the
  only install. Scripts: `build` (`tsc --noEmit && vite build` into
  `web/dist`), `test` (`vitest run`), `dev`. No tsconfig, package.json,
  or lockfile is placed at the repository root (001 D-1; spec-spine.toml
  lists `web` as a standalone npm package).
- **B-2 (the client).** `api.ts` exposes one function per RPC this UI
  uses (`listChanges`, `getChange`, `getRevisionDiff`, `listThreads`,
  `postComment`, `resolveThread`, `reopenThread`, `listAttestations`,
  `listVerdicts`, `replay`, `getRepo`, `listRepos`) as `fetch` calls to
  `POST /hqgit.v1.<Service>/<Method>` with `application/json` (093 B-3),
  an optional bearer from session storage sent as `Authorization`, and
  the TypeScript types of the messages it uses declared beside them. A
  Connect error body becomes `ApiError { code, message, details }`. Every
  response type carries `asOf`; the client never strips it. A drift-guard
  test parses each recorded fixture with the declared types.
- **B-3 (change list).** Route `/` (and `/repos/<ns>`): rows from
  `listChanges` in the order the API returns them (never re-sorted), with
  id prefix, title, state, latest revision number, stack position when
  present, open thread count, and the latest verdict badge; a state
  filter; cursor pagination with `next`; a footer `projected as of
  <entry-prefix> (ordinal N)` (080 B-5) on every page.
- **B-4 (change detail).** Route `/changes/<id>` with a revision selector
  (latest by default). Sections in this DOM order and no other: (1) the
  verdict header from `listVerdicts` (Allow, or Deny with every reason
  listed, or `no policy evaluation recorded`); (2) `DeltaPanel`: API
  surface, dependency, and capability deltas read from
  `hqgit/semantic-delta/v1` attestations (051) over the selected revision,
  each rendered as added, removed, and changed lists, an `unsupported`
  delta rendered as such, and a missing delta rendered as `no semantic
  delta attested for this revision`; (3) `ThreadPanel`; (4)
  `EvidencePanel`; (5) `LineDiff`, collapsed by default, fetching
  `getRevisionDiff` only when expanded, against the previous revision by
  default and the base on request, with an erased blob rendered as
  `erased`. A test asserts the order by DOM position.
- **B-5 (threads).** `ThreadPanel` lists threads for the selected revision
  with the 081 B-2 position marker (`exact`, `moved` with confidence,
  `text`, `lost` with the original path and line, `unavailable`), comments
  in the order returned with author kind badges (human, agent, service,
  org), `erased` bodies rendered as such, and a comment form plus resolve
  and reopen actions that call the server-mediated writes of 093 B-4;
  after a write the panel refetches and shows the new `asOf`. The panel
  renders the routing outcome the API reports (main or quarantine) so an
  unverified viewer sees that their comment is quarantined.
- **B-6 (evidence).** `EvidencePanel` lists every attestation whose
  subject is the selected revision, grouped by predicate, each with
  issuer principal and kind, `at`, and a verification badge from 081
  B-3's column (`ok`, `failed` with reason, `unverified`), the claim
  summarized per known predicate (approval verdict, test counts, finding
  counts, mirror source) and shown as raw JSON otherwise; the policy-eval
  rows offer `replay`, showing 067's `Match | Mismatch | Unavailable`.
  There is no approve button: an approval is signed by the approver's key
  (027, constitution XI) and the panel prints the `hq review approve
  --remote` invocation instead.
- **B-7 (rendering rules).** `format.ts` renders hashes and cids as a
  12-character prefix with the full value on hover and copy, principals
  as `<kind>:<prefix>`, and `Hlc` as UTC ISO-8601 from `wall_ms` with the
  logical counter on hover; nothing reads `Date.now()` to describe ledger
  data. Comment bodies and diff text are rendered as text nodes, never as
  HTML.
- **B-8 (serving).** `static_files.rs` mounts `GET /`, `GET /ui`, and
  `GET /ui/*` to `index.html` (SPA fallback) and `GET /assets/*` to the
  hashed bundles with `Cache-Control: public, max-age=31536000,
  immutable`; `index.html` is `no-cache`. Files come from the embedded
  `web/dist` when the crate is built with feature `web` (`include_dir`)
  and from `[web] dist_dir` otherwise; with neither, `/ui` answers `404
  { "hint": "build web/ or set web.dist_dir" }`. The mount never shadows
  `/hqgit.v1.*`, `/*.git/*`, `/healthz`, or `/readyz`. Responses carry
  `Content-Security-Policy: default-src 'self'; connect-src 'self';
  img-src 'self' data:` and `X-Content-Type-Options: nosniff`.

## 4. Functional requirements

- **FR-001.** `web/test/fixtures/` holds recorded Connect JSON responses
  from the 093 fixtures (a change with two revisions, threads in every
  position state, attestations in every verification state, an Allow and
  a Deny verdict, a semantic delta and a revision without one).
- **FR-002.** `web/test/` covers with vitest: `api.ts` request shape and
  error mapping; the drift guard of B-2; `ChangeList` rows, filter,
  pagination, and the as-of footer; `ChangeDetail` section order; the
  `DeltaPanel` absent and unsupported renderings; every `ThreadPanel`
  marker and the erased body; every `EvidencePanel` badge, Deny reasons,
  and the replay result; `format.ts` against fixed inputs; a comment body
  containing markup rendered as text.
- **FR-003.** `cargo test -p hqgit-server --locked static_files` covers
  the SPA fallback, asset caching headers, the no-dist hint, the CSP
  header, and that `/hqgit.v1.Repos/ListRepos` still reaches the API with
  the UI mounted.
- **FR-004.** `npm run build` produces `web/dist` with hashed asset names
  and no source maps in production; `web/dist` is gitignored.

## 5. Acceptance criteria

- **AC-1.** `cd web && npm ci && npm run build && npm test` exits 0.
- **AC-2.** `cargo test -p hqgit-server --locked static_files` passes.
- **AC-3.** Against a server built with `--features web` holding the 033
  fixture ledger, `/ui/changes/<id>` renders the change with the delta
  section above the line diff and the evidence panel listing the approval.

## 6. Out of scope

Login and sessions (061), in-browser signing of approvals and attestations
(a later spec over 063), issue views, search (082), feeds (085), stack
visualization beyond the position column (a later client), and any UI
for repository administration or key management.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cd web && npm ci && npm run build && npm test
cargo test -p hqgit-server --locked static_files
```
