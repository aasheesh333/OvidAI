# Production Plugin and MCP Compatibility Design

**Date:** 2026-09-06
**Status:** Approved
**Project:** Ovid AI Android personal agent

## 1. Goal

Ovid must run production plugins and MCP servers with the capabilities they expect from Claude Code or Codex, without requiring plugin authors to rewrite their packages for Ovid. Every capability Ovid advertises as preinstalled must actually execute on Android; catalog-only or unavailable integrations must be labeled honestly and must never appear connected or operational.

The compatibility target is behavioral, not branding: Ovid preserves source files, adapts supported Claude Code and Codex structures into one internal runtime, and reports unsupported or platform-incompatible requirements instead of pretending they worked.

## 2. Decisions

1. **Runtime architecture:** compatibility adapters over one native Ovid runtime. Ovid does not embed or impersonate the Claude Code or Codex host process.
2. **Permission model:** one consolidated capability approval per plugin at installation. Grants are persisted, visible, editable, and revocable.
3. **Dependencies:** after approval, declared npm, Python, and supported native dependencies install automatically inside the plugin's isolated sandbox.
4. **Agent installation scope:** an AI-agent installation activates immediately only in the installing session and is persisted as `pendingGlobal`. One app restart promotes it once to `globalActive`, after which it applies to every existing and new session.
5. **Plugins-screen scope:** installation is persisted as `pendingGlobal` and becomes `globalActive` for all sessions after one app restart. It does not mutate already-running session runtimes before restart.
6. **Name conflicts:** all contributions have canonical namespaced IDs. A short alias exists only when globally unique; ambiguous aliases return a chooser/error naming each provider.
7. **Hook failure:** only a valid explicit block decision blocks. Crash, timeout, malformed output, or missing runtime produces a visible warning and ledger record but fails open. Post hooks never block.
8. **Sources:** Claude Code and Codex marketplaces, GitHub repositories, local folders and ZIP files, pasted JSON/TOML, npm packages, direct stdio MCP commands, and Streamable HTTP MCP URLs.
9. **Preinstalled guarantee:** every enabled preinstalled plugin or MCP must pass a boot/runtime capability check. Unavailable packages, fake endpoints, missing credentials, or Android-incompatible binaries are not marked working.

## 3. Current-State Problems

Ovid already supports parts of the desired contract:

- Marketplace parsing for list/map forms.
- `commands/`, `skills/*/SKILL.md`, `agents/*.md`, `hooks/hooks.json`, `.claude-plugin/plugin.json`, and `.mcp.json` fetching.
- Six hook event names and a fail-open `on_pre_tool` gate.
- stdio and Streamable HTTP MCP transports, secure environment/header storage, reconnect, and namespaced MCP proxy tools.
- Plugin content caching and basic enable/disable/install persistence.

The production gaps are structural:

- `PluginItem` is catalog metadata, not a normalized executable manifest.
- Only selected files are downloaded; supporting files inside skill/command bundles can be absent.
- Hooks are reduced to one command per event, losing Claude matcher groups, multiple hooks, hook type, timeout, and ordering.
- Plugin tools collapse to a single generic `plugin_<name>` entry rather than namespaced commands/skills/agents.
- Installation has no capability grant, dependency graph, transaction, rollback, or activation scope.
- Plugin-owned MCP names deduplicate globally by bare name, causing silent collisions.
- Several preinstalled catalog entries are marketing rows rather than verified runtimes. Some MCP package coordinates may be unavailable or require credentials but are presented like functioning services.
- Plugin health currently marks every installed+enabled plugin working without probing it.

## 4. Architecture

### 4.1 `PluginRuntimeManager`

Create `lib/core/plugin_runtime.dart` as the single owner of plugin lifecycle. It exposes:

```dart
enum PluginActivation { sessionActive, pendingGlobal, globalActive, degraded, failed, disabled }

class PluginRuntimeManager extends ChangeNotifier {
  static final I = PluginRuntimeManager._();

  Future<PluginInspection> inspect(PluginSource source);
  Future<PluginInstallResult> install(
    PluginInspection inspection,
    PluginPermissionGrant grant, {
    required PluginInstallOrigin origin,
    String? sessionId,
  });
  Future<void> activateForBoot();
  Future<void> disable(String pluginId);
  Future<void> uninstall(String pluginId);
  bool isActiveForSession(String pluginId, String sessionId);
}
```

