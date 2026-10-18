# Task 17 — MCP/plugin runtime + UI removal wave

Status: DONE — commit **c344db0** (2026-10-18)

## Scope decisions

- **Deleted the whole local MCP/plugin runtime** plus the native-plugin
  capability runtime and the six remaining plugin/MCP UI sheets. The plugin
  catalog screen had already been deleted in T13.
- **Deferred five shared model files to T18**: `mcp_config_parse.dart`,
  `plugin_manifest.dart`, `plugin_registry.dart`, `plugin_permissions.dart`,
  `plugin_adapters.dart`. Their last lib consumers are the T18-owned
  `hook_service.dart` and `skills.dart` (plugin hook engine + plugin catalog
  mounts). Deleting them in T17 would make those files uncompilable, which
  violates the analyze-green-per-task constraint. Only comment references to
  the deleted runtime were edited so the acceptance grep is empty.
- `hook_service.dart` was kept (T18 owns it) but its **legacy `PluginItem`
  map-hook support** and **plugin userConfig substitution** were removed —
  both depended on state fields / `plugin_user_config` deleted in this wave.
- `session_lifecycle_service.dart` was kept; the dead local plugin activation
  barrier now completes immediately at boot.
- **T12 keep-alive residue removed** (coordinator addendum):
  `BackgroundNotifier.syncKeepActive()` + call site,
  `Distribution.idleKeepAliveAvailable`, and
  `AppState.keepAliveEnabled` + setter + `ovid_keep_alive` pref.

## Deleted files (104)

### Core (25)
- `lib/core/mcp_service.dart`
- `lib/core/native_mcp.dart`
- `lib/core/mcp_catalog_tools.dart`
- `lib/core/mcp_client_requests.dart`
- `lib/core/mcp_oauth_discovery.dart`
- `lib/core/plugin_runtime.dart`
- `lib/core/plugin_dependency_service.dart`
- `lib/core/plugin_source_resolver.dart`
- `lib/core/plugin_user_config.dart`
- `lib/core/native_plugin.dart`
- `lib/core/native_plugins/`: `data_utilities.dart`, `dev_utilities.dart`,
  `prompt_dev.dart`, `prompt_framework.dart`, `prompt_knowledge.dart`,
  `rest_descriptors_aimedia.dart`, `rest_descriptors_backend.dart`,
  `rest_descriptors_comms.dart`, `rest_descriptors_dev.dart`,
  `rest_descriptors_infra.dart`, `rest_engine.dart`,
  `utility_cancellation_bridge.dart`, `utility_limits.dart`, `utility_sql.dart`,
  `web_and_db_utilities.dart`

### UI (6)
- `lib/ui/plugin_permission_sheet.dart`
- `lib/ui/mcp_oauth_sheet.dart`
- `lib/ui/mcp_server_add_form.dart`
- `lib/ui/plugin_install_progress.dart`
- `lib/ui/plugin_settings_panel.dart`
- `lib/ui/mcp_elicitation_sheet.dart`

### Tests (73)
All deleted tests referenced a removed module/symbol. Module-owned:
`agent_prompt_transport_contract`, `custom_plugins_work`,
`data_utilities_cancel`, `dev_utilities_cancel`, `marketplace_import`,
`mcp_documented_config_execution`, `mcp_dynamic_timeout`,
`mcp_eval_cancellation`, `mcp_http_completeness`, `mcp_http_origin`,
`mcp_late_status_fencing`, `mcp_memory_isolation`, `mcp_oauth_discovery`,
`mcp_runtime_gate`, `mcp_service_native`, `mcp_sse_origin`, `mcp_stdio_e2e`,
`mcp_token_roundtrip`, `native_mcp_security`, `native_mcp`,
`native_plugin_agent`, `native_plugin_framework`, `native_plugins_data`,
`native_plugins_dev`, `native_plugins_prompt`, `native_plugins_rest`,
`native_plugins_web_db`, `parallel_mcp_lifecycle`,
`parallel_mcp_notifications`, `parallel_mcp_protocol`, `parallel_mcp_round1`,
`parallel_mcp_sockets`, `parallel_utilities_csv`, `parallel_utilities_regex`,
`plugin_action_dispatch`, `plugin_direct_repo_install`, `plugin_e2e_install`,
`plugin_install_approval`, `plugin_install_progress`,
`plugin_install_session_bootstrap`, `plugin_mcp_parity`,
`plugin_native_dependency`, `plugin_rich_ui_and_screen`,
`plugin_runtime_skills`, `prompt_framework_cancel`, `rest_aimedia`,
`rest_backend`, `rest_cancellation`, `rest_comms`, `rest_coverage`,
`rest_descriptors_aimedia_cancel`, `rest_descriptors_backend_cancel`,
`rest_descriptors_dev_cancel`, `rest_descriptors_infra_cancel`, `rest_dev`,
`rest_infra`, `security_plugin_grant_storage`,
`security_secure_settings_migration`, `session_plugin_lifecycle`,
`settings_mcp_and_legacy_hooks`, `structured_edits_and_mcp_streaming`,
`ui_redesign/plugin_sheets`, `wave2_mcp_catalog_tools`,
`wave2_mcp_integration`, `wave2_mcp_oauth`, `wave2_mcp_oauth_ui`,
`wave2_mcp_protocol`, `wave2_utilities_cancel`, `wave2_utilities_dst`,
`wave2_utilities_final`, `wave2_utilities_semantics`,
`wave2_utility_cancellation_bridge`, `web_db_utilities_cancel`.

