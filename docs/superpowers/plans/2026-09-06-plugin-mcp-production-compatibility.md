# Production Plugin and MCP Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make production [CC], Codex, generic plugin, and MCP packages install and run honestly on Android, with one-time capability approval, automatic isolated dependencies, namespaced contributions, complete hook lifecycle, session-to-global activation after one restart, and verified preinstalled capabilities.

**Architecture:** Add a normalized plugin manifest and runtime manager beside the existing `AppState` catalog, then route install/enable/disable/uninstall through atomic staged activation. Compatibility adapters preserve source files while mapping commands, skills, agents, hooks, MCP servers, dependencies, and permissions into namespaced registries; existing `HookService`, `SkillService`, `McpService`, and `AgentService` remain execution backends.

**Tech Stack:** Flutter/Dart, Android sandbox runtimes (Node/Python/native packages), `SharedPreferences`, `FlutterSecureStorage`, stdio + Streamable HTTP MCP, GitHub/npm/local/ZIP source ingestion, `flutter test`.

**Spec:** `docs/superpowers/specs/2026-09-06-plugin-mcp-production-compatibility-design.md` @ `d4cc5e8`.

## Global Constraints

- Flutter binary is `/home/ubuntu/sdk/flutter/bin/flutter`.
- TDD RED→GREEN for each task; all currently-green tests remain green.
- Original plugin source files are preserved; adaptation is metadata-only.
- One consolidated capability/dependency approval per plugin manifest digest; new capabilities on update require delta approval.
- Agent installs activate immediately only in the installing session, then become global after exactly one restart. Plugins-screen installs activate globally after one restart.
- Canonical IDs are namespaced; collisions never silently overwrite.
- Hook failures fail open with visible diagnostics; only explicit valid block decisions deny.
- Secrets remain in secure storage and are exposed only to their owning runtime.
- No preinstalled plugin/MCP may report installed, connected, or working without a real capability/handshake.
- Zero reference-web mentions in `lib/` and `test/`.

---

### Task 1: Normalized manifest, capability grants, and activation records

**Files:**
- Create: `lib/core/plugin_manifest.dart`
- Modify: `lib/core/state.dart` (`PluginItem` persisted runtime fields)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Produces `PluginFormat`, `PluginCapability`, `PluginActivation`, `PluginInstallOrigin`, `NormalizedPluginManifest`, `PluginPermissionGrant`, `PluginActivationRecord`, `CompatibilityIssue`.
- `NormalizedPluginManifest.canonicalId(publisher, name)` produces lowercase slash-safe IDs.

- [ ] **Step 1: Write failing round-trip and namespace tests**

```dart
test('PLUGIN1: normalized manifest and grants round-trip with stable namespaced IDs', () {
  final m = NormalizedPluginManifest(
    id: NormalizedPluginManifest.canonicalId('Acme Inc', 'Reviewer Pro'),
    name: 'Reviewer Pro', version: '1.2.0', format: PluginFormat.claudeCode,
    rootPath: '/plugins/acme', commands: const [], skills: const [], agents: const [],
    hooks: const [], mcpServers: const [],
    dependencies: const PluginDependencies(),
    requestedCapabilities: const {PluginCapability.workspaceRead, PluginCapability.shellExecute},
    unknownFields: const {'futureField': true}, compatibility: const [],
  );
  expect(m.id, 'acme-inc/reviewer-pro');
  expect(NormalizedPluginManifest.fromJson(m.toJson()).unknownFields['futureField'], isTrue);

  final grant = PluginPermissionGrant(
    pluginId: m.id, manifestDigest: 'sha256:abc',
    capabilities: const {PluginCapability.workspaceRead}, approvedAt: DateTime.utc(2026),
  );
  expect(PluginPermissionGrant.fromJson(grant.toJson()).capabilities,
      {PluginCapability.workspaceRead});
});
```

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PLUGIN1"`
Expected: compile failure for missing manifest types.

- [ ] **Step 3: Implement immutable models and JSON conversion**

Implement all types in `plugin_manifest.dart`; contribution records must carry canonical IDs, source-relative paths, frontmatter, and raw unknown fields. Add to `PluginItem`: `runtimeId`, `activation`, `immediateSessionId`, `promoteOnNextBoot`, `manifestDigest`, `compatibilityWarnings`, with backward-compatible JSON defaults (`disabled` for catalog-only rows; existing installed rows become `globalActive` only after Task 9 audit confirms capability).

- [ ] **Step 4: Run GREEN and full file tests**

Run focused PLUGIN1, then `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`.

- [ ] **Step 5: Commit**

