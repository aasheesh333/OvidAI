# Session Stop Isolation Report

## Status

Implemented and verified session-scoped Stop behavior. Chat and notification Stop actions now cancel only the session they represent. Notification Exit and direct `cancelAllRuns()` calls remain explicit global panic paths.

## Root Cause

At baseline `c8c5215`, `AgentService.stopRequested` treated an empty target queue as a panic request: it cleared every run bucket's queue and called `cancelAllRuns()`. The same cancellation helper also walked `AppState.childrenOf(sessionId)` and recursively cancelled child-session buckets. As a result, a Stop action in one chat could stop unrelated chats and subagents.

Two routing issues increased the risk:

- `ChatScreen` recomputed the target from mutable `AppState.I.activeSession` inside the button callback instead of retaining the session rendered by that composer.
- Notification Stop had no represented-session identity and called the global behavior directly.

The old `_cancelBucket` also emitted through `_emit`, whose zone/active-session resolution could deliver the stop event and status to a different bucket when cancellation originated outside the target run's zone.

## Fix

- Made `stopRequested` require a non-null `sessionId` and cancel only that bucket.
- Preserved the target bucket's queue when non-empty and left every other bucket's queue untouched.
- Removed recursive child-session cancellation from `_cancelBucket`.
- Kept process, background-job, approval, HTTP client/request, checkpoint, and PTY cleanup scoped to the target session.
- Wrote the stop event and status directly to the target `AgentRun` bucket.
- Passed the rendered session ID into `_InputBar` for busy, queue, and Stop behavior.
- Tagged notification progress with its session ID and made notification Stop fail closed when that represented session is no longer running, rather than falling back to another run.
- Retained `onAgentExit -> cancelAllRuns()` and verified that direct global panic still cancels both sessions.
- Updated obsolete STOP regression names/comments and source assertions without weakening the existing instant-stop checks.

## RED Evidence

Baseline source at `c8c5215` contained the failing behavior directly:

```dart
for (final b in _runs.values) {
  b.queue.clear();
}
cancelAllRuns();
```

It also recursively called `cancelRunFor(kid.id)` for child sessions. The pre-existing core regression encoded that obsolete contract by requiring both recursive child cancellation and global panic from Chat/notification Stop. The focused isolation assertions would fail against that baseline because session B's run, queue, process/job/PTY, and child run were cancelled when session A stopped.

During final regression verification, the first full core run exposed one stale source assertion for the old untagged `agentWorking('starting task...')` call. That run completed with 551 passing and 1 failing test; the assertion was updated to require `sessionId: s.id`.

## GREEN Evidence

- `flutter test test/session_stop_isolation_test.dart`: 5 passed.
- `flutter test test/core_regression_test.dart --plain-name STOP1`: 1 passed.
- `flutter test test/core_regression_test.dart --plain-name STOP2`: 1 passed.
- `flutter test test/core_regression_test.dart --plain-name "global panic remains explicit while Stop stays session-scoped"`: 1 passed.
- `flutter test test/core_regression_test.dart`: 552 passed.
- `flutter analyze lib/core/agent_service.dart lib/core/agent_notification_service.dart lib/ui/chat_screen.dart test/session_stop_isolation_test.dart test/core_regression_test.dart`: no issues found.
- `git diff --check`: clean.

Focused coverage proves:

- Empty-queue Stop cancels only the requested parent session.
- Non-empty-queue Stop preserves only the target session's queued continuation.
- Target process, job, and PTY are terminated while another session's resources remain live.
- Stop status/events land on the target bucket.
- Notification Stop cancels the session represented by progress.
- Stale notification progress never falls through to a different running session.
- Explicit `cancelAllRuns()` still cancels both sessions and all tracked processes.

## Concerns

No correctness blockers found. Generic lifecycle notification refreshes in `main.dart` do not carry a session ID; they intentionally do not replace the last concrete progress owner. If that owner has already stopped, notification Stop is a safe no-op rather than risking cancellation of another session.

## Review Fix Round

Review of `c8c5215..8107016` found four remaining lifecycle gaps. They were reproduced in `session_stop_isolation_test.dart` before the implementation was hardened:

- Global panic cancelled active buckets without first clearing their queued continuations, allowing each run's `finally` block to start queued work again.
- Notification ownership changed when an update was scheduled, before the native start/update succeeded, so its Stop action could target content not yet displayed.
- `interrupt_agent` inherited ordinary session Stop isolation and therefore left descendant subagents running.
- Targeted cancellation appended directly to `runEvents`, bypassing the event cap and shared session-event handling.

The fix round now:

- Clears every bucket queue before global cancellation and keeps notification Exit on that path.
- Commits notification Stop ownership only after a successful native update. Pending or failed updates retain the displayed owner; a completed represented run deterministically schedules a surviving run for display, with ownership changing only after success.
- Adds `cancelRunTreeFor` exclusively for explicit subagent interruption; ordinary chat Stop remains one-session-only.
- Routes cancellation through bucket-aware `_emitToRun`, preserving the 120-event cap, status updates, session logging, and notification lifecycle without resolving through the caller's Zone.
- Strengthens coverage with separate foreground/job processes, HTTP close/abort assertions, PTY termination and survival checks, a rendered `ChatScreen` Stop interaction, queued global panic and notification Exit tests, pending/failed/successful notification ownership tests, subtree interruption, and event-cap verification.

### Review RED Evidence

The expanded focused suite initially failed in five places:

- Pending notification update left session A active because ownership had already switched to B.
- `cancelAllRuns()` left `must not restart A` in session A's queue.
- Notification Exit left `queued A` in session A's queue.
- Interrupting a parent subagent left its child run active.
- Targeted Stop grew a 120-entry event list to 121.

### Review GREEN Evidence

- `flutter test test/session_stop_isolation_test.dart`: 11 passed after implementation; the final run includes the rendered-chat widget path and independent HTTP/process/job/PTY assertions.
- `flutter test test/core_regression_test.dart --plain-name STOP1`: 1 passed.
- `flutter test test/core_regression_test.dart --plain-name STOP2`: 1 passed.
- `flutter analyze lib/core/agent_service.dart lib/core/agent_notification_service.dart lib/ui/chat_screen.dart test/session_stop_isolation_test.dart test/core_regression_test.dart`: no issues found.
- Targeted process, job, HTTP request/client, and PTY cleanup assertions pass while session B's equivalents remain alive.
- Notification ownership tests cover A displayed while B is pending, B update failure, successful transfer to B, and deterministic transfer after A finishes.
- Global panic and real notification Exit both clear queues before cancelling all buckets.

The required full `core_regression_test.dart` run was executed once. It completed 549 tests successfully and reported three failures in pre-existing plugin migration/install tests (`PLUGIN9 pendingGlobal`, `PLUGIN11 detail sections`, and `PLUGIN11 mounted MCP`). Those failures are outside session-stop ownership and reproduce in migration/runtime state that this fix round was explicitly prohibited from changing. STOP1, STOP2, and all focused isolation tests pass independently.
