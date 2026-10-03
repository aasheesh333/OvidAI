import 'dart:io';

import 'grant_store.dart';
import 'plugin_manifest.dart';
import 'sandbox_service.dart';

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

  static SandboxRootScope roots({
    required NormalizedPluginManifest? manifest,
    required Directory workspace,
    required Map<String, String> env,
    Object? inherited,
  }) {
    final runtime = dependencyRoot(manifest);
    final paths = <String>[
      workspace.path,
      if (manifest != null) manifest.rootPath,
      if (runtime != null)
        for (final sub in ['node', 'python', 'bin', 'cache', 'storage'])
          '$runtime/$sub',
      env['PLUGIN_STORAGE'] ?? '',
    ];
    final envFile = env['CLAUDE_ENV_FILE'] ?? '';
    return SandboxRootScope(
      paths.where(
        (path) => path.startsWith('/') && normalizeGrantPath(path) != '/',
      ),
      // An enclosing session denial still wins; unrelated allowed roots do not
      // become plugin permissions.
      decisions: [
        if (envFile.startsWith('/') && normalizeGrantPath(envFile) != '/')
          PermissionGrant.path(envFile, recursive: false),
        if (inherited is SandboxRootScope)
          ...inherited.decisions.where((decision) => decision.isDeny),
      ],
    );
  }
}

/// Readiness failure: retry after provisioning, without consuming a breaker.
class HookRuntimeUnavailable implements Exception {
  const HookRuntimeUnavailable();

  @override
  String toString() => 'hook runtime unavailable; provision it and retry';
}
