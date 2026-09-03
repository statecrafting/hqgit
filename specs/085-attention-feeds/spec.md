---
id: "085-attention-feeds"
title: "Attention feeds: a per-principal ranked feed where every item carries its reason"
status: approved
kind: "feature"
domain: "l5-projection"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: low
wave: 6
depends_on:
  - "081-change-and-review-views"
establishes:
  - "crates/hqgit-projection/src/feeds.rs"
  - "crates/hqgit-projection/tests/feeds.rs"
  - "crates/hqgit-projection/testdata/feeds/"
extends:
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/lib.rs", nature: additive }
  - { spec: "080-projection-framework", unit: "crates/hqgit-projection/src/registry.rs", nature: additive }
  # Requests and mutes are facts: three `attention.*` kinds join the vocabulary.
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  Design §1.1 point 8 names attention management as an email firehose
  with no prioritization. This spec replaces the firehose with a
  projection: for each principal, a feed of items derived from facts,
  ranked by integer weights for blocking someone's merge, an ownership
  match with its SLA when spec 104 supplies one, staleness measured in
  ledger time rather than wall-clock time, stack depth, and explicit
  requests, with the reasons listed on every item so there is never a
  notification without a reason. Requesting attention and muting are
  facts, so a rebuild reproduces the feed and a mute survives every
  replica. The feed is disposable, as-of a ledger entry, and never a
  source of anything.
---

# 085: Attention feeds

## 1. Purpose

Thesis §4.7 lists feeds among the projections; constitution VI makes them
rebuildable and non-authoritative. A feed is also where a product grows
hidden state fastest (read markers, snoozes, per-user rules in a settings
table), which constitution XI forbids. This spec keeps every input a fact
and every output a pure fold: the rank is arithmetic over integers the
ledger already holds, the reasons are the terms of that arithmetic, and
"now" is the newest entry the fold has seen, not a clock.

## 2. Territory

`feeds.rs` in `hqgit-projection` (the `FeedsProjection`, the rank
function, the query API) and `tests/feeds.rs`, with ranking vectors under
`testdata/feeds/`. Additively: the `lib.rs` re-export, the `register_all`
entry, and three fact kinds in 023's vocabulary. Ownership facts are
consumed through a seam (B-5) because their body is fixed by the
higher-numbered spec 104.

## 3. Behavior

- **B-1 (facts).** Three kinds join `DomainFact` with frozen strings:
  `attention.requested { change: ChangeId, from: Principal, to: Principal,
  note: Option<String>, extra }`; `attention.muted { principal:
  Principal, target: MuteTarget, until: Option<Hlc>, extra }`;
  `attention.unmuted { principal: Principal, target: MuteTarget, extra }`.
  `MuteTarget` is a closed enum `Change(ChangeId) | Stack(Hash) |
  Author(Principal) | Path(String)` (a path pattern as 104 will spell
  it). A mute or unmute MUST be issued by `principal` (023 B-6: the trust
  plane verifies issuer against principal; the fold records a mismatch as
  a defect and applies nothing). Concurrent mute and unmute converge by
  the greater `Hlc` (constitution VII, an LWW register per target).
- **B-2 (the projection).** `FeedsProjection` (`NAME = "feeds"`,
  `SCHEMA_VERSION = 1`) folds `change.opened`, `change.revision_submitted`,
  `change.merged`, `change.abandoned`, `change.depends_on`,
  `review.thread_opened`, `review.comment_posted`,
  `review.thread_resolved`, `review.approval_issued`, the three B-1
  kinds, and `ownership.declared` / `ownership.revoked` through the B-5
  seam. It keeps its own small tables so it is rebuildable alone and
  reads no other projection's file; the 081 dependency supplies the
  shared `AsOf`, `Page`, and `PageCursor` types and the change rows the
  composing binary joins for display. Tables: `feed_items(principal TEXT,
  item_id TEXT, kind TEXT NOT NULL CHECK (kind IN
  ('requested','reply','comment-on-change','owned-path','blocking')),
  change_id TEXT NOT NULL, thread_id TEXT, static_score INTEGER NOT NULL,
  reasons TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT
  NULL, resolved INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (principal,
  item_id))`, `feed_mutes(principal TEXT, target TEXT, until TEXT,
  PRIMARY KEY (principal, target))`, `feed_changes(change_id TEXT
  PRIMARY KEY, opened_by TEXT, state TEXT, stack_depth INTEGER NOT NULL
  DEFAULT 0, open_dependents INTEGER NOT NULL DEFAULT 0, touched_paths
  TEXT, updated_at TEXT)`, and `feed_meta(key TEXT PRIMARY KEY, value
  TEXT)` holding `latest_hlc`, the greatest `Hlc` applied so far.
  `item_id = Hash::of(kind || 0x00 || change_id || 0x00 || thread_id?)`.
