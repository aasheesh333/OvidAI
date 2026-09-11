# Startup and Plugin Runtime Reliability — Task 9 Release Gate Audit

Date: 2026-09-11 · Branch `hoplite/gortyn-77773150` · Baseline `8464bd2`

This audit is the release gate for the Startup and Plugin Runtime Reliability
project (spec `docs/superpowers/specs/2026-09-10-startup-plugin-runtime-reliability-design.md`
§8, §12, §13). It records the automated verification matrix, the synthetic
fixtures, the measured first-frame and 120-second deadline behavior, the
runtime-skill/session-hook integration, the legacy migration recovery, the
debug APK artifact, and the physical-Android checklist with its execution
status.

**Device smoke was NOT executed.** No Android device or emulator is attached to
this environment — `flutter devices` reports only the Linux desktop target and
`adb devices` lists no devices. The checklist in §8 is therefore marked
`NOT EXECUTED`, not `passed`. Nothing on-device was run and nothing on-device
is claimed.

## 1. Verification matrix (exact counts)

All commands run with `/home/ubuntu/sdk/flutter/bin/flutter` on 2026-09-11.

| Command | Result |
|---|---|
| `flutter test test/startup_coordinator_test.dart` | 19/19 passed |
| `flutter test test/startup_first_frame_test.dart` | 35/35 passed |
| `flutter test test/plugin_runtime_migration_test.dart` | 34/34 passed |
| `flutter test test/plugin_runtime_skills_test.dart` | 18/18 passed |
| `flutter test test/session_plugin_lifecycle_test.dart` | 21/21 passed |
| `flutter test test/startup_tasks_test.dart` | 32/32 passed |
| `flutter test test/startup_status_persistence_test.dart` | 25/25 passed |
| `flutter test test/startup_progress_widget_test.dart` | 17/17 passed |
| `flutter test test/startup_performance_test.dart` | 5/5 passed (new) |
| `flutter test test/core_regression_test.dart` | 555/555 passed (552 + 3 new Task 9 pins) |
| `flutter test` (all files) | 785/785 passed (777 + 5 performance + 3 integration) |
| `flutter analyze --no-pub` | No issues found (ran in 5.1s) |
| `flutter build apk --debug` | Built `build/app/outputs/flutter-apk/app-debug.apk` |
| `git diff --check` | clean |

The build emits non-fatal `llvm-strip: … libovid_bootstrap.so: The file was not
recognized as a valid object file` warnings for the three ABIs. The APK still
builds and is produced; these are pre-existing toolchain strip warnings, not
gate failures. They are recorded here rather than hidden.

## 2. First-frame performance (spec §8: under 3 seconds)

New file: `test/startup_performance_test.dart`.

Fixture (`_worstCaseFixture()`): 100 archived sessions with 2 KB message bodies
plus one unparsable row, and one active session with 5,000 messages of ~200
bytes each, with `ovid_active_session: active`. Optional and plugin stages are
wired to a `Completer` that never completes (`marketplace.refresh`,
`mcp.connect`, `firebase.initialize`, `github.initialize`, `sandbox.selfHeal`,
`plugin.activate`).

Measured with a temporary in-repo measurement test (deleted after use), same
fixture and hanging delegates:

- cold first call (isolate decode path): **296 ms**
- warm second call: **139 ms**

Both are under the 3-second budget with an order of magnitude of headroom. The
permanent test asserts `initializeForFirstFrame()` completes under
`_firstFrameBudget = 3 s`, that the recorded stages are exactly
`['local.firstFrame']`, that no optional stage ran, and that the hanging
completer is still incomplete.

**Disclosure:** this is the only wall-clock assertion in the file. The fixture
drives real `dart:io` session decode and preference IO, which `fake_async`
cannot virtualize; the 120-second deadline assertions below use fake time and
are exact. The cold/warm numbers above are single-host measurements, not a
guarantee for every device — the release gate is the `< 3 s` assertion plus the
device checklist in §8.

## 3. 120-second readiness deadline and per-item isolation (spec §8/§13)

Also in `test/startup_performance_test.dart`, using `fake_async` and the real
`MarketplaceRefreshTask`, `McpConnectTask`, and `FirebaseStartupTask`:

