# Task 20 — read-only session-events REST route

Status: DONE — code commit **b276a1d** (2026-10-18); this report is committed
separately (pathspec-only).

## Why

The P8 thin client already assumes this route exists:
`lib/core/cloud/cloud_ws.dart` `_restMirrorReader` calls
`GET /sessions/:id/events?after=<seq>` and reads `{events: [SessionEvent…]}`,
and the trajectory screen will be re-pointed onto it in Task 20. The durable
data (`session_event_mirror`) and the forward reader (`eventMirror.readSince`)
already existed; only the REST surface and a backward reader were missing.

No existing route's behaviour was changed.

## Files

- `cloud/packages/db/src/repos.ts`
  - `toSessionEvent` is now exported (the route reuses it rather than
    re-projecting the row).
  - new `eventMirror.readBefore(db, sessionId, beforeSeq, limit)`.
- `cloud/apps/gateway/src/routes/events.ts` (new)
  - `registerEventRoutes(app, deps)`.
  - exported `parseEventLimit` / `DEFAULT_EVENT_LIMIT` / `MAX_EVENT_LIMIT`.
- `cloud/apps/gateway/src/app.ts`
  - import + `registerEventRoutes(scope, deps)` inside the authenticated
    `/cloud/v1` scope, immediately after `registerMessageRoutes` (same
    composition-root pattern as every other route).
- `cloud/apps/gateway/src/routes/events.test.ts` (new)
- `cloud/packages/db/src/repos.test.ts` (extended the existing `eventMirror`
  test with `readBefore` cases).

## Route contract — `GET /cloud/v1/sessions/:id/events`

Mounted in the authenticated scope (same `authHook` as every other route).

### Ownership

1. `isUuid(sessionId)` false → `404 not_found` (`Session not found.`) — the
   same envelope as a malformed `:id` on `messages.ts`; the id never reaches
   the db.
2. `sessions.get(db, sessionId, principal.uid)` null → the identical
   `404 not_found` envelope. Wrong owner, unknown id and malformed id are
   indistinguishable (never 403, no existence leak).

### Query parameters

| param   | semantics |
|---------|-----------|
| `after` | exclusive forward cursor. Returns events with seq strictly greater, ascending. |
| `before`| exclusive backward cursor. Returns events with seq strictly less, ascending (nearest page first — see below). |
| `tail`  | `1` or `true` opts into the NEWEST page (ascending). Any other value/absence → false. |
| `limit` | default **200**, max **1000**, clamped like `parsePageLimit`: missing/empty/non-numeric/NaN/<1 → 200; >1000 → 1000; fractional → floor. Repeated params use the first value. |

- **Malformed `after`/`before` are IGNORED, never a 400** — the same lenient
  degradation as the messages `before` cursor. A seq must match
  `^\d+(?:-\d+)?$` (a Redis stream id: non-negative `<ms>` optionally
  `-<sub>`); anything else is treated as absent. A present-but-empty
  `after=`/`before=` is likewise absent.
- **Precedence:** valid `after` → valid `before` → `tail` → no cursor.
  `after` wins over both `before` and `tail`: it is the live-mirror resume
  cursor and the only cursor the thin client's `_restMirrorReader` sends; a
  request mixing them is ambiguous, so the forward direction is deterministic.
  A malformed `after` is ignored, in which case a valid `before`/`tail` still
  applies.
- **No cursor means FROM THE BEGINNING** (`readSince(null, limit)`), not the
  newest page. This is the `CloudMirrorReader` contract (see "Contract
  correction" below); callers that want the tail ask for it with `tail=1`.

### Response

`200 { events: SessionEvent[] }` using the exact shared shape from
`cloud/packages/shared/src/events.ts`:

```ts
{ sessionId: string; seq: string; type: SessionEventType; payload: object; ts: string /* ISO */ }
```

Events are always ascending by numeric `(ms, sub)`. An empty session answers
`{ events: [] }`.

## `eventMirror.readBefore` semantics

```ts
readBefore(db, sessionId, beforeSeq: string | null, limit): Promise<SessionEvent[]>
```

- seq comparison mirrors `readSince`'s `splitSeq` expression exactly, with the
  comparison inverted: `seqMs < key.ms OR (seqMs = key.ms AND seqSub < key.sub)`
  — strictly before, so the boundary row is excluded. Numeric comparison (not
  lexicographic), so `999999999999-0 < 1700000000000-0` and `-5 < -10` behave
  numerically.
- `beforeSeq === null` (or unparseable) → no bound → the newest `limit`
  events.
- **Ordering:** in both modes the page is selected `ORDER BY seq DESC LIMIT n`
  and then reversed, i.e. the page NEAREST the bound, returned ascending.
  This is required for contiguous backward paging: the client prepends the
  page and passes its first seq as the next `before`. A plain `ASC LIMIT`
  would return the oldest rows and skip the middle of the history.
- Session-scoped: another session's events never appear; an unknown session
  returns `[]` (the route has already answered 404 for non-owned sessions).

## Tests

`cloud/apps/gateway/src/routes/events.test.ts` (10 tests, real Postgres,
`describe.skipIf(!TEST_DATABASE_URL)`, same setup/stubs as `messages.test.ts`):

- owner gets their events, ascending, exact `{sessionId, seq, type, payload,
  ts}` wire shape (keys asserted);
- another user's session → 404; unknown uuid → 404; malformed id → 404 (exact
  envelope);
- `after` exclusive + forward paging + limit; last seq → empty;
- `before` exclusive + backward paging (nearest page, ascending); before the
  first event → empty;
