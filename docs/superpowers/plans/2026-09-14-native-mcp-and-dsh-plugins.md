# Native Built-in MCPs & DSH-Style Plugins Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement pure-Dart in-process native MCP engines for GitHub, Filesystem, Fetch, and Memory, and upgrade PluginCard/McpCard with DSH web-style inline enable/disable switches and quick delete actions.

**Architecture:** Add `NativeMcpHandler` abstraction and in-process native transport in `McpService`. Built-in MCPs (`github`, `filesystem`, `fetch`, `memory`) execute in Dart without sandbox/proot/Node.js dependencies. GitHub MCP auto-uses `GitHubService.I.token` or custom token. Plugins and MCP cards receive inline switches and delete confirmation dialogs with persistent seed removal tracking.

**Tech Stack:** Dart, Flutter, `http`, `crypto`, `shared_preferences`.

**Spec:** `docs/superpowers/specs/2026-09-14-native-mcp-and-dsh-plugins-design.md`

## Global Constraints
- Zero reliance on `npx` / `uvx` / Node.js / Python for built-in MCP tools.
- GitHub MCP must automatically use `GitHubService.I.token` when user is logged in.
- Tool naming strictly adheres to `mcp__<server>__<tool>` MCP client standard.
- Removed built-in seeds must persist across app restarts.
- All tests must pass cleanly with `flutter test`.

---

### Task 1: Native MCP Handler Base & Handlers (GitHub, Filesystem, Fetch, Memory)

**Files:**
- Create: `lib/core/native_mcp.dart`
- Create: `test/native_mcp_test.dart`

**Interfaces:**
- Produces:
  ```dart
  abstract class NativeMcpHandler {
    Future<Map<String, dynamic>> initialize(Map<String, dynamic> params);
    Future<List<McpToolDef>> listTools();
    Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args);
    Future<void> dispose();
  }
  class NativeGitHubMcpHandler implements NativeMcpHandler { ... }
  class NativeFilesystemMcpHandler implements NativeMcpHandler { ... }
  class NativeFetchMcpHandler implements NativeMcpHandler { ... }
  class NativeMemoryMcpHandler implements NativeMcpHandler { ... }
  ```

- [ ] **Step 1: Write tests for NativeMcpHandler and implementations**
Test tool listing and tool execution for `NativeGitHubMcpHandler`, `NativeFilesystemMcpHandler`, `NativeFetchMcpHandler`, and `NativeMemoryMcpHandler`.

- [ ] **Step 2: Run test to verify it fails**
Run: `/root/flutter/bin/flutter test test/native_mcp_test.dart`
Expected: FAIL (file not found)

- [ ] **Step 3: Implement `lib/core/native_mcp.dart`**
Implement the native handler classes with pure Dart logic (GitHub REST API, File/Directory operations, Web Fetch markdown conversion, and Memory JSON graph).

- [ ] **Step 4: Run test to verify it passes**
Run: `/root/flutter/bin/flutter test test/native_mcp_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add lib/core/native_mcp.dart test/native_mcp_test.dart
git commit -m "feat(mcp): implement pure-dart native handlers for github, filesystem, fetch, and memory"
```

---

### Task 2: Integrate Native Transport into McpService & AppState

**Files:**
- Modify: `lib/core/mcp_service.dart`
- Modify: `lib/core/state.dart`
- Test: `test/mcp_service_native_test.dart`

**Interfaces:**
- Consumes: `NativeMcpHandler`, `NativeGitHubMcpHandler`, etc. from `lib/core/native_mcp.dart`.
- Produces: `McpService.connect` supporting `transport == 'native'`, registering built-in native handlers, auto-injecting `GitHubService.I.token`.

- [ ] **Step 1: Write tests for native McpService connect and tool execution**
Test connecting to a native MCP server (`transport: 'native'`), discovering tools, calling a tool, and disconnecting.

- [ ] **Step 2: Run test to verify it fails**
Run: `/root/flutter/bin/flutter test test/mcp_service_native_test.dart`
Expected: FAIL

- [ ] **Step 3: Update `McpService` and `AppState`**
- In `lib/core/mcp_service.dart`: add native transport handling in `connectOutcome` and `_connectNative`, dispatching `callTool` to native handlers.
- In `lib/core/state.dart`: update built-in seed MCPs (`GitHub`, `Filesystem`, `Fetch`, `Memory`) to `transport: 'native'`. Add `_kRemovedBuiltinSeeds` to persist removed built-in seeds.

- [ ] **Step 4: Run test to verify it passes**
Run: `/root/flutter/bin/flutter test test/mcp_service_native_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add lib/core/mcp_service.dart lib/core/state.dart test/mcp_service_native_test.dart
git commit -m "feat(mcp): integrate in-process native transport into McpService and AppState seeds"
```

---

### Task 3: DSH Web-Style Inline Switch & Quick Delete on PluginCard & McpCard

**Files:**
- Modify: `lib/ui/plugins_screen.dart`
- Modify: `lib/core/state.dart`
- Test: `test/plugins_ui_dsh_flow_test.dart`

**Interfaces:**
- Produces:
  - Inline switch on `PluginCard` and `McpCard` for 1-tap enable/disable.
  - Delete button on `McpCard` and `PluginCard` triggering confirmation dialog.
  - Deletion of built-in seeds tracked persistently.

- [x] **Step 1: Write widget test for inline toggle and delete flow**
Verify tapping switch enables/disables the plugin/MCP, and tapping delete displays dialog and removes the item.

- [x] **Step 2: Run test to verify it fails**
Run: `/root/flutter/bin/flutter test test/plugins_ui_dsh_flow_test.dart`
Expected: FAIL

- [x] **Step 3: Update `lib/ui/plugins_screen.dart`**
Add the inline switch widget and quick delete action with confirmation dialog to `PluginCard`, `McpCard`, and their detail screens.

- [x] **Step 4: Run test to verify it passes**
Run: `/root/flutter/bin/flutter test test/plugins_ui_dsh_flow_test.dart`
Expected: PASS

- [x] **Step 5: Commit**
```bash
git add lib/ui/plugins_screen.dart lib/core/state.dart test/plugins_ui_dsh_flow_test.dart
git commit -m "feat(ui): add dsh web-style inline toggle and quick delete on plugin and mcp cards"
```

---

### Task 4: Full Verification & CI Build

**Files:**
- All modified files

- [x] **Step 1: Run flutter analyze and tests**
Run: `/root/flutter/bin/dart analyze` and `/root/flutter/bin/flutter test`
Expected: 0 errors, all tests pass.

- [ ] **Step 2: Push and verify GitHub Actions CI**
Push branch and monitor GitHub Actions APK/AAB build.
