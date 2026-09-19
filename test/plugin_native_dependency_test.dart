import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/plugin_dependency_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';

/// A plugin npm dependency that needs a native addon cannot run on Android:
/// the platform is bionic (not glibc), a prebuilt Linux `.node` cannot load,
/// and `node-gyp` has no Android target. The failure must say that plainly
/// instead of surfacing a raw gyp stack the user cannot act on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory runtimeRoot;

  setUp(() {
    runtimeRoot = Directory.systemTemp.createTempSync('ovid-natdep-');
  });

  tearDown(() {
    if (runtimeRoot.existsSync()) runtimeRoot.deleteSync(recursive: true);
  });

  Future<PluginDependencyResult> installWith(
    Future<(int, String)> Function(List<String>, {String? cwd, Map<String, String>? env}) runner,
  ) {
    final svc = PluginDependencyService(
      runtimeRootOverride: runtimeRoot,
      runner: runner,
      ensureRuntime: (_) async => true,
    );
    final manifest = NormalizedPluginManifest(
      id: 'acme/native-dep',
      name: 'native-dep',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: runtimeRoot.path,
      dependencies: const PluginDependencies(
        packages: [
          PluginDependency(name: 'sharp', required: true),
        ],
      ),
    );
    return svc.install(manifest, null);
  }

  test('a node-gyp failure names the Android/bionic limitation', () async {
    final result = await installWith((args, {cwd, env}) async {
      return (
        1,
        'gyp ERR! stack Error: not found: make\n'
            'node-gyp rebuild failed',
      );
    });
    final entry = result.entries.single;
    expect(entry.status, PluginDependencyStatus.failed);
    expect(entry.error, isNotNull);
    expect(entry.error!.toLowerCase(), contains('native addon'));
    expect(entry.error, contains('Android'));
  });

  test('a prebuilt-ELF failure is also explained', () async {
    final result = await installWith((args, {cwd, env}) async {
      return (1, 'Error: invalid ELF header (prebuild-install)');
    });
    expect(result.entries.single.error, contains('native addon'));
  });

  test('an ordinary npm failure keeps its raw tail', () async {
    final result = await installWith((args, {cwd, env}) async {
      return (1, 'npm ERR! 404 Not Found - GET https://registry/pkg');
    });
    final err = result.entries.single.error!;
    expect(err.toLowerCase(), isNot(contains('native addon')));
    expect(err, contains('404'));
  });
}
