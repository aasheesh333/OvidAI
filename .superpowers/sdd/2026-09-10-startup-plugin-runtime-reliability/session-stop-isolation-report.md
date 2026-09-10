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
