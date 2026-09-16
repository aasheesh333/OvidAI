import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

/// Install-button routing: every catalog row must resolve to a REAL install
/// path. The add-sheet is only for the explicit + button — tapping Install
/// on a row must never open it as a surprise.
void main() {
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
}