- `hanging marketplace and MCP reach terminal degraded at exactly 120s`: a
  local-state item completes, a marketplace item whose own timeout is 300 s is
  still `running`, an MCP item and a Firebase item are still `queued`. At
  `119.999 s` the run is not complete; at exactly `120.000 s` the run completes
  with `deadlineExceeded == true` and `readinessComplete == true`. The running
  marketplace becomes `degraded` with reason `Startup readiness deadline
  exceeded`; the queued MCP and Firebase items become `skipped` with the same
  reason. The queued MCP item keeps its canonical owner id `acme/slow-mcp`.
- `local safety work is never skipped by the global deadline`: a running
  local-state item is terminalized at 120 s and a queued local item is also
  terminalized (degraded), never executed; the queue still completes.
- `a hanging item degrades at its own timeout and later items run`: an MCP item
  with a 31 s timeout degrades with `Timed out after 31s` and the following
  marketplace item still reaches `ready`; `deadlineExceeded == false`. This is
  the per-item isolation pin.

The global-deadline semantics themselves (exact boundary, retry lock, disable
lock) are additionally covered by the pre-existing
`test/startup_coordinator_test.dart` (19/19).

## 4. Runtime skill and session hook integration

New cross-task group in `test/core_regression_test.dart`:
`Task 9: cross-task startup runtime integration` (3 tests). Fixtures use a real
local-folder plugin (`LocalFolderPluginSource`) with
`.claude-plugin/plugin.json` (`name: Research Kit`, `author: acme`),
`skills/research/SKILL.md` (`RESEARCH BODY`), and, for the hook test, a
`hooks/hooks.json` declaring `SessionStart`.

- **Install scope then one-restart promotion**: `inspect` → save
  `PluginPermissionGrant` → `AppState.installPlugin(origin: agent,
  sessionId: 'A')`. Immediately after install the installing session `A`
  resolves `plugin:acme/research-kit/skill:research` with content
  `RESEARCH BODY`, while session `B` resolves nothing. After
  `AppState.resetTestInstance()` and a second `AppState.initializeReadiness()`
  (one restart), both `A` and `B` resolve the skill and the persisted row is
  `PluginActivation.globalActive` + `enabled`.
- **`session_start` exactly once for every reason with the runtime skill
  visible**: the real installed runtime is promoted globally, then
  `SessionLifecycleService.I.sessionStarted` is called twice per reason
  (`created`, `implicit`, `restored`, `subagent`) through the real
  `HookService` executor. Exactly four events fire (one per session), and the
  executor observes the mounted `research` skill in
  `SkillService.skillsForSession(sessionId)` for all four.
- The AppState creation paths themselves (`newSession`, implicit first,
  restored active, subagent `dispatch_agent`) and hook ordering remain pinned
  by `test/session_plugin_lifecycle_test.dart` (21/21).

## 5. Legacy migration recovery

Third cross-task test in `test/core_regression_test.dart`. It seeds legacy
installed/enabled rows with a hook map (`on_turn_start`) and a cached
`skills/legacy-skill/SKILL.md`, then boots the readiness queue.

- After `local.hydrate` + `localSafety.migrate`, the row is `enabled == false`,
  `PluginActivation.disabled`, `migrationRequired == true`, with reason
  containing `Re-approve`, and the safety aggregate is
  `StartupItemState.migrationRequired`.
- The legacy hook map does not execute (`HookService.fire('on_turn_start', …)`
  makes zero executor calls), `hasLegacyMapHookListeners('on_turn_start')` is
  false, and the cached legacy skill is absent from the catalog.
- The recovery path then runs `inspect` → approve → `installPlugin` →
  `activateForBoot`. The row becomes `runtimeId == acme/research-kit`,
  `migrationRequired == false`, `enabled == true`; the normalized skill resolves
  with `RESEARCH BODY`, the legacy skill stays absent, and the normalized hook
  is registered.

Migration/row/grant behavior is additionally pinned by
`test/plugin_runtime_migration_test.dart` (34/34) and
`test/plugin_runtime_skills_test.dart` (18/18).

## 6. Debug APK artifact

| Field | Value |
|---|---|
| Path | `build/app/outputs/flutter-apk/app-debug.apk` |
| Size (bytes) | 213,608,503 |
| Size (human) | 204 MiB |
| SHA-256 | `60ba182f8fdfcf9d6f220bbb70c9ded223ca759035258ce3738a874a15cb704e` |
| Build command | `flutter build apk --debug` |
| Build time | 340.9 s |

