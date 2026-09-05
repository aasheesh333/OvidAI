# Ovid Plugin/MCP/Desktop/Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Ovid marketplace/plugin/MCP installs actually work like Claude Code/Codex, remove fake counts, deliver real desktop viewport, and keep agent alive after recents swipe until explicit Stop/Exit.

**Architecture:** Fix Dart persistence/runtime gates first (state/agent/mcp/hook/skills), then add narrow Android WebView viewport channel + foreground-service lifecycle split, with TDD RED→GREEN and full regression gates.

**Tech Stack:** Flutter 3.44.9 / Dart, webview_flutter ^4.8.0, Android ForegroundService + MethodChannel ovid/native + ovid/webview, SharedPreferences + flutter_secure_storage, HttpClient MCP Streamable HTTP + stdio JSON-RPC.

**Spec:** Chat-approved A+B+C phased design 2026-09-05 (plugin audit ses_f8d8b6d18ffesGWeUEjp3XBySD, MCP audit ses_f8d8b6adaffeTY0rd04WjMoFGQ, desktop/background audit ses_f8d8b6c60ffeF450C8vgBPaUG9) + Claude plugins reference https://code.claude.com/docs/en/plugins-reference + Codex plugins https://developers.openai.com/codex/plugins

## Global Constraints

- Preserve Read-Only + plan-mode + General/Full/Studio gates; never weaken `_maybeApprove`.
- Hooks fail-open on missing sandbox/error/timeout; exit-2 deny preserved.
- Never store tokens/headers in SharedPreferences plaintext; use secure storage.
- No fake telemetry: zero/hide unknown installs, honest permissions/changelog copy.
- No immortality claims: document OEM/Doze/Android 12+ FGS limits.
- TDD RED→GREEN per task; `flutter analyze` clean; full `flutter test` green; Android `build.yml` green.
- Flutter binary: `/home/ubuntu/sdk/flutter/bin/flutter` (not on PATH).
- Branch `hoplite/gortyn-77773150`, BASE `ec2efb48f5579d353e22f08f85eb0d0a5eb0b29d`.

---

## File Map

- `lib/core/state.dart`: marketplace persist/sync/source, plugin MCP mount, fake counts, McpServer model/cwd/type.
- `lib/ui/plugins_screen.dart`: install/enable/disable/uninstall, MCP import parser, honest copy.
- `lib/core/agent_service.dart`: generic plugin tools, pre-tool args, mcp dispatch fix, desktop controller/channel, run checkpoint.
- `lib/core/skills.dart`: agents/commands manifest parsing.
- `lib/core/hook_service.dart`: matcher + JSON decision + payload.
- `lib/core/mcp_service.dart`: stdio framing/ids/timeouts, HTTP client/session/SSE, reconnect identity, disconnect.
- `lib/ui/chat_screen.dart`: slash-menu grouping + MCP stubs.
- `lib/ui/settings_screen.dart`: honest desktop copy.
- `lib/ui/browser_screen.dart`: controller recreate on toggle.
- `android/.../MainActivity.kt`, `AgentForegroundService.kt`, `AgentStopReceiver.kt`, `AndroidManifest.xml`, `build.gradle.kts`: recents survival, STOP vs EXIT.
- `lib/core/agent_notification_service.dart`, `lib/main.dart`: idle/start/background-denial/battery.
- `test/core_regression_test.dart`: all new RED→GREEN tests.

---

### Task 1: Marketplace persistence + honest catalog

**Files:**
- Modify: `lib/core/state.dart:633-644,1775-1784,2123-2225,2488-2527`
- Modify: `lib/ui/plugins_screen.dart:48-60,94-99,559-563,727-742`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: existing `_loadPluginState`, `syncMarketplaceCatalogs`, `_mergeMarketplaceCatalog`, `_persistPluginState`.
- Produces: `persistMergedMarketplaceCatalog()` + startup auto-sync + `source` restore; uninstall/disable cleanup contract for Task 2.

- [x] **Step 1: Write failing restart round-trip test**

```dart
test('marketplace install survives restart resync', () async {
  final a = await freshAppStateForTest();
  await a.syncMarketplaceCatalogs();
  await a.setPluginInstalled('real-plugin', true);
  final b = await freshAppStateForTest();
  await b.syncMarketplaceCatalogs();
  expect(b.isPluginInstalled('real-plugin'), isTrue);
  expect(b.pluginSource('real-plugin'), isNotNull);
});
```