It delegates source acquisition, format adaptation, dependency installation, contribution registration, and rollback to focused components. Existing `AppState.installPlugin`, `enablePlugin`, `disablePlugin`, and `uninstallPlugin` become thin calls into this manager.

### 4.2 Source resolver

`PluginSourceResolver` normalizes these source types into a read-only staging directory:

| Source | Resolution |
|---|---|
| Claude/Codex marketplace | Resolve catalog entry, then fetch declared source |
| GitHub | Download tree/archive at pinned branch/ref |
| Local folder | Copy into staging with lexical and symlink containment |
| ZIP | Extract into staging; reject absolute paths, traversal, device files, and symlink escapes |
| npm | Resolve metadata/tarball, download with integrity check when supplied, extract safely |
| Pasted JSON/TOML | Store as an ephemeral config source and adapt as MCP-only package |
| Direct command/HTTP URL | Build an MCP-only normalized manifest |

Source resolution has explicit network timeouts, download progress, bounded manifest parsing, and cleanup after failure. Plugin payload size is limited by storage, not an arbitrary transfer cap; individual text manifests still have parser limits to prevent memory abuse.

### 4.3 Compatibility adapters

Adapters preserve original files and emit a `NormalizedPluginManifest`:

```dart
class NormalizedPluginManifest {
  final String id;                    // stable publisher/name identity
  final String name;
  final String version;
  final PluginFormat format;          // claudeCode, codex, genericMcp
  final String rootPath;
  final List<PluginCommand> commands;
  final List<PluginSkill> skills;
  final List<PluginAgent> agents;
  final List<PluginHook> hooks;
  final List<PluginMcpServer> mcpServers;
  final PluginDependencies dependencies;
  final Set<PluginCapability> requestedCapabilities;
  final Map<String, dynamic> unknownFields;
  final List<CompatibilityIssue> compatibility;
}
```

`ClaudePluginAdapter` reads:

- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json` source metadata
- `commands/**/*.md`
- `skills/**/SKILL.md` plus every supporting file under each skill directory
- `agents/**/*.md`
- `hooks/hooks.json`
- `.mcp.json`
- `package.json`, `requirements.txt`, `pyproject.toml`, plugin-local scripts, and declared environment requirements

`CodexPluginAdapter` reads:

- `AGENTS.md` and nested instruction files
- `.agents/skills/**/SKILL.md` plus supporting files
- Codex-compatible agent/persona markdown
- `config.toml` MCP declarations and environment tables
- package/dependency manifests and scripts

`GenericMcpAdapter` accepts `mcpServers`, `mcp_servers`, top-level arrays, direct commands, and Streamable HTTP definitions. SSE-only definitions fail with the existing actionable migration message.

Unknown fields are preserved in `unknownFields`. Optional unsupported behavior produces `degraded` plus a visible warning; required unsupported behavior makes inspection/install fail before activation.

### 4.4 Namespaced contribution registry

Every contribution receives a canonical ID:

```text
plugin:<plugin-id>/command:<name>
plugin:<plugin-id>/skill:<name>
plugin:<plugin-id>/agent:<name>
plugin:<plugin-id>/hook:<event>:<ordinal>
plugin:<plugin-id>/mcp:<server-name>
mcp:<plugin-id>/<server-name>/<tool-name>
```

Aliases (`/review`, `skill`, `mcp__server__tool`) are registered only when unique. A collision never overwrites an earlier contribution. The UI and agent response list canonical choices when an alias is ambiguous.

## 5. Capability and Permission Model

### 5.1 Capabilities

Inspection derives the minimum requested set:

- `workspace.read`, `workspace.write`
- `shell.execute`
- `network.connect`
- `process.spawn`
- `environment.read:<name>`
- `mcp.register`
- `hooks.observe`
- `hooks.block`
- `session.read`, `session.write`
- `device.control` only when explicitly declared and separately allowed by Control mode

The install sheet shows why each capability was inferred and the files that requested it. The user approves once per plugin. Grants persist by plugin ID and manifest digest; a later update requesting new capabilities pauses activation until the delta is approved. Removing a grant immediately disables affected contributions.

Secrets are never copied into plugin metadata or ordinary preferences. Environment and HTTP authorization stay in secure storage and are provided only to the owning process/hook/MCP server.

### 5.2 Install transaction

Installation is atomic:

1. Resolve source into staging.
2. Adapt and validate manifest.
3. Show one consolidated permission and dependency approval.
4. Install dependencies into a versioned private sandbox.
5. Probe commands, hook interpreter, and MCP startup prerequisites.
6. Write normalized manifest, grant, ownership index, and activation state.
7. Register contributions for the permitted scope.
8. Rename staging to the active version.

Any failure before step 8 rolls back files, processes, MCP registrations, hooks, aliases, and secrets created by this transaction. The prior working version remains active during upgrades.

## 6. Dependency Runtime

Approved dependencies install automatically inside:

```text
<app-data>/plugin-runtime/<plugin-id>/<version>/
  node/
  python/
  bin/
  cache/
  storage/
