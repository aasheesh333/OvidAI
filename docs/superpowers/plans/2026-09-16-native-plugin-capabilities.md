# Native Plugin Capabilities (NP1 & NP2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the in-process Native Plugin Capability framework (NP1) and 15 pure-Dart utility plugins (NP2) so catalog items install cleanly without PRoot/sandbox dependencies, expose real tools to the agent as `plugin__<slug>__<tool>`, and support dynamic agent/user configuration.

**Architecture:** A `NativePluginCapability` abstraction registered in `NativePluginRegistry` allows pure-Dart handlers to define tools and configuration. `AgentService` binds installed native plugins to the LLM tool roster, `plugins_screen.dart` routes install to in-process activation (`PluginInstallKind.nativeCapability`), and sensitive plugin configuration persists in `FlutterSecureStorage`.

**Tech Stack:** Dart, Flutter, `http`, `crypto`, `markdown`, `shared_preferences`, `flutter_secure_storage`.

**Spec:** `docs/superpowers/specs/2026-09-16-native-plugin-capabilities-design.md`

## Global Constraints
- Zero reliance on PRoot, sandbox, Node.js, or external repos for native plugins.
- Tool naming strictly follows `plugin__<plugin_slug>__<tool_name>`.
- Honest install reporting: `_pluginToolNames` and roster truth must match exactly.
- Secrets (API keys, passwords, auth tokens) must be stored in `FlutterSecureStorage`, not plaintext prefs.
- `flutter analyze` must report 0 issues, and all tests must pass.

---

### Task 1: Native Plugin Capability Base, Registry & Config Store

**Files:**
- Create: `lib/core/native_plugin.dart`
- Create: `test/native_plugin_framework_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class NativePluginTool {
    final String name;
    final String description;
    final Map<String, dynamic> inputSchema;
    const NativePluginTool({required this.name, required this.description, required this.inputSchema});
  }

  class NativePluginConfigField {
    final String key;
    final String label;
    final bool secret;
    final String? hint;
    const NativePluginConfigField({required this.key, required this.label, this.secret = false, this.hint});
  }

  abstract class NativePluginCapability {
    String get pluginName;
    List<NativePluginConfigField> get configFields;
    List<NativePluginTool> get tools;
    Future<void> configure(Map<String, String> values);
    Future<String> callTool(String toolName, Map<String, dynamic> args);
  }

  class NativePluginRegistry {
    static final NativePluginRegistry I = ...;
    void register(NativePluginCapability capability);
    bool has(String pluginName);
    NativePluginCapability? capabilityFor(String pluginName);
    NativePluginCapability? capabilityForSlug(String slug);
    String slugFor(String pluginName);
    List<NativePluginCapability> get all;
    void clearForTest();
  }
  ```

- [ ] **Step 1: Write test for NativePluginRegistry and configuration storage**

Write `test/native_plugin_framework_test.dart` testing:
1. Registration and lookup by plugin name (case-insensitive) and slug.
2. Storing and retrieving secret vs non-secret configuration values.
3. Slug normalization (`"JSON Visualizer"` -> `"json_visualizer"`).

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugin_framework_test.dart`
Expected: FAIL (file not found)

- [ ] **Step 3: Implement `lib/core/native_plugin.dart`**

Implement `NativePluginTool`, `NativePluginConfigField`, `NativePluginCapability`, and `NativePluginRegistry`.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugin_framework_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugin.dart test/native_plugin_framework_test.dart
git commit -m "feat(plugin): implement NativePluginCapability base and NativePluginRegistry"
```

---

### Task 2: Install Routing & UI Integration in Plugins Screen

**Files:**
- Modify: `lib/ui/plugins_screen.dart`
- Modify: `test/plugin_install_route_test.dart`

**Interfaces:**
- Consumes: `NativePluginRegistry.I.has` from `lib/core/native_plugin.dart`
- Produces: `PluginInstallKind.nativeCapability` enum entry in `pluginInstallRouteForTest`.

- [ ] **Step 1: Write test for `PluginInstallKind.nativeCapability` routing**

In `test/plugin_install_route_test.dart`, add tests verifying:
1. A plugin whose name is registered in `NativePluginRegistry` routes to `PluginInstallKind.nativeCapability`.
2. Unregistered source-less plugin still routes to `PluginInstallKind.unsupported`.

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/plugin_install_route_test.dart`
Expected: FAIL (`nativeCapability` doesn't exist)

- [ ] **Step 3: Update `lib/ui/plugins_screen.dart`**

1. Add `nativeCapability` to `PluginInstallKind` enum.
2. In `pluginInstallRouteForTest(PluginItem plugin)`:
   ```dart
   if (NativePluginRegistry.I.has(plugin.name)) {
     return (kind: PluginInstallKind.nativeCapability, github: null, server: null);
   }
   ```
3. In `plugins_screen.dart` install button switch-case:
   ```dart
   case PluginInstallKind.nativeCapability:
     await app.installBuiltinPlugin(plugin);
     if (context.mounted) {
       ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(content: Text('${plugin.name} installed')),
       );
     }
   ```

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/plugin_install_route_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ui/plugins_screen.dart test/plugin_install_route_test.dart
git commit -m "feat(plugin): route native capabilities to in-process install"
```

---

### Task 3: Agent Roster, Tool Dispatch & Configuration in AgentService

**Files:**
- Modify: `lib/core/agent_service.dart`
- Create: `test/native_plugin_agent_test.dart`

**Interfaces:**
- Consumes: `NativePluginRegistry`
- Produces:
  - Agent tools in roster: `plugin__<slug>__<tool_name>`
  - Execution handling for `plugin__*`
  - Agent tool: `catalog_configure_plugin`

- [ ] **Step 1: Write integration tests for AgentService native plugin tool lifecycle**

