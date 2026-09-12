# Plugins/MCP UI Contraction Design

**Date:** 2026-09-12
**Status:** Approved by product direction (GitHub-only install, single "+", durable status reasons).

## 1. Goal

Contract the Plugins/MCP settings UI to one install story: everything comes
from GitHub, there is exactly one "+" entry point, and every runtime row
reports its durable canonical startup status + reason — never an inferred
boolean.

## 2. User Outcomes

1. One obvious way to add: a single "+" opens one sheet (fetch a plugin
   from GitHub, or add a marketplace which is itself a GitHub repo).
2. No dead-end install routes: local folder, ZIP, npm, pasted MCP config,
   and hand-typed stdio/HTTP server forms go away from the UI.
3. Every plugin row and MCP server card shows *why* it is in its state
   (the persisted canonical status + short reason), including after
   restart — never a bare "Connected / Not connected".
4. A server that never ran reads "Not started", not "Not connected".

## 3. Non-Goals

- Removing multi-source support from the core install transaction
  (`PluginSource` types, `inspect` → approval → `installPlugin` stay;
  forward-compat and core tests keep working).
- Marketplace catalog format changes.
- Detail-screen diagnostics redesign (only the MCP status row changes
  its source).
- Legacy flag-flip plugin rows (no `runtimeId`): no canonical store
  covers them, so they keep availability + enabled display.

## 4. Current Failure Model (evidence)

- Four install entries (`plugins_screen.dart`): AppBar "Add marketplace"
  (`:934-939` → `_addMarketplaceDialog`), AppBar "Install plugin from
  source" (`:943-948` → `showPluginSourceChooser` with six routes:
  local folder, ZIP, GitHub, npm, pasted JSON/TOML, direct stdio/HTTP
  `:377-640`), detail-screen Install (derived GitHub or chooser
  `:1716-1724`), MCP `+1 add-tile` (`:2284` → `_addMcpDialog` manual
  name/cmd/args/env/URL `:2303` + `_importMcpConfig` paste dialog
  `:2499`).
- MCP status is a 3-tier fallback with a boolean bottom
  (`McpCard` icon `:2677-2716`, label `:2730-2798`, border `:2639-2656`;
  diagnostics row `:1962-1966` renders binary
  `'${s.connected ? 'Connected' : 'Not connected'}'`).
- Live MCP toggles write only `serviceStatus` + `server.connected`
  (`state.dart:5181-5200` `toggleMcpServer`, `:2079-2117`
  `_connectMcpForStartup`); the durable store (`runtimeStatusStore`)
  is fed by the startup sink (`_onStartupStatus`, `:1423`) and
  `recordTruthfulPluginStatus` (`:1374`) only — so a durable-first
  card would go stale the moment the user taps Connect.

## 5. Architecture

### 5.1 GitHub-only install UI

- `showPluginSourceChooser` contracts to the GitHub route only: repo
  field (`owner/repo` or URL via `_githubSourceFromInput`) → the
  unchanged single inspection/approval flow (`startPluginInstallForTest`
  → `installPlugin`). Local/ZIP tiles, npm, paste-config, and
  direct-MCP sections are deleted, with the two file-picker test seams
  (`pluginPickDirectoryForTest`, `pluginPickZipFileForTest`).
- The `file_picker` dependency stays (chat/settings/studio/agent use
  it); only the plugin-source call sites go.
- Core `addCustomMcpServer` stays (marketplace import, manifest-driven
  installs, agent install path, existing tests). Existing custom
  servers remain manageable (connect/disconnect, edit config, remove).

### 5.2 Single "+"

- One AppBar `Icons.add` action opens one sheet (`showPluginAddSheet`):
  "Fetch plugin from GitHub" + "Add marketplace" (repo field +
  existing marketplace list with remove) + the refresh affordance stays
  a separate AppBar action.
- Deleted entries: standalone marketplace IconButton/dialog route,
  extension IconButton, `_AddMcpTile`, `_addMcpDialog`,
  `_importMcpConfig`. Detail-screen Install falls back to the single
  sheet instead of the chooser. An empty MCP list shows a hint
  ("Use + to add from GitHub").

### 5.3 Durable status reasons

- Every MCP outcome path records the durable store under the server's
  canonical id: connect success → `ready` ("connected"),
  failure → `failed` (redacted reason), pre-spawn credential block →
  `needsSetup` (missing names), user disconnect → `disabled`
  ("disconnected — tap Connect to start"). Applies to `toggleMcpServer`
  and `_connectMcpForStartup` (and any sibling that writes
  `serviceStatus['mcp:…']`).
- UI reads durable only: `McpCard` icon/label/border,
  `McpDetailScreen` header status, diagnostics MCP row (durable
  `label · reason`, replacing the binary row).
- Runtime rows (plugin `runtimeId`, any MCP server) with no record show
  neutral: faint `help_outline` + "Not started" + neutral border —
  never `serviceStatus`, never `connected`/`installed`/`enabled`
  inference.
- The Connect/Disconnect button stays a live action toggle; the
  `Unsupported on this device` and `Needs setup` banners stay as
  computed structural guards.

## 6. Error Handling

- Unknown/missing persisted status → "Not started" neutral (never a
  crash, never a green check).
- Recording a durable MCP outcome never throws into the toggle path;
  failures keep the existing `serviceStatus` + snackbar behavior.
- Removing a marketplace that owns installed rows keeps current
  behavior (rows stay, diagnostics explain).

## 7. Testing

- Unit/widget-source: chooser has only the GitHub route (source
  asserts no local/ZIP/npm/paste/direct-MCP widgets or seams);
  single "+" sheet routes both GitHub fetch and marketplace add;
  no `_AddMcpTile` / `_addMcpDialog` / `_importMcpConfig` entry;
  MCP toggle/connect records durable `ready`/`failed` with reason;
  no-record runtime rows render neutral "Not started"; diagnostics
  row renders durable label, never binary.
- Regression: existing tests pinning removed UI updated deliberately
  (chooser tiles, add dialogs, import, Task-11 seam tests retargeted
  to GitHub source or removed with the route).

## 8. Decisions

- Install UI is GitHub-only; core keeps all source types.
- Exactly one "+" opens exactly one sheet.
- Durable canonical status + reason is the only status display for
  runtime rows; absence of a record is "Not started".
