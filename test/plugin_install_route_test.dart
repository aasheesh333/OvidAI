import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

class _TestNativeCapability implements NativePluginCapability {
  @override
  final String pluginName;
  _TestNativeCapability(this.pluginName);

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async =>
      'ok:$toolName';
}

/// Install-button routing: every catalog row must resolve to a REAL install
/// path. The add-sheet is only for the explicit + button — tapping Install
/// on a row must never open it as a surprise.
void main() {
  setUp(() {
    NativePluginRegistry.I.clearForTest();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  PluginItem row({
    String? source,
    String author = 'ovidai',
    String name = 'Test Row',
  }) => PluginItem(
    name: name,
    author: author,
    description: 'test',
    version: '1.0.0',
    category: 'Tool',
    source: source,
  );

  test('GitHub owner/repo routes to source install', () {
    final route = pluginInstallRouteForTest(row(source: 'acme/widgets'));
    expect(route.kind, PluginInstallKind.githubSource);
    expect(route.github?.owner, 'acme');
    expect(route.github?.repo, 'widgets');
  });

  test('marketplace:owner/repo routes to source install, not a bogus repo',
      () {
    final route = pluginInstallRouteForTest(
      row(source: 'marketplace:acme/widgets'),
    );
    expect(route.kind, PluginInstallKind.githubSource);
    expect(route.github?.owner, 'acme');
    expect(route.github?.repo, 'widgets');
  });

  test('source-less inbuilt row with real backing installs directly', () {
    expect(
      pluginInstallRouteForTest(row(name: 'Web Search')).kind,
      PluginInstallKind.builtinDirect,
    );
  });

  test('source-less inbuilt row without backing is unsupported', () {
    expect(
      pluginInstallRouteForTest(row(name: 'Git Workbench')).kind,
      PluginInstallKind.unsupported,
    );
  });

  test('source-less non-inbuilt row is unsupported, never the add sheet', () {
    final route = pluginInstallRouteForTest(row(author: 'community'));
    expect(route.kind, PluginInstallKind.unsupported);
  });

  test('unparseable source is unsupported, never the add sheet', () {
    final route = pluginInstallRouteForTest(
      row(source: 'justaword', author: 'community'),
    );
    expect(route.kind, PluginInstallKind.unsupported);
  });

  test('registered native capability routes to nativeCapability', () {
    NativePluginRegistry.I.register(
      _TestNativeCapability('JSON Visualizer'),
    );
    final route = pluginInstallRouteForTest(row(name: 'JSON Visualizer'));
    expect(route.kind, PluginInstallKind.nativeCapability);
  });

  test('unregistered source-less plugin still routes to unsupported', () {
    final route = pluginInstallRouteForTest(row(name: 'JSON Visualizer'));
    expect(route.kind, PluginInstallKind.unsupported);
  });

  group('a row that can never install shows no Install button', () {
    // WS4 honesty (audit 2026-09-25): "MCP Server Hub" and "Voice Input" are
    // source-less inbuilt rows with no executable backing, so Install routed to
    // `unsupported` and tapped into "add its repo with the + button" — advice
    // that cannot work, because they HAVE no repo. The row must not look
    // installable in the first place.
    test('source-less inbuilt row without backing is uninstallable', () {
      expect(inbuiltUninstallableForTest(row(name: 'Git Workbench')), isTrue);
      expect(inbuiltUninstallableForTest(row(name: 'MCP Server Hub')), isTrue);
      expect(inbuiltUninstallableForTest(row(name: 'Voice Input')), isTrue);
    });

    test('a row WITH a repo stays installable (the advice is actionable)', () {
      expect(
        inbuiltUninstallableForTest(row(source: 'justaword', author: 'community')),
        isFalse,
        reason: 'its source is unparseable, but "add its repo" still applies',
      );
      expect(inbuiltUninstallableForTest(row(source: 'acme/widgets')), isFalse);
    });

    test('a row with real backing is not uninstallable', () {
      NativePluginRegistry.I.register(_TestNativeCapability('JSON Visualizer'));
      expect(inbuiltUninstallableForTest(row(name: 'JSON Visualizer')), isFalse);
    });
  });
}
