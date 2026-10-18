# Task 18 — Agent-core satellites + secondary screens + BYOK escrow UI + `state.dart` strip 2/2

Status: IN PROGRESS (2026-10-18)

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

Filled in as the work lands.

- `flutter analyze`:
- `test/cloud_byok_ui_test.dart`:
- `test/state_persisted_migration_test.dart`:
- full `flutter test --no-pub`:
- `flutter build apk --debug`:
- rename-proof plugin/MCP grep:
