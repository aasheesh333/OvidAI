# 03 — Plugins & MCP UI

## Scope
- `lib/ui/plugins_screen.dart` (4035 lines): PluginsScreen, add-plugin sheet, PluginDetailScreen, McpDetailScreen, MCP credentials / runtime-install / JSON-editor sheets
- `lib/ui/plugin_settings_panel.dart`, `lib/ui/plugin_install_progress.dart`, `lib/ui/plugin_permission_sheet.dart`, `lib/ui/mcp_oauth_sheet.dart`
- Calls followed into `lib/core/` (mcp_service.dart, plugin_*.dart, hook_service.dart) where needed to confirm a bug.

## Goal
Product requirement: every Claude Code MCP server and plugin must work as in Claude Code (except OS-limited), and MCP/plugin usage must be tracked and visible. Check the UI against that: install flows (GitHub repo / marketplace), enable/disable, errors, status (connected/degraded/failed), OAuth, env/headers editing, per-tool listing, usage stats. Plus the general review goals in README.md (bugs, states, UX, a11y, perf, security).

Known context (not re-derived here): PostToolUse hooks are fire-and-forget; MCP server→client requests (ping/roots/sampling/elicitation) unanswered; OAuth lacks discovery/DCR and uses paste-back redirect; no per-MCP/plugin usage aggregation; grants stored in SharedPreferences.

## Status
in progress

