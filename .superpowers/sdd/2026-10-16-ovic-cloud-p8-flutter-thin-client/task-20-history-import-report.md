# Task 20 — History import service + tests

Status: DONE (service and tests only; wiring/deletions deferred as instructed)

## Scope

Created exactly two source files, per the strict file scope:

- `lib/core/cloud/history_import.dart`
- `test/cloud_history_import_test.dart`

No other file was edited. The login-gate hook, consent sheet, flag collapse,
and store deletions remain the later Task 20 step.

## Contract anchors (built code, not plan sketches)

- `CloudRestClient.importMessages({sessionId, title, createdAt, messages})`
  (`lib/core/cloud/cloud_rest.dart`).
- `ImportMessage` / `ImportReport` (`lib/core/cloud/models.dart`).
- `POST /import/sessions` (`cloud/apps/gateway/src/routes/import.ts`):
  strict body, per-message `{clientMsgId, role, content, createdAt}`, max 500
  per call, empty batch rejected, duplicate `(session, clientMsgId)` skipped.
- Transcript namespace keys `ovid_sessions` / `ovid_sessions_owner_<encoded>`
  (`state.dart` `_accountKey`, lines 1525-1532, 2226).
- Ledger `SessionLedger.storedSessionIds()` + `read(id)`; per-account memory
  root derived exactly like `AppState._memoryRootForAccount` (line 3854).

## Interface

The pinned `HistoryImportPlan`, `HistoryImportResult`, and
`HistoryImportService` shapes are implemented as specified. Two optional
constructor seams were added without changing the pinned required arguments:

- `String? account` — the later login wiring should pass
  `AppState.sessionAccountId` (`firebase:<uid>` / `guest`). When omitted the
  service discovers the account from the prefs namespaces deterministically.
- `Directory? memoryRoot` — test seam so unit tests never call path_provider.

`CloudRestClient` is **not final**, so the test seam is a subclass overriding
`importMessages` (same pattern as `test/cloud_session_store_test.dart`). No
`ImportTransport` interface was needed; a comment in the test says why.

## Behavior

1. **`plan()` is read-only.** It reads transcript rows through
   `SessionHistoryRepository.readRows` (SQLite authority or legacy prefs
   fallback) and the per-account done marker. It performs no network call and
   writes no preference. It deliberately does not touch the ledger/memory
   stores because `SessionLedger.storedSessionIds` / `MemoryStore.list` can
   create their roots; those stores are scanned during `run`.
2. **Consent is enforced in the service.** `run(consent: false)` returns an
   empty result, emits `skipped (no consent)`, and performs zero network calls
   and zero writes.
3. **Chunking.** `maxMessagesPerCall = 500`; 1,201 messages become
   `500 / 500 / 201`.
4. **Resumability.** `ovid_cloud_import_progress_<uid>` holds a per-session
   entry `{nextChunk, completed, sessionId}`. The first successful chunk stores
   the server session id; every later chunk (including a resumed one) continues
   that same session. On a failure at chunk 3 of 10, `completed = 2` and
   `nextChunk = 3`, so a fresh service instance resumes at chunk 4 and does not
   re-send chunks 1-3. A last-chunk failure is retried instead of being marked
   complete (otherwise the final messages would be lost).
5. **Idempotency key.** `clientMsgId` is `sha256(sessionKey + original message
   index + role + UTC createdAt + content)`, 64 hex chars. It is independent of
   the server session id and of any progress marker, so a re-run with lost
   markers produces identical ids and the server skips duplicates.
6. **`alreadyImported`** reads `ovid_cloud_import_done_<uid>`; `run`
   short-circuits with no network. The marker is only written when a run has no
   `failedSessionKeys`, so a partial run stays resumable.
7. **Ledger/memory** have no gateway route. `run` emits `ledger` then
   `skipped (server endpoint not live)`, and `memory` then the same string
   again. Their event/file counts are added to `result.skipped`; they are never
   silently dropped or reported as imported.
8. **Failures never lose the local data.** A failing session is listed in
   `failedSessionKeys`; its marker records `completed`/`nextChunk`; other
   sessions continue.
9. **Role mapping.** Only `user | assistant | system | tool` are uploaded.
   Anything else is omitted from the batch and counted in `result.skipped`.
   The plan previews every stored message.

Account marker names strip the `firebase:` prefix, matching the plan's
`ovid_cloud_import_{done,progress}_<uid>`. Namespace lookup accepts both the
encoded production account (`ovid_sessions_owner_firebase%3A<uid>`) and a bare
UID key, so fixtures and production agree.

## Tests (12, all passing)

- plan counts from SQLite authority and from the legacy prefs fallback
  (including the bare-uid namespace and `firebase:` alias)
- plan is read-only (no calls, no prefs writes)
- zero calls / no writes without consent
- `alreadyImported` short-circuit with no calls
- 1,201-message chunking 500/500/201 in one server session
- failure at chunk 3, marker inspection, fresh-instance resume at chunk 4
  without re-sending chunks 1-3
- deterministic, 64-hex `clientMsgId`s across runs with a lost marker
- ledger/memory stage text (twice) and skipped counts
- role mapping and unknown-role skipping
- `failedSessionKeys` for one session while another still imports; last-chunk
  retry; completed sessions not re-sent
- server-side `skipped` surfaced as a count, not an error

## Gates

- `flutter analyze --no-pub lib/core/cloud/history_import.dart test/cloud_history_import_test.dart`
  → **No issues found!**
- `flutter test --no-pub test/cloud_history_import_test.dart`
  → **12/12 passed.**
- Full `flutter analyze --no-pub` → 7 pre-existing issues in
  `cloud_session_store.dart`, `studio_files.dart`, and `studio_pty.dart`
  (other agents' in-flight files); **none in this task's files**.

## Deferred to the later Task 20 wiring step

- `lib/ui/history_import_sheet.dart` (consent/progress UI) and the
  `login_gate.dart` post-login hook.
- Passing `AppState.sessionAccountId` explicitly when constructing the service.
- Deleting `session_ledger.dart` / `memory_store.dart` and their tests. Until
  then this service reads them; the deletion step must either keep the
  read-only skip reporting or remove those stages together with the files.
- Flag collapse / first-run flow / owner-gated Play + privacy items.
