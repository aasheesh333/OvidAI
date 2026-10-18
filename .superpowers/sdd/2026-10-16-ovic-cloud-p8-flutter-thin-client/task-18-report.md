# Task 18 — Agent-core satellites + secondary screens + BYOK escrow UI + `state.dart` strip 2/2

Status: DONE — commit **17128c1** (2026-10-18)

## Scope

- Delete the agent-core satellites (hook engine, skills, compaction, prompt
  cache, plan-mode policy, structured edits, subagent tools, claude-code tools,
  grant store, model-failure classifier, Dart SSRF guard, tool-usage store,
  usage-attempt trio, session lifecycle service, recovered-image helpers) plus
  the five plugin/MCP model files T17 deferred here.
- Re-point secondary screens: trajectory (kept ledger), memory (local store is
  retained only for the T20 import window), subagent (facade/empty),
  permissions (server-managed read-only), image receipts (no local recovery),
  artifacts (R2 URLs), usage (server `/usage` only).
- BYOK escrow UI behind `Distribution.cloudByok`, pinned to the BUILT P9
  server contract (no `fingerprint` field exists).
- `state.dart` strip 2/2 with a persisted-JSON schema bump and migration test.

## Carry items from T17

1. **Five deferred plugin/MCP files deleted here** — acceptance grep uses
   rename-proof terms.
2. **Capability toggles** — decision recorded at the end of this report.

## Deleted (core, 28 files)

`mcp_config_parse.dart`, `plugin_manifest.dart`, `plugin_registry.dart`,
`plugin_permissions.dart`, `plugin_adapters.dart`, `hook_service.dart`,
`hook_context_store.dart`, `hook_execution_scope.dart`, `skills.dart`,
`prompt_cache.dart`, `plan_mode.dart`, `structured_edits.dart`,
`subagent_tools.dart`, `claude_code_tools.dart`, `grant_store.dart`,
`model_failure.dart`, `ssrf_guard.dart`, `tool_usage_store.dart`,
`usage_attempt.dart`, `usage_attempt_recorder.dart`,
`usage_attempt_store.dart`, `session_lifecycle_service.dart`,
`recovered_images.dart`, `image_result_locator.dart`,
`compaction/{compaction_checkpoint,compaction_ledger,compaction_policy}.dart`.

The Dart `ssrf_guard.dart` is the client-side guard, NOT the TypeScript
classifier (which lives in `@ovid/shared`); only the Dart copy was removed.

## BYOK deviations from the plan (implemented against the built P9 server)

- `POST /byok {providerId, endpoint, apiKey, label?}` — `endpoint` is REQUIRED
  and validated by `validateEndpoint`; the client sends exactly this strict
  body.
- `GET /byok → {items}`, `DELETE /byok/:id → 204`,
  `POST /byok/:id/test → {ok, error?}` (surfaced as a row action).
- **No `fingerprint` field exists in `byok_keys`.** The UI shows
  `providerId` + `endpoint` + `label` + `status` only. That is strictly safer
  than the plan's intent: no key-derived value is exposed at all.
- The raw key is never rendered after upload, never logged, and never written
  to SharedPreferences (asserted by `test/cloud_byok_ui_test.dart`).
- `Distribution.cloudByok` is now true by default (the P9 endpoints are
  built); a `byokOverrideForTest` seam keeps the UI testable both ways.

## Gates

- `flutter analyze`: **No issues found!** (working tree and a clean
  `git archive HEAD` copy).
- `test/cloud_byok_ui_test.dart`: **3/3** (upload body is the exact strict
  server shape; the success row shows no key; `find.textContaining('sk-')`
  finds nothing; a SharedPreferences dump has nothing key-shaped; the section
  hides when the flag is off).
- `test/state_persisted_migration_test.dart`: **3/3** (a pre-strip v1 blob
  loads without throwing, drops `grants`/compaction/`planPreMode`/
  `agentAllowedTools`/unknown keys, keeps `planMode` + `planModePending`, and
  writes `schemaVersion: 2`).
- Full `flutter test --no-pub`: **1,915 passed / 2 skipped / 0 failed**
  (JSON reporter, exit 0). Baseline after T17 was 2,660 / 3 / 0; the
  **−745 passed / −1 skipped** delta is the 69 deleted module-owned test
  files (hooks, skills, plugin adapters/manifests, compaction, prompt cache,
  plan-mode engine, grant store, usage-attempt/device-usage, SSRF classifier,
  model failure, old memory/subagent/permissions/usage screens, plus the
  removed `AgentService` hook/usage route contracts). No surviving behaviour
  lost coverage: mixed files were edited, not deleted wholesale.
- `flutter build apk --debug`: **built successfully**
  (`build/app/outputs/flutter-apk/app-debug.apk`, exit 0).
- Rename-proof plugin/MCP grep
  (`PluginContributionRegistry|PluginManifest|PluginPermissions|PluginAdapter|McpConfigParse|plugin_adapters|plugin_manifest|plugin_registry|plugin_permissions|mcp_config_parse`):
  **0 hits in `lib/`**.
- Satellite grep (`HookService|SkillService|CompactionEngine|PromptCache|GrantStore|UsageAttemptStore|ToolUsageStore|SessionLifecycleService|SsrfGuard|ModelFailure|RecoveredImages|ImageResultLocator|SubagentToolPolicy`):
  **0 hits in `lib/`**.

## Carry 2 — capability toggles (answer for T20)

The last plugin-row plumbing died here: `app.plugins` / `PluginItem` were
already removed in T17, and T18 deleted `plugin_registry.dart`,
`plugin_manifest.dart`, `plugin_permissions.dart` and `plugin_adapters.dart`
plus the hook/skill engines that read them. The five built-in capability
families in `agent_service.dart` (web search, image studio, file read, web
fetch, code runner) are now added unconditionally; there is **no user-level
off switch anywhere**. `run_code` is an honest stub (T13 removed on-device
execution), so it does not matter; web search / web fetch / file read / image
studio still work, so a user who disabled them in an older build gets them
back. This is short-lived on the local arm (T19 deletes `agent_service.dart`),
but the **server-side roster has the same product question**: if the cloud
roster exposes these unconditionally, the user also loses the ability to turn
them off there. **T20 must decide whether the server-side roster needs a
per-capability toggle.** T18 deliberately did not invent one.

## Deliberate deferrals / notes

- `settings_backup_service.dart` still performs the local transcript
  backup/restore. It is the surviving §13.3 import/export window and is
  retired by Task 20 once `history_import.dart` ships; shrinking it now would
  remove the only path the import task consumes.
- `session_ledger.dart` and `memory_store.dart` are KEPT (import window), as
  instructed. The memory screen no longer reads `MemoryStore`; only the T20
  importer will.
- `presets.dart` keeps the preset roster but drops `planAllowedTools` /
  `planPolicyFor`; plan mode is UI state only now.
- `usage_today.dart` is server-only (`UsageToday.resolve` + an empty device
  baseline); the device journal was deleted.