- [x] **Step 2: Run to verify fail**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "marketplace install survives restart resync"`
Expected: FAIL (imported row gone after reseed).

- [x] **Step 3: Implement persist + auto-sync + source restore**

```dart
Future<void> persistMergedMarketplaceCatalog() async {
  final rows = plugins.where((p) => p.source != null).toList();
  await prefs.setString('ovid_marketplace_merged_v1', jsonEncode(rows.map((e) => e.toJson()).toList()));
}
Future<void> _initialize() async {
  await _loadCustomPlugins();
  await _loadPluginState();
  await _loadMarketplaces();
  await restoreMergedMarketplaceCatalog();
  await syncMarketplaceCatalogs();
  await _applyPluginState();
}
```

Persist `source`; restore by name after sync; `removeMarketplace` prunes merged rows; uninstall deletes cache + unmounts `source:plugin:<name>` MCP + `refreshSkills`; disable calls `refreshSkills` + disconnects owned MCP.

- [x] **Step 4: Zero fake installs + honest copy**

```dart
// seeds: installs: 0, installsKnown: false; UI hides count when !installsKnown
// plugins_screen permissions/changelog: show 'Declared by plugin manifest' or hide when unknown
```

- [x] **Step 5: Run tests**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: PASS; `/home/ubuntu/sdk/flutter/bin/flutter analyze` clean.

- [x] **Step 6: Commit**

```bash
git add lib/core/state.dart lib/ui/plugins_screen.dart test/core_regression_test.dart docs/superpowers/plans/2026-09-05-ovid-plugin-mcp-desktop-persistence.md
git commit -m "fix: marketplace persist + honest installs"
```

---

### Task 2: Plugin runtime capability + manifest parity

**Files:**
- Modify: `lib/core/state.dart:1921-2019,2025-2070,2113-2120`
- Modify: `lib/core/agent_service.dart:2134-2222,6526,6552-6555,9354-9359`
- Modify: `lib/core/skills.dart:80-153`
- Modify: `lib/ui/plugins_screen.dart:13-25`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: Task 1 persisted `source` + fetched content cache.
- Produces: generic plugin tool contribution + skill/agent roots for Task 3 hooks/MCP.

- [x] **Step 1: Write failing non-seed tool test**

```dart
test('imported enabled plugin contributes tools', () async {
  await installMarketplacePluginForTest('real-plugin');
  final tools = await agentToolsForTest();
  expect(tools.any((t) => t.name.contains('real-plugin')), isTrue);
});
```

- [x] **Step 2: Run to verify fail**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "imported enabled plugin contributes tools"`
Expected: FAIL (`contributes no agent tools`).

- [x] **Step 3: Generic capability + subdir fetch + manifest**

```dart
List<AgentTool> _pluginToolNames() {
  final out = <AgentTool>[];
  for (final p in AppState.I.plugins) {
    if (!p.installed || !p.enabled) continue;
    if (seedToolNames.contains(p.name)) { out.add(seedTool(p.name)); continue; }
    if (hasMountedSkillsOrCommands(p.name)) out.add(AgentTool('plugin_${norm(p.name)}', 'Use ${p.name}'));
  }
  return out;
}
Future<String?> _githubPluginSource(PluginItem p) async {
  if (p.source == null) return null;
  if (p.source!.startsWith('./') || p.source!.startsWith('/')) {
    return '${p.marketplaceRepo}/raw/branch/${p.source}';
  }
  return p.source;
}
```

Fetch allowlist adds `agents/*.md`, `hooks/hooks.json`, `.claude-plugin/plugin.json`, command frontmatter `allowed-tools,argument-hint,model`; `skills.dart` scans `agents/` personas + parses new frontmatter; `mountPluginMcpServers` preserves `transport/url/headers/env` (env→secure).

- [x] **Step 4: Run tests**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: PASS; analyze clean.

- [x] **Step 5: Commit**

```bash
git add lib/core/state.dart lib/core/agent_service.dart lib/core/skills.dart lib/ui/plugins_screen.dart test/core_regression_test.dart
git commit -m "feat: generic plugin runtime + manifest parity"
```

---

### Task 3: Hook args + matchers + JSON decision

**Files:**
- Modify: `lib/core/agent_service.dart:5897-5922`
- Modify: `lib/core/hook_service.dart:75-90,103-108,128-130,177-191,204-306`
- Modify: `lib/core/state.dart:176-183,2085-2104`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: Task 2 fetched `hooks/hooks.json`.
- Produces: hook gate contract used by all tool calls.

- [ ] **Step 1: Write failing args/matcher test**

