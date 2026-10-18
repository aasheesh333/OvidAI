# Task 20 — Studio / Schedule local→server session-id mapping

## The bug

`ChatSession.id` is a LOCAL id (`DateTime.now().microsecondsSinceEpoch.toString()`,
`lib/core/state.dart`). `CloudSessionStore` persists a local→server UUID map in
`_idMap` (`serverIdFor`) and deliberately does not rewrite `ChatSession.id`.
Every server route (`/sessions/:id/...`, WS `pty_open.sessionId`) requires a
UUID and applies `isUuid` + an ownership lookup.

Two feature surfaces still put the LOCAL id on the wire:

1. **Studio** — `StudioScreen` passes `AppState.I.activeSession?.id` to
   `StudioEditorTabs` / `StudioEditor` / `StudioFileTree`, which reach
   `StudioFilesClient`. That client built
   `/sessions/$sessionId/workspace/tree` and `.../file`, and `CloudPtyChannel`
   sent `pty_open{sessionId}`. The gateway answered 404 (workspace.ts), so the
   tree/editor/PTY never loaded for any chat created in the app.
2. **Schedule** — `sidebar.dart` and `app_router.dart` pass
   `app.activeSessionId` into `ScheduleScreen`, which filtered
   `ScheduleClient.I.list(...)` with `s.sessionId == widget.sessionId`.
   `ScheduleDto.sessionId` is the server UUID, so the list was ALWAYS empty.

The browser had the same class of bug; it is fixed by a separate lane and was
not touched here.

## Boundary chosen

Resolution happens at the REST/WS boundary, not in UI state. UI keys stay
LOCAL (open tabs, drafts and `StudioDraftStore` record names are unchanged).

`CloudSessionStore` gained the single resolver pair:

- `String resolveServerSessionId(String id)` → `serverIdFor(id) ?? id`
  (unmapped / already-server ids pass through unchanged);
- `Future<String> resolveServerSessionIdAsync(String id)` → awaits `ready`
  (unless the in-memory map is already loaded) then delegates.

A `@visibleForTesting CloudSessionStore.forTest({idMap, ...})` constructor
seeds an in-memory map with `ready` already complete and no SharedPreferences /
network access. The existing `installForTest` / `resetForTest` seams are used
by the widget test.

`CloudRestClient` was deliberately NOT changed: translating there would
double-map ids that the facade already resolved and hide call-site mistakes.

## Call sites fixed

| File | Change |
| --- | --- |
| `lib/core/cloud/cloud_session_store.dart` | Added sync + async resolver, `_loaded` fast path, and `forTest`. |
| `lib/core/cloud/studio_files.dart` | `treeSnapshot`, `readFileDetailed` (and therefore `readFile`), and `writeFile` resolve once before building the path. `writeFile` reuses a resolved-id private read (`_readFile`) so the baseline check and the PUT share one id. State keys remain the caller's id; `StudioTreeSnapshot.sessionId` falls back to the resolved id. Optional `sessions` injection defaults lazily to `CloudSessionStore.I`. |
| `lib/core/cloud/studio_pty.dart` | `CloudPtyChannel` resolves before sending `pty_open`; the open queue stays keyed by the LOCAL id (tab correlation) and `_adoptOpened` / error routing accept either the local or resolved id. Optional `sessions` injection. Resolver failure falls back to the caller's id so the terminal still opens. |
| `lib/ui/schedule_screen.dart` | `_load` resolves once with `resolveServerSessionIdAsync` and compares `ScheduleDto.sessionId` against the SERVER id. The app-bar title still uses `AppState.I.sessionById(widget.sessionId)` (local row). Edit/pause/resume/cancel carry no session id, so no further patch needed. |

No other Studio/Schedule path embeds a session id (`studio_remote_client.dart`
and `schedule_client.dart` are id-agnostic at the boundary).

## Tests

`test/cloud_studio_client_test.dart` — new group
`local→server session id resolution` (mapped `local-1` → UUID
`018f3b0e-…`), each asserting the exact request path / frame:

- `treeSnapshot` sends the UUID;
- `readFile` sends the UUID;
- `writeFile` sends the UUID (PUT);
- an unmapped id passes through unchanged;
- `pty_open` sends the UUID;
- `pty_open` passes an unmapped id through unchanged.

`test/schedule_session_id_test.dart` — widget test: the store maps
`local-1` → UUID, the fake gateway returns one schedule stored under the UUID,
the screen is opened with `local-1`, and it renders the schedule (plus the
local title). Without the resolver the filter compares local vs UUID and the
screen shows the empty state.

Removing the resolver makes the path/frame assertions fail (they would contain
`local-1`) and the schedule screen test fail (no row).

`test/support/studio_fake_gateway.dart` now injects an empty `forTest` store so
the existing Studio suites exercise the resolver without platform-channel
mocks.

## Gates

```
$ flutter analyze --no-pub
No issues found! (ran in 20.7s)

$ flutter test --no-pub test/cloud_studio_client_test.dart \
    test/schedule_session_id_test.dart test/schedule_ui_test.dart \
    test/schedule_pickers_test.dart test/schedule_premium_test.dart \
    test/ui_finish_05_schedule_test.dart \
    test/ui_redesign/schedule_screen_test.dart test/cloud_session_store_test.dart
... +66: All tests passed!

$ flutter test --no-pub
11:15 +1750 ~2 -3: Some tests failed.
```

The three full-suite failures are in the browser lane, which another agent was
editing concurrently (those files are modified in the shared working tree):

- `test/cloud_browser_stream_test.dart: BrowserScreen (cloud) paints the
  decoded image with RawImage` (timed out; that test name is not in the file's
  current on-disk revision)
- `test/ui_redesign/browser_screen_test.dart: state updates the tab strip and
  address row`
- `test/ui_redesign/browser_screen_test.dart: a server takeover ack swaps the
  chip to Release control`

No file from that lane (`browser_screen.dart`, `browser_stream.dart`,
`cloud_ws.dart`, `chat_screen.dart`, browser tests) was touched. A later
full-suite attempt also hit transient compile errors while the Task 20 lane
removed `Distribution.thinOverrideForTest`; the targeted suites above were
re-run against the updated tree and pass.

Commit is pathspec-only over the six touched source/test files plus this
report.
