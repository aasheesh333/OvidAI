import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

NormalizedPluginManifest _manifest(String id, PluginFormat format) =>
    NormalizedPluginManifest(
      id: id,
      name: id,
      version: '1.0.0',
      format: format,
      rootPath: '/plugins/$id',
    );

PluginItem _row({
  String? runtimeId,
  String? source,
  String? marketplace,
  String category = 'Tool',
  String author = 'acme',
}) => PluginItem(
  name: 'Row',
  author: author,
  description: '',
  version: '1.0.0',
  category: category,
  source: source,
  marketplace: marketplace,
  runtimeId: runtimeId,
);

void _register(NormalizedPluginManifest manifest) {
  PluginContributionRegistry.I.register(
    manifest,
    activation: PluginActivation.globalActive,
  );
  addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(manifest.id));
}

void main() {
  test('codex runtime manifest overrides the catalog Claude Code heuristic', () {
    final manifest = _manifest('acme/codex', PluginFormat.codex);
    _register(manifest);
    final row = _row(runtimeId: manifest.id, source: 'acme/repo');
    expect(PluginCard.sourceFormatLabel(row), 'Codex');
  });

  test('claudeCode runtime manifest shows Claude Code even when catalog reads Codex', () {
    final manifest = _manifest('acme/cc', PluginFormat.claudeCode);
    _register(manifest);
    final row = _row(runtimeId: manifest.id);
    expect(PluginCard.sourceFormatLabel(row), 'Claude Code');
  });

  test('genericMcp runtime manifest shows MCP', () {
    final manifest = _manifest('acme/mcp', PluginFormat.genericMcp);
    _register(manifest);
    final row = _row(runtimeId: manifest.id);
    expect(PluginCard.sourceFormatLabel(row), 'MCP');
  });

  test('catalog heuristic is preserved when no runtime manifest exists', () {
    expect(
      PluginCard.sourceFormatLabel(_row(source: 'acme/repo')),
      'Claude Code',
    );
    expect(
      PluginCard.sourceFormatLabel(_row(author: 'ovidai')),
      'Ovid built-in',
    );
    expect(PluginCard.sourceFormatLabel(_row(category: 'MCP')), 'MCP');
    expect(PluginCard.sourceFormatLabel(_row()), 'Codex');
  });

  test('runtimeId without a registered manifest falls back to catalog', () {
    expect(
      PluginCard.sourceFormatLabel(
        _row(runtimeId: 'acme/missing', source: 'acme/repo'),
      ),
      'Claude Code',
    );
  });

  test('formatLabelFor maps every runtime format to its badge', () {
    expect(PluginCard.formatLabelFor(PluginFormat.codex, 'Claude Code'), 'Codex');
    expect(PluginCard.formatLabelFor(PluginFormat.claudeCode, 'Codex'), 'Claude Code');
    expect(PluginCard.formatLabelFor(PluginFormat.genericMcp, 'Codex'), 'MCP');
    expect(PluginCard.formatLabelFor(null, 'Ovid built-in'), 'Ovid built-in');
  });
}