- **B-3 (items and reasons).** An item exists for a principal only when
  at least one reason does; `Reason` is a closed enum `Requested { by }
  | ReplyToYou { thread } | CommentOnYourChange { thread } | OwnsPath {
  path, sla_hours: Option<u32> } | BlocksMerge { count } | StackDepth {
  depth } | Stale { hours }`, stored as sorted-key JSON in `reasons`; a
  write with an empty list is refused by a `CHECK (reasons <> '[]')`.
  `requested` arises from `attention.requested` naming the principal as
  `to`; `reply` from a `review.comment_posted` whose `reply_to` the
  principal authored or on a thread the principal opened; `comment-on-change`
  from a comment on a change the principal opened; `owned-path` from a
  revision whose tree touches a path the principal owns (B-5);
  `blocking` from `change.depends_on` when an open change by another
  principal depends on one the principal opened. An item is `resolved`
  when its change merges or is abandoned, its thread resolves, or the
  principal approves the revision; resolved items are excluded from the
  feed and kept for rebuild equality.
- **B-4 (rank, integers only).** `static_score` is written at apply time:
  `400` for `Requested`, `150` for `ReplyToYou`, `100` for
  `CommentOnYourChange`, `200` for `OwnsPath`, `300 * min(count, 3)` for
  `BlocksMerge`, `25 * min(depth, 4)` for `StackDepth`, summed over the
  item's reasons. The time terms are computed at query time from
  `feed_meta.latest_hlc` so the stored rows stay a pure function of the
  facts: `age_hours = (latest.wall_ms - updated_at.wall_ms) /
  3_600_000`, `stale = min(age_hours, 168)`, and, when an `OwnsPath`
  reason carries `sla_hours = H`, `urgency = min(age_hours * 200 / H,
  400)`. `score = static_score + stale + urgency`, all `u64` integer
  arithmetic. Order is `score DESC, updated_at ASC, item_id ASC`.
- **B-5 (ownership seam).** `trait OwnershipSource { fn owners_of(&self,
  path: &str, at: &Hlc) -> Vec<Owner { principal, sla_hours:
  Option<u32> }>; }`. `FeedsProjection::new(ownership: Box<dyn
  OwnershipSource>)`; this spec ships `NoOwnership` (always empty), so
  `owned-path` items and `urgency` are absent until 104 registers its
  `OwnershipView` as the source. The seam takes facts the projection
  hands it, never a file or a clock.
- **B-6 (mutes).** A mute row suppresses items whose change, stack,
  author, or touched path matches `target`, until `until` is less than
  `latest_hlc`; an unmute deletes the row. Mutes never delete items, so
  unmuting restores them without a rebuild.
- **B-7 (query).** `feed_for(store, principal, cursor: Option<PageCursor>,
  limit: u32) -> AsOf<Page<FeedItem { item_id, kind, change_id,
  thread_id, score: u64, reasons: Vec<Reason>, updated_at: Hlc }>>`
  applies B-4 and B-6 in SQL and returns the reasons on every item;
  `mutes_for(store, principal) -> AsOf<Vec<MuteRow>>`.
- **B-8 (discipline).** No clock, no `HashMap`, no float; every write is
  an upsert on `(principal, item_id)` (080 B-4); no comment body text is
  stored (constitution X); a rebuild equals the incremental fold.

## 4. Functional requirements

- **FR-001.** `testdata/feeds/ranking.json` holds vectors: a list of
  items with reasons, `updated_at`, and `latest_hlc`, and the expected
  `score` and order. A test evaluates the rank function against each.
- **FR-002.** Tests cover, from fixture ledgers: an explicit request
  creates a `requested` item with `Requested` in its reasons; a reply to
  the principal's comment creates `reply`; a dependent change raises
  `BlocksMerge` with the right count and the score changes when a second
  dependent opens; stack depth capped at 4; staleness capped at 168 and
  computed from `latest_hlc`, so appending an unrelated fact later raises
  the score without touching the row; a merge resolves the item; a mute
  hides and an unmute restores; a mute with `until` in the past does not
  hide; a mute issued for another principal is a defect and ignored; with
  a fixture `OwnershipSource` an `owned-path` item appears with
  `sla_hours` and `urgency` follows B-4; rebuild equals incremental.
- **FR-003.** A test asserts no item row exists whose `reasons` is empty
  after folding every fixture (the CHECK is exercised, not assumed).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-projection --locked feeds` passes with
  every vector in FR-001.
- **AC-2.** On the 033 offline-review fixture with one added
  `attention.requested`, `feed_for` returns that change first with
  `Requested` as a reason and `projected as of` the last entry.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The ownership fold and its SLA field (104 supplies the `OwnershipSource`);
delivery (email, push, and a `hq feed` verb belong to 093 and 095 as
clients of this query); read markers (an item resolves by facts, not by
being seen); cross-repository feeds (each repository's feed is local; a
server concatenates).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-projection --locked feeds
```
