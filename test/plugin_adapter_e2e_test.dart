import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';

/// Adapter-level E2E: run the REAL adapters against a synthetic
/// `obra/superpowers`-shaped tree (real repo cloned 2026-09-21 @ 5bf4e78,
/// v6.4.1). Covers the marketplace gaps hand-fixtures can't catch:
/// `.claude-plugin/plugin.json` with an object author, the matcher-group
/// `hooks.json` shape, `.codex-plugin/plugin.json` routing/identity, and
/// SSE degrading to optional instead of failing the install.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Minimal superpowers-shaped tree: Claude manifest (object author),
  /// one skill, the SessionStart matcher-group hook, and a Codex manifest.
  Directory makeSuperpowersTree() {
    final root = Directory.systemTemp.createTempSync('ovid-superpowers-e2e');
    Directory('${root.path}/.claude-plugin').createSync(recursive: true);
    File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': 'superpowers',
        'description': 'Core skills library for Claude Code',
        'version': '6.4.1',
        'author': {'name': 'Jesse Vincent', 'email': 'jesse@fsck.com'},
        'homepage': 'https://github.com/obra/superpowers',
        'license': 'MIT',
        'keywords': ['skills', 'tdd'],
      }),
    );
    Directory('${root.path}/skills/using-superpowers')
        .createSync(recursive: true);
    File('${root.path}/skills/using-superpowers/SKILL.md').writeAsStringSync(
      '---\nname: using-superpowers\n'
      'description: Use superpowers\n---\n\n# Using superpowers\n',
    );
    Directory('${root.path}/hooks').createSync(recursive: true);
    File('${root.path}/hooks/hooks.json').writeAsStringSync(
      jsonEncode({
        'hooks': {
          'SessionStart': [
            {
              'matcher': 'startup|clear|compact',
              'hooks': [
                {
                  'type': 'command',
                  'command': '"\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start',
                  'shell': 'bash',
                  'async': false,
                },
              ],
            },
          ],
        },
      }),
    );
    Directory('${root.path}/.codex-plugin').createSync(recursive: true);
    File('${root.path}/.codex-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': 'superpowers',
        'version': '6.4.1',
        'description': 'An agentic skills framework',
        'author': {'name': 'Jesse Vincent', 'email': 'jesse@fsck.com'},
        'skills': './skills/',
        'hooks': {},
      }),
    );
    return root;
  }

  /// Bare-bones Claude tree for focused hook-shape tests.
  Directory makeHookTree(Map<String, dynamic> hooksJson) {
    final root = Directory.systemTemp.createTempSync('ovid-hook-shape');
    Directory('${root.path}/.claude-plugin').createSync(recursive: true);
    File(
      '${root.path}/.claude-plugin/plugin.json',
    ).writeAsStringSync(jsonEncode({'name': 'hooktest', 'author': 'tester'}));
    Directory('${root.path}/hooks').createSync(recursive: true);
    File('${root.path}/hooks/hooks.json')
        .writeAsStringSync(jsonEncode(hooksJson));
    return root;
  }

  group('obra/superpowers tree shape', () {
    test('Claude adapter: identity, skills, SessionStart hook', () async {
      final root = makeSuperpowersTree();
      addTearDown(() => root.deleteSync(recursive: true));

      final m = await const ClaudePluginAdapter().inspect(root);

      expect(m.id, 'jesse-vincent/superpowers');
      expect(m.name, 'superpowers');
      expect(m.version, '6.4.1');
      expect(m.format, PluginFormat.claudeCode);
      expect(m.skills.map((s) => s.name), contains('using-superpowers'));

      final hook = m.hooks.singleWhere((h) => h.event == 'session_start');
      expect(hook.ordinal, 0);
      expect(hook.matcher, 'startup|clear|compact');
      expect(hook.payload, contains('CLAUDE_PLUGIN_ROOT'));
      // `shell: bash` is known and `async: false` needs no fire-and-forget.
      expect(
        m.compatibility.where(
          (i) => i.severity == CompatibilitySeverity.required,
        ),
        isEmpty,
      );
    });

    test(
      'registry prefers the Claude adapter when both manifests exist',
      () async {
        final root = makeSuperpowersTree();
        addTearDown(() => root.deleteSync(recursive: true));

        final m = await const PluginAdapterRegistry().inspect(root);

        expect(m.format, PluginFormat.claudeCode);
        expect(m.id, 'jesse-vincent/superpowers');
      },
    );

    test('registry routes a Codex-only tree to the Codex adapter', () async {
      final root = makeSuperpowersTree();
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/.claude-plugin').deleteSync(recursive: true);

      final m = await const PluginAdapterRegistry().inspect(root);

      expect(m.format, PluginFormat.codex);
      // Identity, version and the manifest `skills` pointer all come from
      // `.codex-plugin/plugin.json` — no config.toml involved.
      expect(m.id, 'jesse-vincent/superpowers');
      expect(m.version, '6.4.1');
      expect(m.skills.map((s) => s.name), contains('using-superpowers'));
    });
  });

  group('hook normalization', () {
    test('ordinals are per-event, not global', () async {
      final root = makeHookTree({
        'hooks': {
          'SessionStart': [
            {
              'matcher': '',
              'hooks': [
                {'type': 'command', 'command': 'echo a'},
              ],
            },
            {
              'matcher': '',
              'hooks': [
                {'type': 'command', 'command': 'echo b'},
              ],
            },
          ],
          'PreToolUse': [
            {
              'matcher': '',
              'hooks': [
                {'type': 'command', 'command': 'echo c'},
              ],
            },
          ],
        },
      });
      addTearDown(() => root.deleteSync(recursive: true));

      final m = await const ClaudePluginAdapter().inspect(root);

      final starts = [
        for (final h in m.hooks)
          if (h.event == 'session_start') h,
      ];
      final pres = [
        for (final h in m.hooks)
          if (h.event == 'pre_tool') h,
      ];
      expect([for (final h in starts) h.ordinal], [0, 1]);
      expect([for (final h in pres) h.ordinal], [0]);
    });

    test('single-map hook event value is wrapped, not dropped', () async {
      final root = makeHookTree({
        'hooks': {
          'SessionStart': {
            'matcher': 'startup',
            'hooks': [
              {'type': 'command', 'command': 'echo wrapped'},
            ],
          },
        },
      });
      addTearDown(() => root.deleteSync(recursive: true));

      final m = await const ClaudePluginAdapter().inspect(root);

      final hook = m.hooks.singleWhere((h) => h.event == 'session_start');
      expect(hook.payload, 'echo wrapped');
      expect(hook.matcher, 'startup');
    });

    test('unknown hook shell degrades with an optional note', () async {
      final root = makeHookTree({
        'hooks': {
          'SessionStart': [
            {
              'matcher': '',
              'hooks': [
                {
                  'type': 'command',
                  'command': 'echo hi',
                  'shell': 'powershell',
                },
              ],
            },
          ],
        },
      });
      addTearDown(() => root.deleteSync(recursive: true));

      final m = await const ClaudePluginAdapter().inspect(root);

      final notes = m.compatibility.where(
        (i) => i.message.contains('powershell'),
      );
      expect(notes, isNotEmpty);
      expect(
        notes.every((i) => i.severity == CompatibilitySeverity.optional),
        isTrue,
      );
    });
  });

  group('MCP transport parity', () {
    test(
      'SSE server is rejected as required (spec: SSE-only definitions fail)',
      () async {
        final root = Directory.systemTemp.createTempSync('ovid-sse-e2e');
        addTearDown(() => root.deleteSync(recursive: true));
        Directory('${root.path}/.claude-plugin').createSync(recursive: true);
        File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
          jsonEncode({'name': 'ssetest', 'author': 'tester'}),
        );
        File('${root.path}/.mcp.json').writeAsStringSync(
          jsonEncode({
            'mcpServers': {
              'legacy': {'type': 'sse', 'url': 'https://example.com/sse'},
            },
          }),
        );

        final m = await const ClaudePluginAdapter().inspect(root);

        final sseNotes = m.compatibility.where(
          (i) => i.fields.any((f) => f.contains('legacy')),
        );
        expect(sseNotes, isNotEmpty);
        expect(
          sseNotes.every((i) => i.severity == CompatibilitySeverity.required),
          isTrue,
        );
        expect(
          sseNotes.every((i) => i.message.contains('Streamable HTTP')),
          isTrue,
        );
      },
    );
  });

  group('manifest shape hardening', () {
    test(
      'non-string/non-map author degrades to a required issue, never throws',
      () async {
        for (final author in [
          ['a', 'b'],
          42,
          true,
        ]) {
          final root = Directory.systemTemp.createTempSync('ovid-author-shape');
          addTearDown(() => root.deleteSync(recursive: true));
          Directory('${root.path}/.claude-plugin').createSync(recursive: true);
          File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
            jsonEncode({'name': 'authortest', 'author': author}),
          );

          final m = await const ClaudePluginAdapter().inspect(root);

          expect(
            m.compatibility.any(
              (i) =>
                  i.severity == CompatibilitySeverity.required &&
                  i.message.contains('publisher'),
            ),
            isTrue,
          );
        }
      },
    );

    test('numeric Codex version is stringified, not cast-thrown', () async {
      final root = Directory.systemTemp.createTempSync('ovid-version-shape');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/.codex-plugin').createSync(recursive: true);
      File('${root.path}/.codex-plugin/plugin.json').writeAsStringSync(
        jsonEncode({'name': 'versiontest', 'version': 2, 'author': 'tester'}),
      );

      final m = await const CodexPluginAdapter().inspect(root);

      expect(m.version, '2');
    });

    test('Codex skills pointer cannot escape the plugin tree', () async {
      final root = Directory.systemTemp.createTempSync('ovid-pointer-escape');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/.codex-plugin').createSync(recursive: true);
      File('${root.path}/.codex-plugin/plugin.json').writeAsStringSync(
        jsonEncode({
          'name': 'pointertest',
          'author': 'tester',
          'skills': '../outside',
        }),
      );

      final m = await const CodexPluginAdapter().inspect(root);

      expect(m.skills, isEmpty);
    });
  });
}
