import 'package:flutter/foundation.dart';

import 'diag.dart';
import 'native_plugin.dart';
import 'plugin_registry.dart';

/// Plugin `userConfig` parity: the values a user saves in a plugin's
/// Settings form reach the plugin the way Claude Code passes them —
///   • exported to the plugin's processes (MCP servers, hooks) as
///     `CLAUDE_PLUGIN_OPTION_<KEY>` environment variables, and
///   • substituted for `${user_config.<key>}` in the plugin's MCP server
///     args, url and headers (hook commands reference the env variable, so
///     a value is never spliced into a shell string).
///
/// Values are read from [NativePluginConfigStore] under the plugin's
/// runtime id — the same namespace the Settings panel writes.

/// Test seam: replaces the stored-value lookup for a plugin id.
@visibleForTesting
Future<Map<String, String>> Function(String pluginId)?
pluginUserConfigReaderForTest;

/// Saved settings for [pluginId] keyed by field key (empty values dropped).
Future<Map<String, String>> pluginUserConfigValues(String pluginId) async {
  final override = pluginUserConfigReaderForTest;
  try {
    final Map<String, String> raw;
    if (override != null) {
      raw = await override(pluginId);
    } else {
      final fields = PluginContributionRegistry.I.settingsFieldsForPlugin(
        pluginId,
      );
      if (fields.isEmpty) return const {};
      raw = await NativePluginConfigStore.I.readAll(
        pluginName: pluginId,
        fields: [
          for (final f in fields)
            NativePluginConfigField(
              key: f.key,
              label: f.label.isEmpty ? f.key : f.label,
              secret: f.secret,
            ),
        ],
      );
    }
    return {
      for (final e in raw.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
  } catch (e) {
    Diag.swallow('plugin_user_config', e);
    return const {};
  }
}

/// Env variable name for one setting key: `CLAUDE_PLUGIN_OPTION_<KEY>`,
/// upper-cased with every non-alphanumeric run folded to `_`.
String pluginOptionEnvName(String key) {
  final k = key
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return 'CLAUDE_PLUGIN_OPTION_$k';
}

/// `CLAUDE_PLUGIN_OPTION_<KEY>` env for the given saved [values].
Map<String, String> pluginOptionEnv(Map<String, String> values) => {
  for (final e in values.entries) pluginOptionEnvName(e.key): e.value,
};

/// Convenience: the option env for [pluginId] (empty when it saved none).
Future<Map<String, String>> pluginOptionEnvFor(String? pluginId) async {
  if (pluginId == null || pluginId.isEmpty) return const {};
  return pluginOptionEnv(await pluginUserConfigValues(pluginId));
}

final _userConfigRef = RegExp(r'\$\{user_config\.([A-Za-z0-9_.\-]+)\}');

/// Replaces `${user_config.<key>}` with the saved value. Unknown keys are
/// left as-is so a missing setting stays visible instead of turning into
/// an empty string.
String substituteUserConfig(String input, Map<String, String> values) {
  if (!input.contains(r'${user_config.')) return input;
  return input.replaceAllMapped(
    _userConfigRef,
    (m) => values[m.group(1)!] ?? m.group(0)!,
  );
}

/// Rewrites `${user_config.<key>}` in a hook shell command to the matching
/// `${CLAUDE_PLUGIN_OPTION_<KEY>}` variable, which the hook env exports.
/// The shell expands it, so a value is never spliced into the command.
String rewriteUserConfigRefsForShell(String command) {
  if (!command.contains(r'${user_config.')) return command;
  return command.replaceAllMapped(
    _userConfigRef,
    (m) => '\${${pluginOptionEnvName(m.group(1)!)}}',
  );
}