This is a debug build; it is an artifact-integrity and buildability gate, not a
release-signed artifact.

## 7. Offline startup and observability

- **Offline startup**: the first-frame test never runs `marketplace.refresh`,
  `mcp.connect`, `firebase.initialize`, `github.initialize`, or
  `sandbox.selfHeal`; `test/startup_first_frame_test.dart` pins that the
  production `main()` renders before readiness starts and that first-frame
  initialization contains no direct optional-service calls.
- **Durable status**: `test/startup_status_persistence_test.dart` (25/25) pins
  the persisted `PluginRuntimeStatus` records, scrubbing, capping, and
  capability-truthful health. `startup_coordinator.dart` emits terminal
  transitions to the status sink; the `localSafety.migrate` and `plugin.activate`
  items surface state + scrubbed reason. A debug-only timeline export is not
  newly added by Task 9; no new behavior was introduced beyond the verification
  surface.
- **Compatibility seam**: the fully-awaited `AppState.initialize()` path remains
  and is exercised by the cross-task tests and the pre-existing suites.

## 8. Physical Android smoke checklist (spec §12)

Status legend: `PASSED` = executed on a physical Android device/emulator;
`FAILED` = executed and failed; `NOT EXECUTED` = no device/emulator attached.

Environment: `flutter devices` → only `Linux (desktop)`; `adb devices` → no
devices attached. Therefore **every row below is `NOT EXECUTED`**.

| # | Check | Status | Evidence / notes |
|---|---|---|---|
| 1 | Offline startup: launch with no network, shell/composer usable, first frame < 3 s | NOT EXECUTED | No Android device/emulator attached. Automated offline first-frame pin: 296 ms cold / 139 ms warm on host. |
| 2 | One hanging MCP: does not block first frame; item degrades at its budget | NOT EXECUTED | No device. Automated fake-time pin in `startup_performance_test.dart`. |
| 3 | One missing-credential MCP: shows `Needs setup: <ENV>` and never dials | NOT EXECUTED | No device. Automated `startup_tasks_test.dart` pin. |
| 4 | One runtime skill: appears in the installing session, hidden elsewhere before promotion, global after restart | NOT EXECUTED | No device. Automated cross-task pin in `core_regression_test.dart`. |
| 5 | One `SessionStart` hook: fires exactly once per session reason | NOT EXECUTED | No device. Automated cross-task + lifecycle pins. |
| 6 | One legacy plugin migration: disabled `Migration required`, cannot execute, then normalized install works | NOT EXECUTED | No device. Automated cross-task + migration pins. |
| 7 | 120 s deadline: open degraded with per-item reasons/Retry/Disable | NOT EXECUTED | No device. Automated fake-time + widget pins. |
| 8 | APK installs and launches on-device | NOT EXECUTED | No device; APK built and SHA-pinned in §6. |

## 9. Concerns and limitations

1. **No on-device verification.** ABI/OEM behavior (stdio MCP, sandbox exec,
   notification/lifecycle) remains unverified until a release owner runs §8 on
   a physical device.
2. **Wall-clock first-frame assertion.** The 3-second assertion is host wall
   clock because the fixture performs real local IO. It has ~10x headroom on
   this host; a very slow CI host could in principle flake. The 120-second
   deadline assertion is fake-time exact.
3. **Debug APK size.** 204 MiB is a debug artifact; not representative of a
   release build.
4. **Strip warnings.** `llvm-strip` does not recognize the debug
   `libovid_bootstrap.so` objects; the build still succeeds. Tracked as a
   toolchain warning, not a gate failure.
5. **Task 8 deferred minors** (per-runtime base-stage delegate re-invocation;
   disabled/excluded rows lose the aggregate status sweep) remain as documented
   in the Task 8 report and are not release blockers for this gate.

## 10. Gate decision

Automated gates are green: all focused suites, the full core regression
(555/555), the full Flutter suite (785/785), `flutter analyze` (no issues), the
debug APK build, and `git diff --check`. The on-device smoke checklist (§8) is
`NOT EXECUTED` because no Android device/emulator is attached; on-device release
sign-off must therefore remain open until a release owner completes it.