```bash
git add lib/core/plugin_manifest.dart lib/core/state.dart test/core_regression_test.dart
git commit -m "feat: normalized plugin manifest and activation model"
```

---

### Task 2: [CC], Codex, and generic MCP adapters

**Files:**
- Create: `lib/core/plugin_adapters.dart`
- Modify: `lib/core/skills.dart` (supporting-file metadata and recursive safe bundle scan)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes Task 1 models.
- Produces `ClaudePluginAdapter.inspect(Directory)`, `CodexPluginAdapter.inspect(Directory)`, `GenericMcpAdapter.inspectConfig(String, {required String sourceId})`, and `PluginAdapterRegistry.inspect(Directory)`.

- [ ] **Step 1: Add fixture-driven failing tests**

Create temporary plugin trees in tests covering `.claude-plugin/plugin.json`, recursive commands, skill assets, agents, multiple hook groups, `.mcp.json`, `AGENTS.md`, `.agents/skills`, and Codex `config.toml`. Assert normalized canonical IDs, all contributions, inferred capabilities, preserved unknown fields, and required-vs-optional compatibility issues.

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PLUGIN2"`
Expected: missing adapter classes.

- [ ] **Step 3: Implement adapters**

Use safe recursive walks (`followLinks:false`, max depth 12, lexical containment). Parse command/skill/agent frontmatter without rewriting files. Copy supporting skill files into contribution metadata. Map both `mcpServers` and `mcp_servers` using the existing parser helpers; preserve env/header names without secret values. Normalize existing six Ovid hook aliases and native [CC] names into canonical events from the spec.

- [ ] **Step 4: Verify focused and full tests**

Run PLUGIN2 tests, full regression file, and `flutter analyze`.

- [ ] **Step 5: Commit**

```bash
git add lib/core/plugin_adapters.dart lib/core/skills.dart test/core_regression_test.dart
git commit -m "feat: Claude Code and Codex plugin compatibility adapters"
```

---

### Task 3: Secure source resolver (marketplace, GitHub, local, ZIP, npm, config, direct MCP)

**Files:**
- Create: `lib/core/plugin_source_resolver.dart`
- Modify: `lib/core/state.dart` (replace selective fetch path with resolver delegation)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Produces `PluginSource` sealed variants and `PluginSourceResolver.resolve(PluginSource) -> Future<ResolvedPluginSource>`.
- Staging directories live under app-private `plugin-staging/<transaction-id>`.

- [ ] **Step 1: Write failing source and hostile archive tests**

Test local folder copy, ZIP traversal rejection (`../escape`), absolute entry rejection, symlink escape rejection, GitHub mock-server archive, npm metadata/tarball resolution, pasted JSON/TOML, and direct stdio/HTTP MCP source creation.

- [ ] **Step 2: Run RED**

Run PLUGIN3 tests; expect missing resolver.

- [ ] **Step 3: Implement resolver**

Reuse existing GitHub timeout/user-agent patterns. Resolve every source into staging without modifying original content. Verify npm integrity when `dist.integrity` exists. Stream payloads to disk; manifest text parsing remains bounded. Delete staging on every error. Expose progress callback `(received,total?)`.

- [ ] **Step 4: Verify tests**

Run PLUGIN3, full regression, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/core/plugin_source_resolver.dart lib/core/state.dart test/core_regression_test.dart
git commit -m "feat: secure multi-source plugin resolver"
```

---

### Task 4: Namespaced contribution registry and session scoping

**Files:**
- Create: `lib/core/plugin_registry.dart`
- Modify: `lib/core/agent_service.dart` (tool roster/dispatch)
- Modify: `lib/core/skills.dart` (canonical lookup + unique alias)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Produces `PluginContributionRegistry.register`, `unregisterPlugin`, `toolsForSession`, `resolveAlias`, `isPluginActiveForSession`.
- Canonical IDs match spec §4.4.

- [ ] **Step 1: Write failing collision/scope tests**

Test two plugins both contributing `review`: canonical tools coexist, bare alias is ambiguous, unique alias resolves, a `sessionActive` plugin is visible only in `immediateSessionId`, and `globalActive` is visible everywhere.

- [ ] **Step 2: Run RED**

Run PLUGIN4 tests; expect missing registry.

- [ ] **Step 3: Implement registry and route roster**

Replace generic `plugin_<name>` collapse with canonical command/skill/agent tools. Keep existing seed built-ins routed to their real handlers. Resolve active plugin contributions by running session ID, not foreground session. Ambiguous aliases return an exact list of canonical options and do not execute.

- [ ] **Step 4: Verify**

Run PLUGIN4, existing plugin/MCP tests, full suite, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/core/plugin_registry.dart lib/core/agent_service.dart lib/core/skills.dart test/core_regression_test.dart
git commit -m "feat: namespaced plugin contributions and session scope"
```

---

### Task 5: Capability approval and secure grant persistence

**Files:**
- Create: `lib/ui/plugin_permission_sheet.dart`
- Create: `lib/core/plugin_permissions.dart`
- Modify: `lib/core/state.dart`
- Modify: `lib/ui/plugins_screen.dart`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Produces `PluginPermissionStore.load/save/revoke`, capability inference explanations, and consolidated install sheet result.

- [ ] **Step 1: Write failing permission tests**

Test first approval, unchanged digest reuse, capability-delta requiring reapproval, revocation, denied capability, and ensure secret values never appear in JSON/preferences.

- [ ] **Step 2: Run RED**

Run PLUGIN5 tests; expect missing permission store.

- [ ] **Step 3: Implement permission store and sheet**

Persist non-secret grants in preferences keyed by plugin ID + digest. Store secret values in `FlutterSecureStorage` under owner-scoped keys. Sheet lists capability, inferred reason/source path, dependency commands, and Accept/Cancel. No per-action prompts after grant; normal session mode and approval policy still apply.

- [ ] **Step 4: Verify**

Run PLUGIN5, widget test for sheet, full suite, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/core/plugin_permissions.dart lib/ui/plugin_permission_sheet.dart lib/core/state.dart lib/ui/plugins_screen.dart test/core_regression_test.dart
git commit -m "feat: one-time plugin capability approval"
```

---

### Task 6: Isolated automatic dependency installer

**Files:**
- Create: `lib/core/plugin_dependency_service.dart`
- Modify: `lib/core/sandbox_service.dart` (plugin-specific environment/cwd helper)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Produces `PluginDependencyService.install(manifest, grant, onProgress)`, `probe`, `removeVersion`, `PluginDependencyResult`.

- [ ] **Step 1: Write failing command-shape and failure tests**

Test npm local prefix + lockfile, Python isolated target/venv, native package ABI check, lifecycle scripts denied without `shellExecute`, optional failure -> degraded, required failure -> failed, and no writes outside plugin runtime root.

- [ ] **Step 2: Run RED**

Run PLUGIN6 tests; expect missing service.

- [ ] **Step 3: Implement installer**

Install under `<app-data>/plugin-runtime/<id>/<version>/`. Use sandbox `npm`, Python, and package manager already present; never Android system paths. Capture command, exit, resolved versions, checksums, and capped logs. Required failures abort; optional failures identify disabled contributions.

- [ ] **Step 4: Verify**

Run PLUGIN6, existing sandbox tests, full suite, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/core/plugin_dependency_service.dart lib/core/sandbox_service.dart test/core_regression_test.dart
git commit -m "feat: isolated automatic plugin dependencies"
```

---

### Task 7: Atomic runtime manager and one-restart activation

**Files:**
- Create: `lib/core/plugin_runtime.dart`
- Modify: `lib/core/state.dart` (`initialize`, install/enable/disable/uninstall delegation)
- Modify: `lib/core/agent_service.dart` (agent install origin/session)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes Tasks 1-6.
- Produces `PluginRuntimeManager.inspect/install/activateForBoot/disable/uninstall/isActiveForSession`.

- [ ] **Step 1: Write failing activation/rollback tests**

Test agent install -> current session active + `promoteOnNextBoot`; another session cannot resolve it; Plugins-screen install -> pending and unavailable; first simulated boot promotes both globally and clears flag; second boot is idempotent; failed dependency rolls back files/registry/MCP/secrets; upgrade failure retains prior version.

- [ ] **Step 2: Run RED**

Run PLUGIN7 tests; expect missing manager.

- [ ] **Step 3: Implement transaction and boot epoch**

Use staging, inspection, grant, dependencies, probe, persisted manifest/record, registry activation, then atomic directory rename. Add one `bootEpoch` increment in `AppState._initialize`; `activateForBoot` promotes records whose `installedBootEpoch < currentBootEpoch && promoteOnNextBoot`. Agent tool passes `PluginInstallOrigin.agent` and run session; UI passes `.pluginsScreen`.

- [ ] **Step 4: Verify**

