# Task 1 Report: Startup Coordinator

## Status

Implemented the startup coordinator state machine and deadline behavior from
design sections 5.2, 7, and 8.

## RED Evidence

- Initial focused test failed to compile because
  `lib/core/startup_coordinator.dart` and all required public types were absent.
- Deadline/retry/disable tests then failed because the initial sequential
  implementation ran queued external work after the deadline, did not rerun
  failed items, and did not invoke disable callbacks.
- The non-terminal result test failed because a task could return `running` and
  leave readiness incomplete.

## GREEN Evidence

- `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart`
  passed 7 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub` reported no issues.
- `git diff --check` passed.

## Files

- `lib/core/startup_coordinator.dart`
- `test/startup_coordinator_test.dart`
- `.superpowers/sdd/2026-09-10-startup-plugin-runtime-reliability/task-1-report.md`

## Self-Review

- Public coordinator model and methods match the binding design, with the
  brief-required `StartupDisable` and `StartupTask.onDisable` extension.
- Startup execution is sequential and isolated per item; exceptions and item
  timeouts become terminal statuses without stopping later work.
- The global deadline marks the running item degraded, skips queued external
  work, and permits queued local safety work to finish.
- A run token prevents stale task completions from replacing deadline states.
- Retry is item-scoped and guarded by the shared running-ID lock. Disable is
  limited to plugin/MCP tasks with callbacks and is idempotent after success.
- Error reasons use a private capped redactor; there is no hook runtime import.
- `.superpowers/brainstorm/` was not modified.

## Concerns

- Dart futures cannot cancel underlying timed-out work. The run token and
  running-ID lock prevent stale completion from changing coordinator state,
  but task implementations remain responsible for releasing their resources.
- Full regression was not run, as permitted for this isolated leaf task.

## Fix Round 1

### RED Evidence

- Deterministic `fake_async` deadline tests showed external work ran before a
  queued local migration and that queued local work could begin after expiry.
- A stale-invocation test showed Retry invoked the same task a second time while
  its deadline-expired source future was still unresolved.
- Direct task-result tests showed secret-bearing reasons were published without
  redaction or the 500-character cap.
- A concurrent `start()` test showed the superseded start future did not return
  at its own deadline.

### GREEN Evidence

- `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart`
  passed 13 tests, including exact 120-second boundary, hanging local task,
  competing timeout/deadline, and stale-future retry cases under `fake_async`.
- `/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub` reported no issues.
- `git diff --check` passed.

### Changes and Self-Review

- Local safety tasks are ordered ahead of external readiness tasks. At the
  global deadline all unfinished statuses become terminal and `start()` returns
  without waiting for task timeout or source-future completion.
- Raw task invocation lifetime remains locked independently of published
  timeout/deadline state. Retry, Disable, and a repeated Start cannot duplicate
  an unresolved task invocation; settlement clears the lock without replacing
  stale terminal status.
- Every task-returned reason is privately scrubbed and capped before it enters
  the snapshot. No hook runtime dependency was introduced.
- Real 10/20 ms waits were replaced with deterministic fake time, using the
  `fake_async` package already available through `flutter_test`.

### Concerns

- Timed-out Dart futures remain non-cancellable; the coordinator prevents
  duplicate invocation but task owners still control resource cancellation.
- Full regression remains outside this isolated leaf fix round.

## Fix Round 2

### RED Evidence

- A deterministic stale-disable test failed because completing a disable after
  a newer `start()` left the item lifetime lock held, so a subsequent Disable
  callback was never invoked.

### GREEN Evidence

- `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart`
  passed 15 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub` reported no issues.
- `git diff --check` passed.

### Changes and Self-Review

- Disable callback settlement now removes its lifetime lock unconditionally in
  `finally`, independent of the coordinator run token.
- Publishing Disabled or Failed remains guarded by both the captured run token
  and successful lock ownership removal, so a stale callback cannot overwrite
  a newer run's status.
- Added pins confirming task-returned null reasons remain null and ordinary
  non-secret reasons remain unchanged.

### Concerns

- Full regression remains outside this isolated leaf fix round.
