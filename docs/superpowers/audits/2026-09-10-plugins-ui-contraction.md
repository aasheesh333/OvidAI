# Plugins/MCP UI Contraction — Task 4 Release Gate Audit

Date: 2026-09-12 · Branch `hoplite/gortyn-77773150` · Baseline `c1cfb16` · Task 4 verification commit (this commit)

This audit is the release gate for the Plugins/MCP UI Contraction project (spec
`docs/superpowers/specs/2026-09-10-plugins-ui-design.md`). It records the
automated verification matrix and the per-outcome evidence for the three promised
behaviors (GitHub-only install, single "+" sheet, durable MCP status with
reasons), then the device-only checklist with its execution status.

**Device checks were NOT executed.** No Android device or emulator is attached
to this environment. Every on-device row in §7 is marked `NOT EXECUTED`, not
`passed`. Nothing on-device was run and nothing on-device is claimed.

This is a test/docs-only task. No production behavior was changed. The new
end-to-end gate surfaced no defect, so no RED-first fix was required.

## 1. Verification matrix (exact counts)

All commands run with `/root/flutter/bin/flutter` on 2026-09-12,
working tree at baseline `c1cfb16` plus the Task 4 test/docs changes.

`flutter --version`:

```text
Flutter 3.47.4 • channel stable • https://github.com/flutter/flutter.git
Framework • revision 9584c6713b (34 hours ago) • 2026-09-10 15:25:10 -0700
Engine • hash 0e228ec8c8d2abc9fcf1d053e8a40665bb859ec7 (revision 06a2e2a110) (8 days ago) • 2026-09-03 16:07:13.000Z
Tools • Dart 3.13.3 • DevTools 2.60.0
```

`ANDROID_HOME=/opt/android-sdk`, Java 17 present.

| Command | Result |
|---|---|
| `flutter test test/plugins_ui_parity_test.dart` | 7/7 passed (new) |
| `flutter test` (3 plugins-contraction suites) | 30/30 passed (7 parity + 8 github-only + 15 durable-status) |
| `flutter test` (all files) | 1017/1017 passed (1010 baseline + 7 new) |
| `flutter analyze --no-pub` | 2 pre-existing warnings, 0 errors (ran in 6.0 s) |
| `flutter build apk --debug` | FAILED (toolchain, see §8 — no APK produced, no SHA) |
| `git diff --check` | clean |

The focused set is `plugins_ui_parity`, `plugins_ui_github_only`, and
`plugins_mcp_durable_status`.

`flutter analyze` reports only two pre-existing
`unawaited_return_in_try_block` warnings
(`lib/core/agent_service.dart:6780`, `lib/core/hook_service.dart:317`).
Neither file is touched by this task (test/docs-only); the new parity test
introduces no analyzer issue. There are no errors.

`pubspec.lock` was not dirtied: `git status` shows only the three intended
files (no lock bump to revert).

## 2. GitHub-only install UI (spec §5.1)

`showPluginAddSheet` is the only install entry and carries only the GitHub
route into the unchanged single inspection/approval flow
(`lib/ui/plugins_screen.dart:318`, `_githubSourceFromInput` at `:546`,
`_runSourceInstall` at `:561`, fetch call at `:419-421`). The five removed
routes (local folder, ZIP, npm, pasted config, direct-MCP server) are absent
from the sheet slice, the two file-picker seams
(`pluginPickDirectoryForTest`, `pluginPickZipFileForTest`) plus their
`FilePicker` call sites are gone, and the old `showPluginSourceChooser`
entry point no longer exists anywhere in the file. Core `addCustomMcpServer`
in `lib/core/state.dart` is untouched (spec non-goal: forward-compat and
existing custom servers stay manageable).

The new gate pins this at both levels: the contracted-surface test asserts
the sheet keeps `Fetch from GitHub` + `_githubSourceFromInput` +
`_runSourceInstall` and asserts the absence of every removed route string,
seam, and chooser name; the single-sheet widget test asserts the opened
sheet shows `Fetch from GitHub` while `Local folder` and
`Add custom MCP server` render nothing.

## 3. Single "+" sheet (spec §5.2)

One AppBar `Icons.add` action (`tooltip: 'Add plugin or marketplace'` at
`lib/ui/plugins_screen.dart:773` → `showPluginAddSheet(context)` at `:776`)
opens one sheet (`Add plugin or marketplace` header at `:360`) with a shared
repo field feeding both `Fetch from GitHub` (`:419-421`) and
`Add marketplace` (`addMarketplace` + `fetchMarketplaceCatalog` at `:443`,
`:465`, `YOUR MARKETPLACES` list at `:478`). Refresh stays a separate AppBar
action (`:765`). Deleted entries are gone: standalone marketplace dialog
route, extension install button, `_AddMcpTile`, `_addMcpDialog`,
`_importMcpConfig`. Detail-screen Install without a derived source falls
back to the sheet (`:1355`). An empty MCP list renders the hint
`Use + to add from GitHub` (`:1921`).

