# Native GitHub & Built-in MCP Runtime and DSH-Style Management Spec

**Date:** 2026-09-14  
**Author:** opencode  
**Status:** Approved for Implementation  

---

## 1. Executive Summary

Users on Android encounter failures when attempting to run built-in MCP servers (GitHub, Filesystem, Fetch, Memory) because they currently rely on spawning external `npx` / `uvx` processes inside a PRoot Linux sandbox. On mobile devices, `npx` / `uvx` package downloads frequently time out, fail due to Node.js/V8 resource limits, or stall because environment variables (like `GITHUB_TOKEN`) are not automatically linked with Ovid's existing GitHub login. Furthermore, managing plugins and MCP servers lacks the fluid, modern UX of DSH web, which features direct inline enable/disable switches, immediate visual state feedback, and quick deletion with confirmation.

This specification defines:
1. **Pure-Dart In-Process Native MCP Architecture**: A native in-process transport (`transport: 'native'`) in `McpService`. Built-in MCP servers (`GitHub`, `Filesystem`, `Fetch`, `Memory`) execute directly in Dart inside the app process, requiring zero sandbox initialization, zero Node.js/Python installations, and zero `npx` downloads.
2. **Native GitHub MCP**: Exposes full GitHub tool capabilities (`search_repositories`, `get_file_contents`, `create_or_update_file`, `create_issue`, `list_issues`, `create_pull_request`, `add_issue_comment`, `fork_repository`, etc.) backed by GitHub REST API calls in Dart, automatically using `GitHubService.I.token` if the user is signed into GitHub in Ovid (or falling back to a configured `GITHUB_TOKEN`).
3. **Native Built-ins**:
   - `Filesystem`: Implements `read_file`, `write_file`, `list_directory`, `search_files`, `get_file_info` using Dart `dart:io` against the session workspace or user-shared directories.
   - `Fetch`: Implements `fetch` to retrieve web pages and convert HTML to markdown/text.
   - `Memory`: Implements graph-based long-term memory (`create_entities`, `create_relations`, `add_observations`, `read_graph`, `search_nodes`, `open_nodes`) backed by local JSON persistence.
4. **DSH Web-Style Plugin & MCP Management Flow**:
   - `PluginCard` and `McpCard` feature inline toggle switches for 1-tap Enable / Disable with instantaneous visual feedback (state dot green for ready/working, gray for disabled, red for error).
   - Quick Delete action (trash icon / 3-dot menu) with confirmation dialog on cards and detail screens.
   - Deleted built-in seeds are recorded in persistent preferences so they remain deleted across app restarts unless explicitly restored.

---

## 2. Architecture & Data Flow

```
+--------------------------------------------------------------------------+
|                              Chat & Agent Loop                           |
|                       mcp__<server>__<tool> dispatch                     |
+------------------------------------+-------------------------------------+
                                     |
                                     v
+------------------------------------+-------------------------------------+
|                               McpService                                 |
|                                                                          |
|   +-----------------------+ +------------------+ +-------------------+   |
|   |  stdio transport      | |  http transport  | | native transport  |   |
|   |  (SandboxService/Pty) | |  (package:http)  | | (In-process Dart) |   |
|   +-----------------------+ +------------------+ +---------+---------+   |
+-------------------------------------------------------------|------------+
                                                              |
                 +-------------------+------------------------+-------------------+
                 |                   |                        |                   |
                 v                   v                        v                   v
        +-----------------+ +------------------+    +-------------------+ +---------------+
        |  Native GitHub  | | Native Filesystem|    |   Native Fetch    | | Native Memory |
        |  MCP Handler    | | MCP Handler      |    |   MCP Handler     | | MCP Handler   |
        |                 | |                  |    |                   | |               |
        | - GitHubService | | - Session workdir|    | - HTTP client     | | - JSON graph  |
        |   OAuth token   | | - Dart File/Dir  |    | - HTML to Markdown| | - Local disk  |
        | - GitHub REST   | |                  |    |                   | |   persistence |
        +-----------------+ +------------------+    +-------------------+ +---------------+
```

### 2.1 McpService In-Process Native Transport

1. **Protocol Implementation**:
   - A `NativeMcpHandler` interface defines:
     ```dart
     abstract class NativeMcpHandler {
       Future<Map<String, dynamic>> initialize(Map<String, dynamic> params);
       Future<List<McpToolDef>> listTools();
       Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args);
       Future<void> dispose();
     }
     ```
   - `McpService` registers native handlers:
     - `'github'`: `NativeGitHubMcpHandler`
     - `'filesystem'`: `NativeFilesystemMcpHandler`
     - `'fetch'`: `NativeFetchMcpHandler`
     - `'memory'`: `NativeMemoryMcpHandler`