```

- npm: local prefix, lockfile honored, lifecycle scripts run only when `shell.execute` was granted.
- Python: per-plugin virtual environment or isolated target directory using the sandbox Python.
- Native packages: only packages available through Ovid's sandbox package manager and compatible with device ABI. Unsupported desktop binaries yield a precise compatibility error.
- Executables never install into Android system paths.
- Install logs, exit codes, resolved versions, and checksums are retained for diagnostics.

A failed required dependency means `failed` and no partial activation. An optional dependency means `degraded` with the affected contribution disabled.

## 7. Activation and Restart Semantics

Persist these fields per plugin:

```dart
class PluginActivationRecord {
  final String pluginId;
  final PluginActivation state;
  final String? immediateSessionId;
  final int installedBootEpoch;
  final bool promoteOnNextBoot;
}
```

`bootEpoch` increments exactly once during app initialization.

- **Installed by agent:** after successful install, state is `sessionActive`, `immediateSessionId` is the installing session, and `promoteOnNextBoot=true`. It is available immediately only to that session.
- **Installed from Plugins screen:** state is `pendingGlobal`, no immediate session, `promoteOnNextBoot=true`. It is unavailable to running sessions until restart.
- **One restart:** `activateForBoot()` promotes all valid pending records to `globalActive` once, clears `promoteOnNextBoot`, mounts contributions, and reconnects owned MCP servers. No second restart is required.
- **Global active:** applies to every existing and future session.
- **Failed/degraded:** never reported as working; diagnostics identify the exact dependency, capability, hook, or MCP failure.

Agent session scoping is enforced at tool-roster and hook-listener resolution, not only in UI state, so another session cannot call a pending plugin by guessing its canonical name.

## 8. Hooks

### 8.1 Lifecycle

Normalize Claude Code/Codex names into:

```text
session_start
session_end
user_prompt_submit
pre_request
post_request
pre_tool
post_tool
permission_request
notification
pre_compact
post_compact
stop
subagent_start
subagent_end
```

Existing Ovid aliases (`on_session_start`, `on_turn_start`, `on_pre_request`, `on_pre_tool`, `on_post_tool`, `on_turn_end`) remain accepted and map to this canonical set.

Each event supports multiple ordered hooks, matcher groups, command or prompt hook types where implementable, per-hook timeout (capped at 120 seconds), and a 2KB model-context output cap. Environment includes plugin root, private storage, workspace, session ID, selected model, canonical event, payload JSON, and only approved secret names.

### 8.2 Failure and blocking

- `pre_tool` and `permission_request` may block only with exit code 2 or valid JSON `{ "decision": "block", "reason": "..." }`.
- Crash, timeout, missing interpreter, malformed matcher/output, or any other nonzero exit is a visible fail-open warning and ledger event.
- Post/observe hooks are fire-and-forget and cannot block the main run.
- Deterministic ordering is install order, then manifest order.
- A hook cannot recursively invoke its own event; depth is capped and repeated failures trip a per-plugin circuit breaker for the current session.

Hooks run on every matching request/action, not merely at installation. Disabled or out-of-scope plugins never receive events.

## 9. MCP Ownership and Runtime

Plugin-owned MCP names use `<plugin-id>/<server-name>`. The ownership index tracks environment keys, headers, transport, process, tools, reconnect timers, and activation scope.

- Activation mounts and connects servers whose prerequisites and credentials are available.
- Missing credentials produce `degraded: needs configuration`, never fake connected state.
- Disable/uninstall cancels reconnect, disconnects the process/client, removes tools and aliases, and securely deletes owned secrets only on uninstall.
- stdio servers run inside the plugin sandbox with plugin-local dependencies and cwd.
- HTTP servers use Streamable HTTP with session IDs, auth errors, timeouts, and connection-level backoff already supported by `McpService`.
- Tool discovery is refreshed on `notifications/tools/list_changed`.

## 10. Preinstalled Production Audit

The built-in catalog is divided into:

1. **Core built-ins:** real Ovid functions such as web search, file read, browser, sandbox, and memory. They remain enabled only when their backing function exists and passes a capability check.
2. **Bundled MCP definitions:** entries with verified package/command/HTTP coordinates. They start `notConfigured` or `disconnected`, never `connected=true` unless an actual handshake succeeded.
3. **Discoverable catalog entries:** listings without bundled executable content. They are clearly labeled `Available`, not `Installed`, and cannot claim tools or health.

Production release gate:

- No seeded plugin marked installed unless `_pluginToolNames` resolves at least one real tool, hook, skill, agent, or successfully configured MCP server.
- No seeded MCP marked connected unless `McpService.isConnected(name)` is true after handshake.
- Verify every package coordinate against the configured registry during CI or maintain a pinned tested manifest. Missing/unpublished package names are removed or replaced with real implementations.
- Credential-dependent MCPs show setup requirements and do not auto-spawn until configured.
- Android-incompatible desktop servers show `Unsupported on this device` with the missing runtime/ABI reason.
- Startup health is derived from probes, never hardcoded `working`.

## 11. UI and Diagnostics

The Plugins screen provides:

- Source/format badge: Claude Code, Codex, MCP, Ovid built-in.
- Activation badge: This session, Restart to enable everywhere, Global, Degraded, Failed, Disabled.
- One consolidated permissions/dependencies sheet before install.
- Namespaced contributions list and alias conflicts.
- MCP connection state and credential setup.
- Hook event list, last result, failure count, and circuit-breaker state.
- Compatibility warnings with required vs optional distinction.
- Install/runtime logs and Retry, Disable, Uninstall, and Edit permissions actions.

Errors remain actionable: source failure, parse failure, unsupported required field, denied capability, dependency failure, missing secret, MCP handshake failure, or hook failure are distinct states.

## 12. Testing and Release Gates

1. Fixture plugins for Claude Code, Codex, generic MCP, local folder, ZIP, npm, and malformed/hostile packages.
2. Adapter golden tests for commands, skills with assets, agents, multiple hooks/matchers, MCP env/headers/cwd/timeouts, dependencies, unknown fields, and required-capability failures.
3. Permission tests for first approval, unchanged updates, capability-delta reapproval, revoke, and secret isolation.
4. Activation tests for agent immediate-session scope, Plugins-screen pending scope, one-restart global promotion, and no cross-session leakage before restart.
5. Namespace collision tests for command, skill, agent, hook, server, and MCP tool aliases.
6. Hook tests for every lifecycle point, ordering, payload, explicit blocking, timeout fail-open, malformed output, recursion guard, and circuit breaker.
7. MCP ownership tests for mount, connect, reconnect, tool-list changes, disable, uninstall, and failed credentials.
8. Transaction tests proving partial installs and upgrades roll back.
9. Preinstalled audit test: every `installed && enabled` seed has a real capability; every `connected` MCP has a live runtime seam; no fake install counts or success states.
10. Full `flutter analyze`, Flutter tests, debug APK build, and on-device smoke test with one stdio and one Streamable HTTP MCP before release.

## 13. Explicit Limits

- Ovid cannot guarantee arbitrary third-party desktop binaries will run on Android. It guarantees accurate compatibility detection and no false success.
- Unsupported proprietary host APIs are reported with their exact manifest fields; optional ones degrade, required ones fail.
- Plugin capability does not bypass session permission mode, Control mode restrictions, workspace containment, or Android platform security.
- Installing a plugin never grants more authority than the user's consolidated approval.
