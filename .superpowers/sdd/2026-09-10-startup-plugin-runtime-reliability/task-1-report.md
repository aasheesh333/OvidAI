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