Write `test/native_plugin_agent_test.dart` testing:
1. Discovered tools from an installed & enabled native plugin appear in `_tools`.
2. Disabling the plugin removes the tools from `_tools`.
3. Calling `plugin__<slug>__<tool>` invokes `capability.callTool` and returns output.
4. Calling `catalog_configure_plugin` updates the capability's configuration.

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugin_agent_test.dart`
Expected: FAIL

- [ ] **Step 3: Update `lib/core/agent_service.dart`**

1. In `_tools` generation:
   Iterate over installed and enabled plugins with registered native capabilities and add their tools with prefix `plugin__<slug>__<tool.name>`.
2. In `_pluginToolNames`:
   If `NativePluginRegistry.I.has(p.name)`, return tools formatted as `plugin__<slug>__<tool.name>`.
3. In `executeTool`:
   Add handler for `String() when name.startsWith('plugin__')`:
   Parse `<slug>` and `<tool_name>`, locate capability, check plugin is enabled, call `capability.callTool`.
4. Add `catalog_configure_plugin` tool definition in `_coreTools` and handler in `executeTool`.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugin_agent_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/native_plugin_agent_test.dart
git commit -m "feat(agent): wire native plugin capabilities into tool roster and dispatch"
```

---

### Task 4: Implement NP2 Part A Utility Capabilities

**Plugins:**
1. `JSON Visualizer` (`json_visualizer`)
2. `Regex Builder` (`regex_builder`)
3. `SQL Formatter` (`sql_formatter`)
4. `Cron Designer` (`cron_designer`)
5. `Color Palette Gen` (`color_palette_gen`)

**Files:**
- Create: `lib/core/native_plugins/data_utilities.dart`
- Create: `test/native_plugins_data_test.dart`

- [ ] **Step 1: Write tests for Part A utilities**

Test inputs and outputs for:
- JSON format, minify, query (e.g. `a.b.0.c`), stats.
- Regex test (match indices), replace, explain.
- SQL format and syntax validation.
- Cron explain, build, and next_runs.
- Color palette from_hex, WCAG contrast calculation.

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_data_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement `lib/core/native_plugins/data_utilities.dart`**

Implement handlers for the 5 capabilities and a `registerDataUtilities()` function.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_data_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/data_utilities.dart test/native_plugins_data_test.dart
git commit -m "feat(plugin): implement native JSON, Regex, SQL, Cron, and Color utilities"
```

---

### Task 5: Implement NP2 Part B Utility Capabilities

**Plugins:**
6. `File Converter` (`file_converter`)
7. `Markdown Editor` (`markdown_editor`)
8. `Password Vault` (`password_vault`)
9. `Env Manager` (`env_manager`)
10. `Log Analyzer` (`log_analyzer`)

**Files:**
- Create: `lib/core/native_plugins/dev_utilities.dart`
- Create: `test/native_plugins_dev_test.dart`

- [ ] **Step 1: Write tests for Part B utilities**

Test inputs and outputs for:
- CSV to JSON and JSON to CSV conversion.
- Markdown HTML rendering (via `package:markdown`), TOC extraction, word count stats.
- Password Vault cryptographically secure generation, store/get/list.
- Env Manager parse, set, and merge.
- Log Analyzer severity counting and level/text filtering.

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_dev_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement `lib/core/native_plugins/dev_utilities.dart`**

Implement handlers for the 5 capabilities and a `registerDevUtilities()` function.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_dev_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/dev_utilities.dart test/native_plugins_dev_test.dart
git commit -m "feat(plugin): implement native File Converter, Markdown, Vault, Env, and Log utilities"
```

---

### Task 6: Implement NP2 Part C Utility Capabilities

**Plugins:**
11. `API Tester` (`api_tester`)
12. `Web Scraper Pro` (`web_scraper_pro`)
13. `Prompt Library` (`prompt_library`)
14. `DB Designer` (`db_designer`)
15. `Web Clipper` (`web_clipper`)

**Files:**
- Create: `lib/core/native_plugins/web_and_db_utilities.dart`
- Create: `test/native_plugins_web_db_test.dart`

- [ ] **Step 1: Write tests for Part C utilities**

Test inputs and outputs for:
- API Tester dispatching mock HTTP GET/POST and returning status/headers/body.
- Web Scraper Pro extracting elements and attributes from HTML text.
- Prompt Library save, list, get, and delete.
- DB Designer generate_ddl (PostgreSQL/SQLite) and schema validation.
- Web Clipper fetching webpage and returning structured markdown.

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_web_db_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement `lib/core/native_plugins/web_and_db_utilities.dart`**

Implement handlers for the 5 capabilities and a `registerWebAndDbUtilities()` function.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_web_db_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/web_and_db_utilities.dart test/native_plugins_web_db_test.dart
git commit -m "feat(plugin): implement native API Tester, Scraper, Prompt, DB Designer, and Clipper"
```

---

### Task 7: Bootstrap All Native Capabilities & Full Verification

**Files:**
- Modify: `lib/core/state.dart` (call registration during app initialize)
- Test: All unit and regression tests

- [ ] **Step 1: Call `registerAllNativePlugins()` during app initialization in `lib/core/state.dart`**
- [ ] **Step 2: Run Dart Analyzer**

Run: `/root/flutter/bin/dart analyze lib test`
Expected: 0 issues.

- [ ] **Step 3: Run Flutter Test Suite**

Run: `/root/flutter/bin/flutter test`
Expected: All tests pass.

- [ ] **Step 4: Commit and Push**

```bash
git add lib/core/state.dart
git commit -m "feat(plugin): bootstrap all 15 native plugin capabilities on app initialization"
git push origin hoplite/gortyn-77773150
```
