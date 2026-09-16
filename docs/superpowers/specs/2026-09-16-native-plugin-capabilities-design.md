# Native Plugin Capabilities & Dynamic Agent Control Spec

**Date:** 2026-09-16  
**Author:** opencode  
**Status:** Approved for Implementation (Sub-project NP1 & NP2)  

---

## 1. Executive Summary

Ovid contains a catalog of ~94 seeded plugins and 7 MCP servers. While 8 core plugins (`Web Search`, `Image Studio`, `File Reader`, etc.) have direct agent tool mappings, and 4 MCP servers (`GitHub`, `Filesystem`, `Fetch`, `Memory`) execute in-process via `NativeMcpHandler`, the remaining ~86 seeded catalog items previously functioned only as static discovery cards. When a user attempted to install one, the UI displayed `"can't be installed from the catalog"`, and the agent could neither install nor execute them.

This specification defines **NP1 (Native Plugin Capability Framework)** and **NP2 (Pure-Dart Utility Plugins Batch)**:
1. **In-Process Native Plugin Framework (`NativePluginCapability`)**: An extensible Dart interface allowing any catalog plugin to register tool schemas and execution handlers that run directly inside Ovid without requiring external repos, sandboxes, or node/python runtimes.
2. **Honest Install & Dynamic Discovery**:
   - `PluginInstallKind.nativeCapability` routes catalog Install buttons directly to in-process activation (`installBuiltinPlugin`), eliminating the `"unsupported"` fallback for all implemented capabilities.
   - `AgentService` registers discovered capability tools into the agent roster as canonical `plugin__<plugin_slug>__<tool_name>` tools.
   - `_pluginToolNames` truthfully advertises these tool gains so UI badges match agent capabilities.
3. **Agent & User Configuration**:
   - Capabilities declare optional or required `NativePluginConfigField` definitions (e.g. API keys, secrets, base URLs).
   - Persistent configuration storage: secrets stored in `FlutterSecureStorage`, non-sensitive settings in `SharedPreferences`.
   - Agent tool `catalog_configure_plugin(plugin, settings)` allows the model to configure plugins on demand.
4. **NP2: Pure-Dart Utility Plugins**: 15 in-process plugins executing zero-dependency or existing-dependency Dart logic:
   - `JSON Visualizer`, `Regex Builder`, `SQL Formatter`, `Cron Designer`, `Color Palette Gen`, `File Converter`, `Markdown Editor`, `Password Vault`, `Env Manager`, `Log Analyzer`, `API Tester`, `Web Scraper Pro`, `Prompt Library`, `DB Designer`, `Web Clipper`.

---

## 2. Architecture & Data Flow

```
+-------------------------------------------------------------------------------+
|                               Chat & Agent Loop                               |
|        plugin__<plugin_slug>__<tool> OR catalog_configure_plugin dispatch     |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+---------------------------------------+---------------------------------------+
|                                  AgentService                                 |
|                                                                               |
|   - _tools roster generation: iterates installed+enabled native plugins       |
|   - _pluginToolNames: advertises tool gains to UI                             |
|   - dispatch: routes plugin__* calls to NativePluginRegistry                  |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+---------------------------------------+---------------------------------------+
|                            NativePluginRegistry                               |
|                     registry of NativePluginCapability                        |
+---------------------------------------+---------------------------------------+
                                        |
    +-----------------+-----------------+-----------------+-----------------+
    |                 |                 |                 |                 |
    v                 v                 v                 v                 v
+---------+     +-----------+     +-----------+     +-----------+     +-----------+
|  JSON   |     |   Regex   |     | Password  |     |    API    |     |    Web    |
| Tools   |     |  Builder  |     |   Vault   |     |  Tester   |     |  Clipper  |
+---------+     +-----------+     +-----------+     +-----------+     +-----------+
 (Dart IO/      (Dart RegExp)      (Secure         (package:http)     (HTTP + text
  convert)                          Storage)                           transform)
```

---

## 3. Detailed Component Specifications

