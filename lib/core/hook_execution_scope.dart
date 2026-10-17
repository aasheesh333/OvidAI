import 'dart:io';

import 'grant_store.dart';
import 'plugin_manifest.dart';

/// Invocation-local access to committed plugin content and its dependencies.
/// Registry activation is checked by HookService before constructing this.
class HookExecutionScope {
  static String? dependencyRoot(NormalizedPluginManifest? manifest) {
    if (manifest == null || !manifest.rootPath.startsWith('/')) return null;
    String segment(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._~-]'), '_');
    final version = segment(manifest.version);
    final safeVersion = version.isEmpty || version == '.' || version == '..'
        ? 'unversioned'
        : version;
    final suffix = [
      'plugin-runtime',
      ...manifest.id.split('/').map(segment),
      safeVersion,
      'content',
    ].join('/');
    final root = normalizeGrantPath(manifest.rootPath);
    if (!root.endsWith('/$suffix')) return null;
    return Directory(root).parent.path;
  }

}

/// Readiness failure: retry after provisioning, without consuming a breaker.
class HookRuntimeUnavailable implements Exception {
  const HookRuntimeUnavailable();

  @override
  String toString() => 'hook runtime unavailable; provision it and retry';
}

/// Environment names plugin-supplied env may never set (M1): a hook's
/// `CLAUDE_ENV_FILE` exports and a plugin-owned MCP server's env. Each one
/// steers which binaries, modules, libraries or credentials a process
/// resolves — `PATH`/`HOME`, `NODE_PATH`/`PYTHONPATH` module injection,
/// `LD_*`/`DYLD_*` preloads, `GIT_*` (e.g. `GIT_SSH_COMMAND`,
/// `GIT_CONFIG_*`) and `npm_config_*` (npm reads the prefix
/// case-insensitively, so the check does too).
bool isProtectedRuntimeEnvName(String name) {
  final upper = name.toUpperCase();
  for (final prefix in const ['LD_', 'DYLD_', 'GIT_', 'NPM_CONFIG_']) {
    if (upper.startsWith(prefix)) return true;
  }
  return const {
    'PATH',
    'HOME',
    'NODE_PATH',
    'NODE_OPTIONS',
    'PYTHONPATH',
    'PYTHONHOME',
    'PYTHONSTARTUP',
    'BASH_ENV',
    'ENV',
  }.contains(upper);
}