## Kept-with-edits (test-deletion triage)

These files mostly cover SURVIVING behaviour; only the removed-symbol groups
were deleted.

- `test/chat_screen_distribution_gates_test.dart` — removed the MCP/plugin
  seeders and the two "offered on-device" tests; kept the Skills source,
  browser-header, thin-client, and router tests.
- `test/claude_code_hooks_mcp_parity_test.dart` — removed the
  "MCP client capabilities" group and the elicitation-sheet widget test; kept
  tool aliasing, subagent policy, hooks, and usage-attribution groups.
- `test/claude_code_subagent_parity_test.dart` — removed the "MCP inside a
  subagent" group; kept scoping, no-nesting, hook, and skills groups.
- `test/claude_plugin_compat_test.dart` — removed the install-time
  `ensureHookScriptsExecutable` group; kept hook compatibility groups.
- `test/p2_subagent_races_test.dart` — removed the inherited-plugin-MCP race
  test; kept all other admission/race tests.
- `test/wave2_hooks_agent_test.dart` — removed the runtime-uninstall fencing
  test; kept the agent-hook evaluator tests.
- `test/wave2_hooks_lifecycle_test.dart` — removed runtime
  uninstall/disable/persisted-runtime tests; kept hook lifecycle fencing tests.
- `test/agent_dispatch_route_contract_test.dart` — removed the `_Fanout`
  helper and the `runPromptTool` fanout test; kept all route/admission tests.
- `test/agent_hook_integration_test.dart`,
  `test/agent_hook_production_test.dart`,
  `test/hook_permission_request_contract_test.dart` — removed the deleted
  `pluginBootActivator` test seam only.
- `test/p0_reliability_test.dart` — removed marketplace-source and
  builtin-plugin-install groups; kept provider/model identity pins.
- `test/settings_actions_integration_test.dart` — removed the MCP import and
  one `oauthMemoryEmpty` assertion; kept the reset contract.
- `test/session_ledger_integration_test.dart` — removed the deleted
  `pluginBootActivator` seam only.
- `test/security_ssrf_guard_test.dart` — removed the `NativeFetchMcpHandler`
  test and import; kept the full address-classification/DNS suite.
- `test/security_secret_scrub_test.dart` — removed the `redactStartupError`
  test (defined in the deleted `plugin_runtime`) and import; kept every
  surviving scrub pin.
- `test/background_notifications_test.dart` — init test now expects only
  `notifyConfigure` (the dead `bgSetKeepActive` call is gone).
- `test/token_budget_test.dart` — removed the three deleted tool names from
  the required roster (`agent_install_plugin`, `agent_install_mcp`,
  `catalog_add_mcp`); every surviving capability family is still asserted.
- `test/codex_parity_test.dart` — removed the three source-inspection tests
  for deleted plugin/MCP wiring (plugin MCP mount, legacy install allowlist,
  marketplace discovery) and the deleted `mcp_service` env assertion; kept the
  transport/config.toml parsing, Codex workspace roots, and skill-matcher
  tests.

New pinning test: `test/chat_tool_visuals_cloud_test.dart` (2 tests) — an
`mcp__github__list` tool Message renders its MCP glyph/title/state with no
plugin runtime present.

## Modified production files

`lib/main.dart` (elicitor + OAuth redirect wiring removed),
`lib/ui/shell.dart` (`McpService.disconnectAll` removed; WS close only),
`lib/ui/chat_screen.dart` (MCP/plugin slash sources removed),
`lib/core/state.dart` (PluginItem/McpServer/plugins/mcpServers, marketplace
sync, plugin content mount, MCP persistence, native-plugin registration,
plugin-safety startup, keep-alive pref removed),
`lib/core/settings_state_integration.dart` (plugin/MCP reset keys removed),
`lib/core/agent_service.dart` (mcp/plugin/native-plugin imports + members,
MCP dispatch cases, plugin install/config cases, MCP sampling/roots/progress,
and the dead MCP/plugin/catalog tool schemas removed; mechanical only),
`lib/core/hook_service.dart` (legacy PluginItem hooks + userConfig removed),
`lib/core/background_notifications.dart` (keep-alive call removed),
`lib/core/distribution.dart` (keep-alive flag removed),
plus comment-only edits in the five deferred model files so the acceptance
grep is empty.

## Gates

- `flutter analyze`: **No issues found!**
- acceptance grep `McpService|PluginRegistry|plugin_runtime` in `lib/`: **0**
- `test/chat_tool_visuals_cloud_test.dart`: **2/2**
- settings/sidebar suites: **36/36**
- full `flutter test --no-pub`: **2,660 passed / 3 skipped / 0 failed**
  (exit 0, run twice after the final edits). Baseline was ~4,007; the −1,347
  delta is the 73 deleted module-owned test files.
- `flutter analyze` on a clean `git archive HEAD` copy with only this task's
  diff applied: **No issues found!**
- `flutter build apk --debug`: **built successfully** (`app-debug.apk`, exit 0)

## LOC removed

`git diff --stat -- lib test`: **134 files changed, 129 insertions,
61,588 deletions** (deleted files alone: 53,893 lines at HEAD).