```dart
test('pre-tool hook receives args and matcher blocks', () async {
  installHookForTest('on_pre_tool', matcher: 'run_shell', script: 'exit 2');
  final r = await fireGateForTest('on_pre_tool', {'tool': 'run_shell', 'args': {'command': 'rm -rf /'}});
  expect(r.allowed, isFalse);
});
```

- [ ] **Step 2: Run to verify fail**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "pre-tool hook receives args and matcher blocks"`
Expected: FAIL (payload tool-only, no matcher).

- [ ] **Step 3: Implement payload + matcher + JSON decision**

```dart
await HookService.I.fireGate('on_pre_tool', {'tool': name, 'args': args});
// hook_service: matcher RegExp on tool name; stdout JSON {"decision":"block","reason":"..."} also denies; keep exit-2 deny + fail-open
```

Fetch `hooks/hooks.json`; support map+list forms; cap stdout 2KB/env 4KB; ledger invoke/result.

- [ ] **Step 4: Run tests**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: PASS; analyze clean.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart lib/core/hook_service.dart lib/core/state.dart test/core_regression_test.dart
git commit -m "feat: hook args + matchers + decision"
```

---

### Task 4: MCP import + runtime reliability

**Files:**
- Modify: `lib/ui/plugins_screen.dart:1004-1213,1380-1755`
- Modify: `lib/core/state.dart:188-229,2164-2401,2583-2601,2268-2284`
- Modify: `lib/core/mcp_service.dart:108-194,287-352,427-434,481-526,535-696`
- Modify: `lib/core/agent_service.dart:2193-2201,6433-6478,6562-6697`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: Task 2 mounted plugin MCP.
- Produces: stable connect/call/disconnect contract for agent + UI.

- [ ] **Step 1: Write failing parser + proxy + remove tests**

```dart
test('mcp toml single-quote multiline env parses', () {
  final res = parseMcpConfigForTest("[mcp_servers.foo]\ncommand='npx'\nargs=[\n\"a\"\n]\n[\"mcp_servers.foo.env\"]\nK=\"v\"");
  expect(res.single.name, 'foo');
});
test('legacy mcp proxy calls matched server', () async {
  expect(await legacyMcpProxyForTest('mcp_gh_list'), contains('gh'));
});
test('remove mcp disconnects and prunes intent', () async {
  await removeMcpForTest('gh');
  expect(isDisconnectedForTest('gh'), isTrue);
});
```

- [ ] **Step 2: Run to verify fail**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "mcp toml single-quote multiline env parses"`
Expected: FAIL.

- [ ] **Step 3: Implement parser + model + runtime fixes**

```dart
// parser: accept mcpServers|mcp_servers|servers, top array; single+double quotes; multiline args; [*.env] + headers.*; cwd/type; surface ignoredKeys
// McpServer: add cwd, type, startupTimeoutS; updateCustomMcpServer round-trips url/transport/headers/cwd/env; shell-split args preserving quotes
// remove: disconnect()+cancelReconnect()+secureDelete+intent prune; reconnect lookup by name
// stdio: startup vs call timeouts; tolerate string ids; try stdin.writeln → MCP error; reject pretty-printed JSON with clear error
// http: close clients; handle Mcp-Session-Id; event:/multi-line data; clear 'SSE not supported, use Streamable HTTP'; 401 auth-error re-prompt
// agent: fix mcp_* to callTool(match.name); catalog list shows transport/url; catalog add supports url/headers/env; inject disconnected stubs
```

- [ ] **Step 4: Run tests**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: PASS; analyze clean.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/plugins_screen.dart lib/core/state.dart lib/core/mcp_service.dart lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "fix: mcp import + runtime reliability"
```

---

### Task 5: Real desktop viewport

**Files:**
- Modify: `lib/core/agent_service.dart:29-63,1272-1305,1313-1463,6772-6806`
- Modify: `lib/ui/browser_screen.dart:38-49,102,343-350`
- Modify: `lib/ui/settings_screen.dart:228-237`
- Create: `android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt`
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: existing `BrowserTab.desktopMode`, `setTabDesktopMode`, `controllerForTab`.
- Produces: real layout viewport for desktop tabs.

- [ ] **Step 1: Write failing ordering/recreate test**

```dart
test('desktop sets UA before first load and recreates on toggle', () {
  final src = readAgentServiceSourceForTest();
  expect(src.indexOf('setUserAgent(desktopUA)') < src.indexOf('loadRequest'), isTrue);
  expect(src.contains('recreateControllerForDesktopToggle'), isTrue);
});
```