The new gate pins: the marketplace-routing test asserts the sheet carries
`addMarketplace` + `fetchMarketplaceCatalog` + `Add marketplace` +
`YOUR MARKETPLACES`; the AppBar widget test asserts refresh + exactly one
`+` (one `Icons.add`, one combined tooltip, no `Add marketplace` tooltip),
the empty-list hint, and that tapping `+` opens one sheet showing both
`Fetch from GitHub` and `Add marketplace` with no removed entries and no
exception.

## 4. Durable MCP status with reasons (spec §5.3)

Every MCP outcome path records the durable store under the server's
canonical id, never throwing into the toggle path: helpers `_recordMcpStatus`
/ `_recordMcpReady` (`ready`/`connected`) / `_recordMcpFailed`
(`failed`/redacted) / `_recordMcpNeedsSetup` (`needsSetup`/missing names) /
`_recordMcpDisabled` (`disabled`/`disconnected — tap Connect to start`) at
`lib/core/state.dart:5271-5320`, shared mapping `_recordMcpConnectDurable`
at `:5326-5343`, wired into `toggleMcpServer` (`:5345-5382`), the startup
connect/disable pair (`_connectMcpForStartup` at `:2113-2185`,
`_disableMcpForStartup` at `:2187-2221`), and both `reconnectServices` arms
(`:5448-5464`). `recordStartupStatus` (`:1351-1375`) backfills canonical MCP
`ready`/`disabled` reasons so the later coordinator sink write cannot clobber
them back to null. UI reads durable only: `durableMcpStatus` (`:93-94`) +
`mcpDurableStatusText` (`:99-105`, `Not started` at `:101`), `McpCard`
icon/label/border (`:2015-2031`, `:2055-2064`, `:2079-2104`),
`McpDetailScreen` header status (`:2208-2232`), diagnostics owned-MCP row
(`:1599-1602`). No-record rows render faint `help_outline` + `Not started`
+ neutral hairline — never `serviceStatus`, never
`connected`/`installed`/`enabled` inference. The Connect/Disconnect toggle
(`:2262`) and the `Unsupported on this device` / `Needs setup` banners stay
as live structural guards.

The new gate pins at runtime (no source-substring checks for behavior):
toggle success records `ready`/`connected` with live `working` intact;
toggle failure records `failed` with `[REDACTED]` (secret absent) and live
`failed`; credential block records `needsSetup` naming the missing env;
disconnect records `disabled` with the em-dash reason and clears the live
entry; `mcpDurableStatusText` returns `Not started` with no record and
`Ready · connected` once recorded; the `McpCard` widget renders neutral
despite a live `working` entry and renders `Ready · connected` after the
durable write; the diagnostics source check asserts the binary
`s.connected ? 'Connected' : 'Not connected'` template is gone and
`mcpDurableStatusText(s)` is wired.

## 5. Plugin rows and legacy scope (spec §3 non-goals)

Plugin runtime rows already render neutral for no-record cases and were left
untouched; legacy flag-flip rows without a `runtimeId` keep their
availability + enabled display (no canonical store covers them). The core
multi-source install transaction (`PluginSource` types, inspect → approval
→ `installPlugin`) is unchanged. The README now documents the contracted
shipped contract (`README.md`, Plugin formats + MCP servers sections). No
widget redesign beyond the contraction was in scope and none was made.

## 6. README

`README.md` (Plugin formats) now states the UI offers only the GitHub route
through exactly one "+" sheet (fetch plugin vs add marketplace, each
marketplace itself a GitHub repo), with the core transaction still accepting
every source type for forward-compat. `README.md` (MCP servers) now states
every MCP row/card/detail/diagnostics entry shows the durable canonical
status plus reason, `Not started` when no record exists, and that all four
outcome paths record durably under the canonical id. Both edits are small
and factual; no other README sections changed.

## 7. Device-only checks

Status legend: `PASSED` = executed on a physical Android device/emulator;
`FAILED` = executed and failed; `NOT EXECUTED` = no device/emulator attached.

Environment: no Android device/emulator is attached to this environment.
Therefore **every row below is `NOT EXECUTED`**.