Run PLUGIN7, install/uninstall legacy tests, full suite, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/core/plugin_runtime.dart lib/core/state.dart lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "feat: atomic plugin runtime and one-restart promotion"
```

---

### Task 8: Full hook lifecycle, ordering, and circuit breaker

**Files:**
- Modify: `lib/core/hook_service.dart`
- Modify: `lib/core/agent_service.dart` (all lifecycle wiring)
- Modify: `lib/core/state.dart` (multiple hook records, canonical names)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes normalized `PluginHook` and activation registry.
- Produces canonical events from spec §8, alias mapping, ordered multiple hooks, explicit-block-only gates, circuit breaker.

- [ ] **Step 1: Write failing lifecycle tests**

Test all 13 canonical lifecycle points, aliases, manifest order, install order, session scope, matcher groups, full payload/args, timeout cap, output cap, malformed output fail-open warning, exit-2/JSON block, recursion prevention, and repeated-failure circuit breaker.

- [ ] **Step 2: Run RED**

Run PLUGIN8 tests; expect missing canonical events/multiple-hook model.

- [ ] **Step 3: Implement hooks**

Replace `Map<event,String>` runtime consumption with ordered `List<PluginHook>` while retaining backward JSON migration. Add context env (`PLUGIN_ROOT`, storage, workspace, session, model, event, payload). Wire missing lifecycle points around user prompt, provider request/response, permissions, compaction, stop, and subagent start/end. Only `pre_tool` and `permission_request` explicit block responses deny; everything else logs and continues.

- [ ] **Step 4: Verify**

Run PLUGIN8 plus all existing hook tests, full suite, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/core/hook_service.dart lib/core/agent_service.dart lib/core/state.dart test/core_regression_test.dart
git commit -m "feat: production plugin hook lifecycle"
```

---

### Task 9: Plugin-owned namespaced MCP lifecycle

**Files:**
- Modify: `lib/core/mcp_service.dart`
- Modify: `lib/core/plugin_runtime.dart`
- Modify: `lib/core/plugin_registry.dart`
- Modify: `lib/core/state.dart` (ownership persistence/migration)
- Modify: `lib/core/agent_service.dart` (canonical MCP tools and aliases)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Produces owner ID on `McpServer`, canonical `<plugin-id>/<server-name>`, owned secret/process/reconnect/tool cleanup.

- [ ] **Step 1: Write failing ownership tests**

Test two plugins with same server/tool names coexist; unique alias only; missing credential -> degraded not connected; activation connects; list_changed refreshes tools; disable disconnects/removes roster; uninstall deletes owned secrets; unrelated server remains alive.

- [ ] **Step 2: Run RED**

Run PLUGIN9 tests; expect bare-name dedupe/collision failures.

- [ ] **Step 3: Implement ownership**

Add `ownerPluginId` and canonical ID persistence. Mount with canonical names, store env/headers under canonical owner keys, resolve cwd inside plugin runtime, and delegate lifecycle to `McpService`. Preserve old custom server names through migration with `ownerPluginId=null`.

- [ ] **Step 4: Verify**