### 3.1 `NativePluginCapability` Interface (`lib/core/native_plugin.dart`)

```dart
class NativePluginTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const NativePluginTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

class NativePluginConfigField {
  final String key;
  final String label;
  final bool secret;
  final String? hint;

  const NativePluginConfigField({
    required this.key,
    required this.label,
    this.secret = false,
    this.hint,
  });
}

abstract class NativePluginCapability {
  String get pluginName;
  List<NativePluginConfigField> get configFields;
  List<NativePluginTool> get tools;
  Future<void> configure(Map<String, String> values);
  Future<String> callTool(String toolName, Map<String, dynamic> args);
}
```

### 3.2 `NativePluginRegistry`

A process-wide registry singleton:
- `register(NativePluginCapability capability)`
- `has(String pluginName)`: Returns true if a native capability is registered for the given plugin name (normalized comparison).
- `capabilityFor(String pluginName)`: Returns the capability if present.
- `slugFor(String pluginName)`: Converts plugin name to snake_case identifier for tool naming (e.g. `JSON Visualizer` -> `json_visualizer`).

### 3.3 Install Routing & UI Integration (`lib/ui/plugins_screen.dart`)

- Update `PluginInstallKind` enum with `nativeCapability`.
- In `pluginInstallRouteForTest(plugin)`:
  - If `NativePluginRegistry.I.has(plugin.name)` is true, return `PluginInstallKind.nativeCapability`.
- In card install button handler:
  - When `route.kind == PluginInstallKind.nativeCapability`, call `app.installBuiltinPlugin(plugin)` and show SnackBar confirmation.
- In `PluginCard` and `PluginDetailScreen`:
  - If capability has `configFields`, show a "Configure" action to inspect/edit settings.

### 3.4 Agent Roster & Dispatch (`lib/core/agent_service.dart`)

- In `_tools`:
  - For each plugin in `app.plugins.where((p) => p.installed && p.enabled)`:
    - If `NativePluginRegistry.I.has(p.name)`:
      - Query capability tools and append them formatted as:
        ```json
        {
          "type": "function",
          "function": {
            "name": "plugin__<slug>__<tool_name>",
            "description": "[<pluginName>] <tool.description>",
            "parameters": tool.inputSchema
          }
        }
        ```
- In `_pluginToolNames(PluginItem p)`:
  - If `NativePluginRegistry.I.has(p.name)`:
    - Return capability tools formatted as `plugin__<slug>__<tool_name>`.
- In `executeTool`:
  - Add case matching `String() when name.startsWith('plugin__')`:
    - Parse `<slug>` and `<tool_name>`.
    - Locate matching capability.
    - Check if the corresponding plugin is installed and enabled. If not, return error.
    - Delegate execution to `capability.callTool(toolName, cleanArgs)`.
- Agent tool `catalog_configure_plugin`:
  - Parameters: `plugin` (string), `settings` (object string-to-string).
  - Updates configuration and persists secrets to `FlutterSecureStorage` and non-secrets to `SharedPreferences`.

---

## 4. NP2: Pure-Dart Utility Implementations

### 1. JSON Visualizer (`json_visualizer`)
- `format(json_string, indent)`: Validates and pretty-prints JSON.
- `minify(json_string)`: Strips whitespace.
- `query(json_string, path)`: Navigates dot-notated or array index path (e.g. `users.0.name`).
- `stats(json_string)`: Reports keys count, max depth, data types, size.

### 2. Regex Builder (`regex_builder`)
- `test(pattern, text, multiline, case_sensitive)`: Tests regex match and returns matches with indices.
- `replace(pattern, replacement, text, multiline, case_sensitive)`: Performs regex search and replace.
- `explain(pattern)`: Analyzes tokens (groups, character classes, quantifiers) and explains behavior.

### 3. SQL Formatter (`sql_formatter`)
- `format(sql)`: Formats standard SQL statements with indented clauses (SELECT, FROM, WHERE, JOIN, GROUP BY, ORDER BY).
- `validate(sql)`: Checks balanced quotes, parentheses, and common syntax structures.

