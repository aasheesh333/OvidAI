// Task 1 (Plugins/MCP UI Contraction, spec §5.1): the install source
// chooser is GitHub-only. Source-level contract (no non-GitHub routes or
// file-picker seams) + widget-level behavior (sheet shows the GitHub
// field/button only).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

String _pluginsScreenSource() =>
    File('lib/ui/plugins_screen.dart').readAsStringSync();

/// The `showPluginSourceChooser` function body: from its declaration to
/// the `_githubSourceFromInput` helper that follows it.
String _chooserBody(String src) {
  final start = src.indexOf('Future<void> showPluginSourceChooser');
  assert(start >= 0, 'showPluginSourceChooser not found');
  final end = src.indexOf(
    'GithubPluginSource? _githubSourceFromInput',
    start,
  );
  assert(end > start, 'chooser body end marker not found');
  return src.substring(start, end);
}

void main() {
  group('GitHub-only plugin install UI', () {
    test('chooser keeps the GitHub route', () {
      final src = _pluginsScreenSource();
      final chooser = _chooserBody(src);
      expect(chooser, contains('_githubSourceFromInput'));
      expect(chooser, contains('_runSourceInstall'));
      expect(chooser, contains('Fetch from GitHub'));
      expect(chooser, contains('owner/repo'));
      // GitHub-only header copy (no "every source" wording).
      expect(chooser, contains('Install plugin from GitHub'));
      expect(chooser, isNot(contains('Every source is inspected')));
      // File-picker seams are gone from the whole file.
      expect(src, isNot(contains('pluginPickDirectoryForTest')));
      expect(src, isNot(contains('pluginPickZipFileForTest')));
      expect(src, isNot(contains('FilePicker')));
    });

    test('chooser has no non-GitHub routes', () {
      final chooser = _chooserBody(_pluginsScreenSource());
      expect(chooser, isNot(contains('Local folder')));
      expect(chooser, isNot(contains('ZIP archive')));
      expect(chooser, isNot(contains('Install from npm')));
      expect(chooser, isNot(contains('Inspect pasted config')));
      expect(chooser, isNot(contains('Add MCP server')));
      expect(chooser, isNot(contains('PASTE MCP CONFIG')));
      expect(chooser, isNot(contains('DIRECT MCP SERVER')));
      expect(chooser, isNot(contains('LocalFolderPluginSource')));
      expect(chooser, isNot(contains('ZipPluginSource')));
      expect(chooser, isNot(contains('NpmPluginSource')));
      expect(chooser, isNot(contains('PastedConfigPluginSource')));
      expect(chooser, isNot(contains('DirectMcpPluginSource')));
    });

    testWidgets('chooser sheet shows the GitHub field/button only', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showPluginSourceChooser(ctx),
                child: const Text('open chooser'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open chooser'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Fetch from GitHub'), findsOneWidget);
      expect(
        find.text('owner/repo or https://github.com/owner/repo'),
        findsOneWidget,
      );
      expect(find.text('Local folder'), findsNothing);
      expect(find.text('ZIP archive'), findsNothing);
      expect(find.text('Install from npm'), findsNothing);
      expect(find.text('Inspect pasted config'), findsNothing);
      expect(find.text('Add MCP server'), findsNothing);
    });
  });
}
