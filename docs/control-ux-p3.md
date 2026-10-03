# P3 Control UX

## Behavior

- Natural task completion selects the originating session, reveals the chat
  route, and requests Ovid's foreground launch with that session ID. Interim
  tool `done` events do not return to Ovid or retire Control status. Errors and
  explicit Stop do not request a completion focus jump. The existing blocked
  launch explanation remains available in the originating transcript.
- Steering text and question answers follow the live Control owner even after
  the foreground chat changes. Other sessions' progress cannot recolor or
  remove that run's glow.
- Four independent 80dp, non-touchable accessibility-overlay windows render
  radial corner gradients. One 1600ms reversing animator changes their alpha;
  the circle has no colored stroke or breathing animation. These windows are
  independent of the steering bubble, so foregrounding Ovid hides the bubble
  while Control status remains visible.
- Green means working; yellow means awaiting approval **or an answer to a
  question**; red means a current-run error. Recovering into another model turn
  restores green. **Idle/unknown means no glow/window**. Terminal errors remove
  the glow during cleanup, so the persistent error record is the transcript.
- Disabled system animators and touch exploration use static corner gradients.
  The bubble and Stop control expose accessibility descriptions.
- The expanded box's X is now immediate Stop, including with a draft present.
  Native Stop invalidates pending results and queued gestures before the Dart
  callback. Dart closes active generation sockets/processes through the existing
  run cancellation path, clears Control queues, and cancels dictation. Late
  results, retry dispatches and voice callbacks are discarded. Other modes keep
  their established queue continuation semantics.
- Stop, mode exit, terminal cleanup, service interruption/unbind/destroy, and
  activity teardown remove Control windows and invalidate device work. A fresh
  Control run explicitly opens a new device generation.
- Notification Stop/Exit use the existing Dart notification bridge. The
  scheduler-owned foreground service, receivers and MainActivity scheduler
  routes have no Control changes. Overlay Stop cancels natively before its
  bridge event; notification Stop cancels through the targeted Dart run path.
- Background admission attaches steering to the admitted Control owner. A
  delayed return callback cannot cancel a newer task's device generation.
- Android has no recall API for an accessibility gesture already dispatched to
  the OS. That stroke can finish; queued strokes, outstanding results and future
  dispatches are cancelled. Screenshot buffers are released even when cancelled.
- Desktop tabs keep a real 1280×800 viewport (8:5). Height-fit scaling preserves
  that ratio; a per-tab horizontal pan controller and visible draggable scrollbar
  expose overflow width. Vertical document scrolling stays inside the WebView.

## Verification

Behavioral coverage lives in `test/control_return_test.dart`,
`test/device_actions_cancel_submit_test.dart`,
`test/browser_desktop_geometry_test.dart` and
`android/app/src/test/kotlin/com/dhanuk/ovidai/ControlLifecycleTest.kt`.
Obsolete source-string assertions for the prior full-width edge strips and
bubble animation were retired in favor of state/lifecycle tests.

Use `/root/flutter/bin/flutter test --no-pub --concurrency=2` with the Control,
device, desktop geometry, voice and session-stop test files. Run
`/root/flutter/bin/dart analyze` separately.

Android compilation is available through the cached Gradle 9.1.0 distribution:

```sh
gradle :app:compileDebugKotlin -x :app:processDebugGoogleServices \
  --offline --max-workers=2 --console=plain
```

The normal Android unit-test task requires the untracked `google-services.json`,
which is absent here. Skipping its generation lets Kotlin compile, but Android
resource mapping still blocks the full unit-test task. The six pure lifecycle
tests can instead be compiled with the cached Kotlin compiler and run using
JUnit 4.13.2 without Android resources. No Firebase configuration was fabricated.

## Device-only checks

1. Run Control from chat A, select B, then background Ovid. Complete several
   tools: focus must stay on the driven app until final completion returns to A.
   Repeat with Browser/Studio open and with background launches blocked by an OEM.
2. Observe all four corners in portrait/landscape, gesture/three-button navigation,
   and with a display cutout. Check green → yellow → green, recoverable red →
   green, terminal error removal; the circle must remain plain.
3. Enable TalkBack/touch exploration or disable animator duration scale. Check
   static gradients, readable Stop semantics, and no interception of app taps.
4. Stop from a populated overlay box, app composer and notification during a
   stream, approval, gesture, reconnect retry, screenshot consent and dictation.
   Queued Control instructions must not run; late callbacks must not restart work.
   One already-dispatched OS stroke may finish.
5. Repeat show/hide, rotation, mode exit, service disable/unbind, Exit, and activity
   teardown. Inspect for leftover windows, keyboard focus, animators or captures.
6. In desktop browser mode, pan to the far right with both drag and scrollbar,
   then scroll a long page to its bottom and activate a bottom-right control.
   Verify Chromium's real viewport/media-query geometry remains 1280×800 and
   that platform-view gesture arbitration works on actual Android WebView.