- no cursor / `?before=` / `?after=` → FROM THE BEGINNING; `?limit=2` → first 2;
- truncation regression (250 events, `limit=200`): no cursor and `?before=`
  return the FIRST 200 starting at the oldest seq; `?tail=1` returns the LAST
  200 starting at event 51; `?tail=true&limit=2` → last 2; `?after=<oldest>`
  pages forward; `?tail=1&after=<seq>` → `after` wins;
- both `after` and `before` present → `after` wins;
- malformed `after`/`before` (`garbage`, `not-a-seq`, `-1`, `1-2-3`) →
  200 from the beginning, never 400;
- limit clamps: no limit / `0` / `-5` / `abc` → first 200 of 1001;
  `?tail=1&limit=0` → newest 200; `5000` → 1000 rows;
- empty session → `{events: []}`.

`cloud/packages/db/src/repos.test.ts` extends the existing `eventMirror` test
with `readBefore`: boundary exclusivity on ms and sub, numeric sub ordering
(`-5` vs `-10`), before-first → empty, `null` → newest page ascending,
bounded page nearest the boundary, and session isolation. `readSince` from the
beginning (null bound, oldest-first, including the limit) was already pinned
by the existing `all` / `limited` assertions.

## Contract correction (coordinator follow-up)

The first cut of this route treated "no cursor" as "newest page", reusing
`readBefore(null)`. That **broke the client's documented contract**:
`CloudMirrorReader` (`lib/core/cloud/cloud_ws.dart`) is defined as
"events with seq strictly AFTER `lastSeq` (null ⇒ from the beginning)", and
`_restMirrorReader` encodes a null cursor as `'after': lastSeq ?? ''` →
`?after=`. On a first-ever subscribe whose WS replay degraded, the old route
answered only the newest 200 events, so a transcript longer than `limit` was
silently truncated — the client folded an incomplete history with no error.
The original tests could not see it because they seeded only 5 events.

Fix: the route now distinguishes the two "no cursor" meanings explicitly with
the four-way precedence above — bare no-cursor → `readSince(null)` (from the
beginning), and the newest page only on an explicit `tail=1`/`tail=true`.
The `readBefore` repo semantics are unchanged; it is simply no longer the
default.

**Client impact: none.** `_restMirrorReader` sends `'after': lastSeq ?? ''`;
with the corrected precedence an empty `after=` is treated as absent and falls
through to rule 4 (from the beginning), which is exactly the typedef's
contract. The trajectory screen, when re-pointed in Task 20, should request
the tail explicitly with `tail=1` rather than relying on a no-cursor default.

## Gates

All run in `/root/OvidAI/cloud` against an isolated database
(`ovid_events_t20` on the disposable `ovid-dev-pg` container, port 5433 —
created for this task; the shared dev database and the live containers were
not touched).

```
$ pnpm --filter @ovid/db build
$ tsc -p tsconfig.json
DB_BUILD_EXIT=0

$ pnpm --filter @ovid/gateway build
$ tsc -p tsconfig.json
GW_BUILD_EXIT=0

$ pnpm --filter @ovid/db test
 ✓ src/moneyRepos.test.ts (9 tests) 1010ms
 ✓ src/repos.test.ts (14 tests) 817ms
 ✓ src/reposStorage.test.ts (10 tests) 767ms
 ✓ src/scheduleRepos.test.ts (12 tests) 795ms
 ✓ src/mcpRepos.test.ts (8 tests) 663ms
 ✓ src/scheduleService.test.ts (15 tests) 744ms
 ✓ src/repos.search.test.ts (10 tests) 897ms
 ✓ src/schemaTables.test.ts (4 tests) 596ms
 ✓ src/repos.grants.test.ts (4 tests) 582ms
 ✓ src/deviceRepos.test.ts (3 tests) 591ms
 ✓ src/migrate-cli.test.ts (5 tests) 2349ms
 Test Files  11 passed (11)
      Tests  94 passed (94)

$ pnpm --filter @ovid/gateway test
 ✓ src/routes/events.test.ts (10 tests) 1682ms
   ✓ truncation regression: 250 events, no cursor → the FIRST 200 (never only the tail) 321ms
   ✓ limit clamps: 0/negative/garbage → default 200; >1000 → 1000 1007ms
 ✓ src/routes/messages.test.ts (21 tests) 894ms
 ... (24 further files pass / 6 skipped by their own env guards)
 Test Files  26 passed | 6 skipped (32)
      Tests  290 passed | 68 skipped (358)

$ pnpm --filter @ovid/db exec tsc -p tsconfig.check.json --noEmit
DB_TSC_EXIT=0   (no output)

$ pnpm --filter @ovid/gateway exec tsc -p tsconfig.check.json --noEmit
GW_TSC_EXIT=0   (no output)
```

## Deviations

- **None functional.** Two implementation notes:
  1. `readBefore` uses `DESC LIMIT` + reverse for the bounded case too (not
     only for `beforeSeq === null`), because that is what "pages backward"
     requires; the null case is simply the same query with no bound.
  2. The route defines "malformed seq" with a strict
     `^\d+(?:-\d+)?$` guard rather than delegating to the repo's
     `Number()`-based `splitSeq`, so shapes like `-1` or `1-2-3` degrade to
     "no cursor" at the boundary instead of reaching SQL.
- No new dependencies. No Flutter client files touched. Unrelated working-tree
  modifications (`lib/`, `pubspec.lock`, other-lane reports,
  `docs/screen-review/`, `node_modules/`) were left untouched; commits are
  pathspec-only.