- [ ] **Step 2: Run to verify fail**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "desktop sets UA before first load and recreates on toggle"`
Expected: FAIL (no recreate path).

- [ ] **Step 3: Implement channel + recreate**

```dart
// Dart: before first load if desktop → await OvidWebView.applyDesktopViewport(true) then setUserAgent(desktopUA) then loadRequest
// toggle → update tab.desktopMode → dispose controller → controllerForTab() fresh → reload URL
// drop wasted pre-reload _applyTabZoom; keep post-page-finished re-apply only for zoom fallback
// Kotlin OvidWebViewHandler: WebSettings.useWideViewPort=true, loadWithOverviewMode=true, supportMultipleWindows=true, initialScale fit 1280
// honest copy: 'Desktop layout viewport (media queries use 1280px); fallback scale-only if channel unavailable'
```

- [ ] **Step 4: Run tests**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: PASS; analyze clean.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart lib/ui/browser_screen.dart lib/ui/settings_screen.dart android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt test/core_regression_test.dart
git commit -m "feat: real desktop viewport"
```

---

### Task 6: Recents survival until Stop/Exit

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/AgentForegroundService.kt:33-148`
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/AgentStopReceiver.kt:13-24`
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt:48-218`
- Modify: `lib/core/agent_notification_service.dart:33-127`
- Modify: `lib/core/agent_service.dart:761-779,4682,2100-2103,5334`
- Modify: `lib/main.dart:156-184`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: existing `anyRunActive`, `cancelAllRuns`, `agentWorking/agentIdle`.
- Produces: STOP vs EXIT semantics + recents survival + restart checkpoint.

- [ ] **Step 1: Write failing lifecycle tests**

```dart
test('idle only stops service when no runs active', () async {
  setAnyRunActiveForTest(true);
  await agentIdleForTest();
  expect(serviceStopRequestedForTest(), isFalse);
});
test('stop vs exit split', () {
  final src = readForegroundServiceSourceForTest();
  expect(src.contains('ACTION_STOP'), isTrue);
  expect(src.contains('ACTION_EXIT'), isTrue);
  expect(src.contains('finishAndRemoveTask'), isTrue);
});
```

- [ ] **Step 2: Run to verify fail**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "idle only stops service when no runs active"`
Expected: FAIL.

- [ ] **Step 3: Implement native + Dart split**

```kotlin
// Manifest: service android:stopWithTask="false"
// onTaskRemoved: if runs active → re-assert startForeground, do NOT stopSelf
// ACTION_STOP: cancel run, keep service if other runs active
// ACTION_EXIT: cancel + stopSelf + finishAndRemoveTask
// Receiver: startForegroundService on O+, handle BackgroundStartDenied
```

```dart
// agentIdle only invokes agentServiceStop when !anyRunActive
// background agentWorking handles ForegroundServiceStartNotAllowed without disabling mid-run
// checkpoint run state to disk; START_STICKY restore path; battery exemption prompt flow
```

- [ ] **Step 4: Run tests**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: PASS; analyze clean.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin/com/dhanuk/ovidai/AgentForegroundService.kt android/app/src/main/kotlin/com/dhanuk/ovidai/AgentStopReceiver.kt android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt lib/core/agent_notification_service.dart lib/core/agent_service.dart lib/main.dart test/core_regression_test.dart
git commit -m "feat: recents survival + stop vs exit"
```

---

### Task 7: Production verification gate

**Files:**
- Verify only; fix forward in owning task on failure.

- [ ] **Step 1: Analyze**

Run: `/home/ubuntu/sdk/flutter/bin/flutter analyze`
Expected: clean.

- [ ] **Step 2: Full regression**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test`
Expected: all pass (baseline 328 + new).

- [ ] **Step 3: Android build**

Run: `gh run list --branch hoplite/gortyn-77773150 --limit 1`
Expected: success with debug APK + release APK/AAB.

- [ ] **Step 4: Commit gate marker only if needed**

```bash
git status --short
```

## Self-Review

- Spec coverage: marketplace persist (T1), generic runtime + manifest (T2), hooks (T3), MCP (T4), desktop (T5), background (T6), gates (T7). No gaps.
- Placeholder scan: no TBD/TODO; every step has concrete code + command + expected.
- Type consistency: `PluginItem.source/marketplaceRepo`, `McpServer.cwd/type`, `AgentTool`, `anyRunActive`, `ACTION_STOP/EXIT` used consistently.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-05-ovid-plugin-mcp-desktop-persistence.md`. Execution: Subagent-Driven (user pre-approved A+B+C + parallel crews).