### 4. Cron Designer (`cron_designer`)
- `explain(expression)`: Explains 5-part cron syntax in plain English.
- `build(frequency, time, days)`: Generates cron expression from structured parameters.
- `next_runs(expression, count)`: Calculates future timestamps based on expression.

### 5. Color Palette Gen (`color_palette_gen`)
- `from_hex(hex)`: Generates complementary, analogous, triadic, and monochromatic swatches.
- `contrast(hex1, hex2)`: Calculates relative luminance and WCAG 2.1 contrast ratio with AA/AAA compliance ratings.

### 6. File Converter (`file_converter`)
- `csv_to_json(csv_text)`: Converts CSV data with headers into JSON array of objects.
- `json_to_csv(json_text)`: Flattens JSON array of objects into CSV rows.

### 7. Markdown Editor (`markdown_editor`)
- `render_html(markdown)`: Renders markdown to HTML using existing `package:markdown`.
- `extract_toc(markdown)`: Extracts headers (H1-H6) with levels and slug anchors.
- `stats(markdown)`: Word count, character count, reading time estimate.

### 8. Password Vault (`password_vault`)
- `generate(length, uppercase, lowercase, numbers, symbols)`: Cryptographically secure random password generation (`dart:math` `Random.secure`).
- `store(key, secret)`: Securely stores secret in `FlutterSecureStorage`.
- `get(key)`: Retrieves secret by key.
- `list()`: Lists stored secret keys (without values).

### 9. Env Manager (`env_manager`)
- `parse(env_content)`: Parses `.env` key-value pairs with comment and quote support.
- `set(env_content, key, value)`: Updates or adds a variable while preserving surrounding lines.
- `merge(base_env, override_env)`: Merges two `.env` files with collision resolution.

### 10. Log Analyzer (`log_analyzer`)
- `parse(log_text)`: Categorizes entries by severity (FATAL, ERROR, WARN, INFO, DEBUG), finds error clusters.
- `filter(log_text, level, query)`: Filters log lines matching level and search substring.

### 11. API Tester (`api_tester`)
- `request(url, method, headers, body, timeout_seconds)`: Dispatches HTTP request using `http.Client`, returns status code, response headers, body, and elapsed duration.

### 12. Web Scraper Pro (`web_scraper_pro`)
- `extract(html, tag, attribute, contains_text)`: Pure-Dart regex/tokenizer DOM extraction of elements, links (`href`), images (`src`), or text blocks.

### 13. Prompt Library (`prompt_library`)
- `save(title, prompt, tags)`: Persists reusable prompt template.
- `get(title)`: Retrieves prompt.
- `list(tag)`: Lists saved prompts with optional tag filter.
- `delete(title)`: Deletes saved prompt.

### 14. DB Designer (`db_designer`)
- `generate_ddl(schema)`: Converts JSON table definition (columns, types, constraints, foreign keys) into PostgreSQL / SQLite DDL.
- `validate_schema(schema)`: Validates table dependencies, primary keys, and field types.

### 15. Web Clipper (`web_clipper`)
- `clip(url)`: Fetches target webpage, extracts title and readable body content, converts to markdown, and returns formatted document.

---

## 5. Verification Plan

1. **Unit Tests**:
   - `test/native_plugin_framework_test.dart`: Tests `NativePluginRegistry`, configuration persistence, secret isolation, and install routing.
   - `test/native_plugins_tools_test.dart`: Tests all 15 native plugin implementations with real input-output assertions.
2. **Integration Tests**:
   - `test/native_plugin_agent_test.dart`:
     - Verifies `AgentService._tools` contains `plugin__<slug>__*` tools when plugin is installed & enabled.
     - Verifies `executeTool` executes the capability and returns truthful formatted output.
     - Verifies `catalog_configure_plugin` dynamically sets configuration.
3. **Full Suite & Static Analysis**:
   - `dart analyze lib test` must report 0 issues.
   - `flutter test` must pass all existing and new tests.