Run PLUGIN9 plus full MCP suite, full regression, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/core/mcp_service.dart lib/core/plugin_runtime.dart lib/core/plugin_registry.dart lib/core/state.dart lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "feat: namespaced plugin-owned MCP lifecycle"
```

---

### Task 10: Production audit of preinstalled plugins and MCPs

**Files:**
- Modify: `lib/core/state.dart:3447-3632,4213-4480` (seed truthfulness)
- Modify: `lib/core/plugin_runtime.dart` (boot probes)
- Modify: `lib/ui/plugins_screen.dart` and `lib/ui/health_screen.dart`
- Create: `docs/superpowers/audits/2026-09-06-preinstalled-plugin-mcp-runtime.md`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Produces honest preinstalled states: `working`, `notConfigured`, `available`, `unsupported`, `degraded`, `failed`; no hardcoded connected/working.

- [ ] **Step 1: Write failing seed audit test**

```dart
test('PLUGIN10: every preinstalled enabled plugin has real capability and no MCP is fake-connected', () {
  final app = AppState.createForTest();
  for (final p in app.plugins.where((p) => p.installed && p.enabled)) {
    expect(AgentService.I.pluginToolNames(p), isNotEmpty,
        reason: '${p.name} is marked installed but contributes nothing');
  }
  for (final s in app.mcpServers.where((s) => s.connected)) {
    expect(McpService.I.isConnected(s.name), isTrue,
        reason: '${s.name} is hardcoded connected without a handshake');
  }
});
```

- [ ] **Step 2: Run RED**

Expected: seeded entries such as hardcoded Chrome DevTools connected state and installed-but-disabled/no-tool rows fail.

- [ ] **Step 3: Audit and correct each seed**

Document every built-in plugin/MCP with backing implementation, package/URL, Android runtime requirements, credentials, and resulting state. Keep core built-ins installed only when real handlers exist. Convert marketing rows to `available`. Remove hardcoded `connected:true`; derive status only after handshake. Mark unavailable/unpublished package coordinates unsupported or replace with verified current coordinates. Credential-dependent servers remain notConfigured until secret setup.

- [ ] **Step 4: Add boot probe and UI states**

Probe dependency/runtime/credential prerequisites at startup. Plugins and Health screens show exact state and actionable diagnostics, never binary optimism.

- [ ] **Step 5: Verify and commit**

Run PLUGIN10, full regression, analyze, and debug APK build.

```bash
git add lib/core/state.dart lib/core/plugin_runtime.dart lib/ui/plugins_screen.dart lib/ui/health_screen.dart docs/superpowers/audits/2026-09-06-preinstalled-plugin-mcp-runtime.md test/core_regression_test.dart
git commit -m "fix: make every preinstalled plugin and MCP runtime-honest"
```

---

### Task 11: Production plugin UI and complete install entry points

**Files:**
- Modify: `lib/ui/plugins_screen.dart`
- Modify: `lib/core/agent_service.dart` (all source arguments for agent install)
- Modify: `lib/main.dart` (single boot activation)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes runtime manager and permission sheet.
- Produces install flows for marketplace, GitHub, folder, ZIP, npm, JSON/TOML, stdio, HTTP; status/contributions/logs/permissions UI.

- [ ] **Step 1: Write failing widget and dispatch tests**

Test each source route reaches `inspect`; permission cancel leaves no state; agent origin carries session ID; Plugins-screen origin is pending; badges render This session / Restart to enable everywhere / Global / Degraded / Failed; retry/disable/uninstall/edit-grants actions call runtime manager.

- [ ] **Step 2: Run RED**

Run PLUGIN11 tests; expect missing entry points/status widgets.

- [ ] **Step 3: Implement UI and agent schemas**

Use one source chooser and one inspection/approval flow. Agent install tools accept typed source variants and return exact activation scope. Add contribution, alias conflict, MCP, hook, dependency, compatibility, grant, and log sections. `main.dart` calls `PluginRuntimeManager.I.activateForBoot()` once after persisted state loads, before reconnecting services.

- [ ] **Step 4: Verify**

Run PLUGIN11, full suite, analyze.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/plugins_screen.dart lib/core/agent_service.dart lib/main.dart test/core_regression_test.dart
git commit -m "feat: production plugin install and diagnostics UI"
```

---

### Task 12: Full verification and Android smoke gate

**Files:**
- Verify all files from Tasks 1-11
- Update: `README.md` with supported plugin/MCP formats and Android limits

- [ ] **Step 1: Static and unit verification**

Run:

```bash
/home/ubuntu/sdk/flutter/bin/flutter analyze
/home/ubuntu/sdk/flutter/bin/flutter test
```

Expected: no issues; all tests pass.

- [ ] **Step 2: Build Android artifact**

Run: `/home/ubuntu/sdk/flutter/bin/flutter build apk --debug`
Expected: APK builds.

- [ ] **Step 3: Smoke checklist**

On Android, install one fixture [CC] plugin with a command/skill/hook/stdio MCP and one Streamable HTTP MCP; approve once; verify current-session activation for agent install, no other-session access before restart, one-restart global promotion, hook firing per request/tool, dependencies, namespaced tools, disable/uninstall cleanup, and accurate health. Record results in `docs/superpowers/audits/2026-09-06-preinstalled-plugin-mcp-runtime.md`.

- [ ] **Step 4: Commit docs**

```bash
git add README.md docs/superpowers/audits/2026-09-06-preinstalled-plugin-mcp-runtime.md
git commit -m "docs: plugin and MCP production compatibility matrix"
```

## Self-Review

1. Spec coverage: source resolution (Task 3), adapters (Task 2), normalized model (Task 1), permissions (Task 5), dependencies (Task 6), activation/restart (Task 7), namespaces/session scope (Task 4), hooks (Task 8), MCP ownership (Task 9), preinstalled truthfulness (Task 10), all install sources/UI (Task 11), release gates (Task 12).
2. No placeholders: each task names concrete files, interfaces, tests, failure expectations, verification, and commit.
3. Type consistency: Task 1 owns all shared models; Tasks 2-11 consume exact names from Task 1. `PluginRuntimeManager`, `PluginContributionRegistry`, `PluginPermissionStore`, and `PluginDependencyService` each have one responsibility.
