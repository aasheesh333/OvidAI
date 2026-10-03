# P4 scheduler implementation plan

**Goal:** Durable, session-owned schedules with honest Android background status.

**Architecture:** A clock-injected coordinator claims each occurrence durably before dispatch. Session maps remain the storage format. Running claims recovered after process loss are paused with unknown outcome, never replayed automatically. A single deadline timer and an inexact AlarmManager alarm replace continuous polling. Android stores an independent explicit-stop latch checked before every service start/update and alarm.

**Constraints:** Work only in `/tmp/opencode/wt-schedule`, branch `wip/schedule`; no commits. No control overlay or natural task-return changes. Flutter tests use `/root/flutter/bin/flutter test --concurrency=2`.

## Sequence
- [x] Add fake-clock tests for persistence-before-dispatch, crash recovery, concurrent ticks, stop races, fixed-rate recurrence, daily dates, and bounded safe retries; implement `lib/core/schedule_coordinator.dart`.
- [x] Connect session persistence, schedule tools, run results, deadline arming, startup reconciliation, and cancellation in `agent_service.dart`.
- [x] Add Schedule above Trajectory and a session schedule screen with status, next date/time, edit, pause/resume, cancel, and background constraints; verify widgets.
- [x] Integrate native stop latch, permitted inexact alarms, foreground failure reporting, retained engine lifecycle, and reboot rearming. Stop/Exit must cancel alarms and reject stale updates.
- [x] Run focused and regression Flutter tests, Dart analysis, and Kotlin compilation if the installed Android toolchain permits. Record actual behavior and limitations.

## Semantics
One-offs accept a validated local date/time or ISO timestamp with explicit offset; stored deadlines are UTC. Daily `HH:mm` follows device-local calendar time (DST gaps normalize forward; repeated hours fire once). Interval recurrence is creation-aligned and skips missed slots. Overdue pending occurrences run once after recovery. Interrupted claimed occurrences pause for user review. Retries are bounded (0–3, default 0), exponential from 30 seconds, and only permitted for failures known to precede agent execution. Failed agent runs are not blindly replayed.

## Android contract
An active runtime can execute while the UI is backgrounded, subject to Android limits. Alarms are inexact and may be delayed by Doze. No background activity launch, exact-alarm permission, or unrestricted foreground-service start is attempted by an alarm/boot receiver. If the process is gone, the alarm posts a reopen notification; opening the app reconciles state. Explicit Stop pauses schedules and persists across service ticks/restarts until explicit resume. Idle schedules hold no wake lock and invoke no model.

## Handoff

Native production files touched (all under `android/app/src/main/`):
- `AndroidManifest.xml`: alarm/time-change receiver registration, corrected boot comments; no permission additions.
- `kotlin/com/dhanuk/ovidai/MainActivity.kt`: retained single Flutter engine, scheduling/stop-state method-channel endpoints, stop checks before start/update.
- `kotlin/com/dhanuk/ovidai/AgentForegroundService.kt`: stop latch, foreground-start failure reporting and termination, explicit receiver notification intents, no notification-only sticky restart.
- `kotlin/com/dhanuk/ovidai/AgentStopReceiver.kt`: persist Stop/Exit before Dart callbacks; cancel service/alarm without starting a new foreground service.
- `kotlin/com/dhanuk/ovidai/BootReceiver.kt`: rearm alarm rather than pretend the Dart agent restarted.
- `kotlin/com/dhanuk/ovidai/ScheduleAlarmReceiver.kt` (new): inexact alarm, clock/timezone refresh, notification to reopen when runtime is absent.
- `kotlin/com/dhanuk/ovidai/BackgroundStopLatch.kt` (new): persistence-backed stop policy.

Native test: `android/app/src/test/kotlin/com/dhanuk/ovidai/BackgroundStopLatchTest.kt` (2 JUnit tests).

Dart production files: `lib/core/schedule_coordinator.dart` (new), `lib/core/agent_service.dart`, `lib/core/agent_notification_service.dart`, `lib/core/state.dart` (reject false persistence result), `lib/main.dart` (resume reconciliation), `lib/ui/schedule_screen.dart` (new), `lib/ui/sidebar.dart`.

Control integration: no accessibility-service, corner-glow, overlay, or natural task-return edits. Shared `MainActivity.kt` and `agent_service.dart` scheduling hunks need normal merge review with the control branch. Notification Stop now means global background Stop (cancels runs/queues and pauses schedules); chat Stop retains session-local behavior and pauses its running scheduled task. Global Resume enables scheduling but does not silently replay paused tasks; resume individual tasks after reviewing their outcome.

Validation: focused scheduler/UI/background, session stop, overlay, sidebar, wake-lock and persistence regression tests; coordinator/UI also run with `TZ=America/New_York` for 23/25-hour daily boundaries. Modified Dart files analyze cleanly. `:app:compileDebugKotlin -x :app:processDebugGoogleServices --offline --max-workers=2` succeeds. Normal build and Gradle unit-test resource graph need the absent `google-services.json`; native latch tests were compiled with cached Kotlin compiler and run through JUnitCore successfully.

Limitations: no physical-device Doze/swipe/force-stop/reboot validation in this environment. Process death/reboot does not cold-start a second Dart engine: reopen is required, with an allowed notification when possible. Notification permission denial can prevent that prompt. Daily timezone means current device-local timezone, not an arbitrary IANA zone; one-off offset timestamps are fixed UTC instants. A failed agent execution stops that schedule for review; only known pre-dispatch failures receive the configured 0–3 retries (30/60/120 seconds). Existing approval gates may wait for user input. Retained Flutter-engine lifecycle has been compiled but needs device testing, especially native tools which require an attached Activity. External tool side effects are not exactly-once transactional; uncertain claims deliberately pause rather than duplicate effects.