| # | Check | Status | Evidence / notes |
|---|---|---|---|
| 1 | Single "+" opens one sheet offering GitHub fetch and marketplace add, with no local/ZIP/npm/paste/direct-MCP entries on-device | NOT EXECUTED | No device. Automated pins in `plugins_ui_parity_test.dart` (contracted-surface + single-sheet widget tests) / `plugins_ui_github_only_test.dart`. |
| 2 | GitHub fetch inspects, asks one capability approval, and installs on-device | NOT EXECUTED | No device. Core transaction covered by existing regression suites; UI route pinned by the parity sheet widget test. |
| 3 | Marketplace add from the same sheet imports and lists the catalog on-device | NOT EXECUTED | No device. Automated sheet-routing pins in `plugins_ui_parity_test.dart` / `plugins_ui_github_only_test.dart`. |
| 4 | MCP connect success shows durable `Ready · connected` after restart on-device | NOT EXECUTED | No device. Automated runtime + widget pins in `plugins_ui_parity_test.dart` / `plugins_mcp_durable_status_test.dart` (MockClient handshake, SharedPreferences mocks). |
| 5 | MCP failure / needs-setup / disabled rows show durable reasons, and a never-run server reads `Not started` on-device | NOT EXECUTED | No device. Automated runtime + `McpCard` neutral pins in `plugins_ui_parity_test.dart` / `plugins_mcp_durable_status_test.dart`. |
| 6 | Plugin diagnostics MCP row shows durable `label · reason`, never binary `Connected/Not connected`, on-device | NOT EXECUTED | No device. Automated source + helper pins in `plugins_ui_parity_test.dart` / `plugins_mcp_durable_status_test.dart`. |
| 7 | APK installs and launches on-device | NOT EXECUTED | No device; debug APK did not build in this environment (see §8). |

## 8. Debug APK artifact

The debug build **failed for toolchain reasons** and produced no APK. The
failure is recorded exactly rather than fabricating a SHA.

| Field | Value |
|---|---|
| Path | N/A (no APK produced) |
| Size (bytes) | N/A |
| SHA-256 | N/A (NOT EXECUTED — build failed, nothing to hash) |
| Build command | `flutter build apk --debug` (with `PATH=/root/flutter/bin:$PATH`, `ANDROID_HOME=/opt/android-sdk`) |
| Build time | 58.1 s (Gradle `assembleDebug` failed with exit code 1) |
| Built from | baseline `c1cfb16` working tree + Task 4 test/docs changes |
| Failure | `Execution failed for task ':app:processDebugGoogleServices'. File google-services.json is missing. The Google Services Plugin cannot function without it. Searched locations: /root/OvidAI/android/app/src/debug/google-services.json, /root/OvidAI/android/app/src/debug/google-services.json, /root/OvidAI/android/app/src/google-services.json, /root/OvidAI/android/app/src/debug/google-services.json, /root/OvidAI/android/app/src/Debug/google-services.json, /root/OvidAI/android/app/google-services.json` |

The build emitted the pre-existing minimum-SDK-23 deprecation warning before
failing on the missing `google-services.json`. That file is absent from the
checkout (`android/app/google-services.json` does not exist), is gitignored,
and is unrelated to this test/docs-only task, which touches no Android or
Dart production code. Per the brief it was NOT created or fabricated. This
is a buildability gap in this environment, not a gate pass: on-device
install/launch (§7 row 7) remains `NOT EXECUTED`.

Had the APK built, it would still be a workspace-bound, gitignored artifact
under `build/` (debug builds are not byte-reproducible across machines); the
SHA would pin that workspace artifact only.

## 9. Concerns and limitations

1. **No on-device verification.** Single-sheet install flows, durable status
   across a real restart, diagnostics rendering, and install/launch remain
   unverified until a release owner with a device completes §7 — compounded
   here by the missing debug APK (§8).
2. **Debug APK missing.** `google-services.json` is absent from the checkout,
   so `assembleDebug` cannot succeed in this environment. A release owner
   should either provide the file or document the expected debug-build path
   before claiming the APK gate.
3. **Analyzer warnings stand.** The two `unawaited_return_in_try_block`
   warnings pre-date this task and are untouched; a future cleanup can `await`
   or restructure those returns without changing this gate.
4. **Toggle-off mid-flight race (carried from Task 3, known, unhandled):** if
   the user taps Disconnect while a connect is in flight, the late `.then`
   completion records `failed` after the toggle-off `disabled` write (newer
   `updatedAt` wins). Final card can read Failed instead of Disabled. Left
   as-is per minimal scope; `serviceStatus` has the same pre-existing race.
5. **Scope call (carried from Task 3):** plugin runtime rows keep their
   `serviceStatus` fallback (only MCP UI was made durable-only). The brief's
   explicit UI list is McpCard/detail/diagnostics; plugin rows already render
   neutral no-record.
6. **No engine change.** Contraction is UI routes plus durable status display;
   marketplace catalog format, core multi-source transaction, and
   detail-screen diagnostics beyond the MCP row are out of scope (spec §3).

## 10. Gate decision

Automated gates are green where runnable: the new end-to-end suite (7/7), the
focused plugins-contraction set (30/30), the full Flutter suite (1017/1017),
`flutter analyze` (0 errors; 2 pre-existing warnings), and
`git diff --check` (clean). The debug APK gate **did not pass** — the build
fails on the missing `google-services.json` (§8) — and the on-device checklist
(§7) is `NOT EXECUTED` because no Android device/emulator is attached.
Automated sign-off is therefore green; on-device release sign-off **and** the
APK buildability item must remain open until a release owner with the missing
config and hardware completes them.
