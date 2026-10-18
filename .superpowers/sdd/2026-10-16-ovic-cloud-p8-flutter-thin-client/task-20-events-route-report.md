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
| `limit` | default **200**, max **1000**, clamped like `parsePageLimit`: missing/empty/non-numeric/NaN/<1 → 200; >1000 → 1000; fractional → floor. Repeated params use the first value. |

- **Malformed `after`/`before` are IGNORED, never a 400** — the same lenient
  degradation as the messages `before` cursor. A seq must match
  `^\d+(?:-\d+)?$` (a Redis stream id: non-negative `<ms>` optionally
  `-<sub>`); anything else is treated as absent.
- **When both are present, `after` wins and `before` is ignored.** Rationale:
  `after` is the live-mirror resume cursor and the only cursor the thin
  client's `_restMirrorReader` sends; a request carrying both is ambiguous,
  so the forward direction is deterministic. A malformed `after` is ignored,
  in which case a valid `before` still applies.
- With neither usable cursor the route returns the **newest page, ascending**
  (`readBefore(null, limit)`), so the trajectory screen opens on the tail in
  one call.

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

`cloud/apps/gateway/src/routes/events.test.ts` (9 tests, real Postgres,
`describe.skipIf(!TEST_DATABASE_URL)`, same setup/stubs as `messages.test.ts`):

- owner gets their events, ascending, exact `{sessionId, seq, type, payload,
  ts}` wire shape (keys asserted);
- another user's session → 404; unknown uuid → 404; malformed id → 404 (exact
  envelope);
- `after` exclusive + forward paging + limit; last seq → empty;
- `before` exclusive + backward paging (nearest page, ascending); before the
  first event → empty;
- `before` with no value → newest page ascending; `?limit=2` → tail;
- both present → `after` wins;
- malformed `after`/`before` (`garbage`, `not-a-seq`, `-1`, `1-2-3`) →
  200 default page, never 400;
- limit clamps: no limit / `0` / `-5` / `abc` → 200 rows (newest 200 of 1001);
  `5000` → 1000 rows;
- empty session → `{events: []}`.

`cloud/packages/db/src/repos.test.ts` extends the existing `eventMirror` test
with `readBefore`: boundary exclusivity on ms and sub, numeric sub ordering
(`-5` vs `-10`), before-first → empty, `null` → newest page ascending,
bounded page nearest the boundary, and session isolation.

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
 ✓ src/moneyRepos.test.ts (9 tests) 756ms
 ✓ src/repos.test.ts (14 tests) 676ms
 ✓ src/reposStorage.test.ts (10 tests) 589ms
 ✓ src/scheduleRepos.test.ts (12 tests) 646ms
 ✓ src/mcpRepos.test.ts (8 tests) 564ms
 ✓ src/scheduleService.test.ts (15 tests) 594ms
 ✓ src/repos.search.test.ts (10 tests) 781ms
 ✓ src/schemaTables.test.ts (4 tests) 482ms
 ✓ src/repos.grants.test.ts (4 tests) 498ms
 ✓ src/deviceRepos.test.ts (3 tests) 477ms
 ✓ src/migrate-cli.test.ts (5 tests) 2095ms
 Test Files  11 passed (11)
      Tests  94 passed (94)

$ pnpm --filter @ovid/gateway test
 ✓ src/routes/events.test.ts (9 tests) 1039ms
 ✓ src/routes/messages.test.ts (21 tests) 722ms
 ... (24 further files pass / 6 skipped by their own env guards)
 Test Files  26 passed | 6 skipped (32)
      Tests  289 passed | 68 skipped (357)

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