2. **Connecting**:
   - If `server.transport == 'native'` (or matches a registered native server name and is configured as native), `McpService` calls `_connectNative(server, rs)`:
     - Initializes handler with protocol handshake.
     - Fetches `tools/list` and populates `rs.tools`.
     - Marks `rs.handshakeDone = true`.
     - Returns `OutcomeKind.ready`.
   - Tool execution (`callTool`) routes directly to `handler.callTool(tool, args)` without inter-process communication serialization overhead.

### 2.2 Native GitHub MCP Handler

- **Authentication**:
  - Automatically queries `GitHubService.I.token`.
  - If null, queries `AppState.I.getMcpEnv(server.canonicalId)` for `GITHUB_TOKEN`.
  - If neither is present, reports `needsSetup` with message `"Please log in to GitHub or set GITHUB_TOKEN"`.
- **Tools**:
  - `search_repositories(query, per_page, page)`
  - `get_file_contents(owner, repo, path, ref)`
  - `create_or_update_file(owner, repo, path, content, message, branch, sha)`
  - `create_issue(owner, repo, title, body, labels, assignees)`
  - `list_issues(owner, repo, state, per_page, page)`
  - `get_issue(owner, repo, issue_number)`
  - `add_issue_comment(owner, repo, issue_number, body)`
  - `create_pull_request(owner, repo, title, head, base, body)`
  - `list_pull_requests(owner, repo, state, per_page, page)`
  - `fork_repository(owner, repo, organization)`
  - `list_commits(owner, repo, page, per_page)`
  - `get_user(username)`

### 2.3 Native Filesystem MCP Handler

- **Scope**:
  - Anchored to the active session workspace (`AgentService.I._sessionWorkDir()`) or allowed roots.
- **Tools**:
  - `read_file(path)`
  - `write_file(path, content)`
  - `list_directory(path)`
  - `get_file_info(path)`
  - `search_files(path, pattern)`
  - `delete_file(path)`

### 2.4 Native Fetch MCP Handler

- **Tools**:
  - `fetch(url, max_length, raw)`: Fetches target URL via HTTP with user-agent, converts HTML to clean markdown/text, and returns bounded content.

### 2.5 Native Memory MCP Handler

- **Tools**:
  - `create_entities(entities)`
  - `create_relations(relations)`
  - `add_observations(observations)`
  - `read_graph()`
  - `search_nodes(query)`
  - `open_nodes(names)`
- Persisted to `$appDocDir/mcp_memory.json`.

---

## 3. UI & Lifecycle (DSH Web Parity)

### 3.1 PluginCard & McpCard Inline Controls

- Each card displays:
  - Left: Service/Plugin icon with category tag.
  - Middle: Name, description/author, and real-time status pill (`Ready` green, `Connecting` yellow dot chase, `Disabled` gray, `Failed` red).
  - Right:
    - Inline Switch / Toggle:
      - 1-tap toggles between active and disabled.
      - Triggers `app.toggleMcpServer(server)` or `app.enablePlugin(plugin)` / `app.disablePlugin(plugin)`.
    - Delete button (trash icon):
      - Triggers confirmation dialog: `"Delete [Name]?"`.
      - On confirm, disconnects and removes the server/plugin.
      - For built-in seeds: saves the removed ID in `_kRemovedBuiltinSeeds` preference so it does not resurrect on restart.
- Clicking the body of the card navigates to the Detail Screen as before.

### 3.2 Detail Screens

- Update `PluginDetailScreen` and `McpDetailScreen`:
  - Consistent enable/disable switch in the header.
  - Trash/Delete action with confirmation.
  - Live tools list showing available tools when connected.

---

## 4. Verification Plan

1. **Unit & Widget Tests**:
   - `test/native_mcp_test.dart`: Test `NativeGitHubMcpHandler`, `NativeFilesystemMcpHandler`, `NativeFetchMcpHandler`, `NativeMemoryMcpHandler` RPCs, tool registration, and tool dispatch.
   - `test/mcp_service_native_test.dart`: Test `McpService.connect` with native transport, tool call routing, and disconnection.
   - `test/plugins_ui_dsh_flow_test.dart`: Test inline switch toggle and delete flow on `McpCard` and `PluginCard`.
2. **Build & Static Analysis**:
   - `flutter analyze`
   - `flutter test`
