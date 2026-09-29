import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/plugin_adapters.dart';

/// Claude Code plugin.json parity gaps closed 2026-09-25 (audit):
///  * command/agent names are namespaced by their sub-directory, so
///    `commands/git/commit.md` and `commands/svn/commit.md` no longer collide;
///  * a `plugin.json` `hooks` STRING value is a file pointer, not a directory;
///  * a `mcpServers` STRING value points at a `.mcp.json` file;
///  * `commands`/`skills`/`agents` may be an ARRAY of directory pointers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory tree() {
    final r = Directory.systemTemp.createTempSync('ovid-cc-parity-');
    addTearDown(() {
      if (r.existsSync()) r.deleteSync(recursive: true);
    });
    Directory('${r.path}/.claude-plugin').createSync(recursive: true);
    return r;
  }

  void manifest(Directory r, Map<String, dynamic> j) {
    File('${r.path}/.claude-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': 'parity',
        'version': '1.0.0',
        'author': {'name': 'T', 'email': 't@t.com'},
        ...j,
      }),
    );
  }

  void cmd(Directory r, String relPath, {String? name}) {
    final f = File('${r.path}/$relPath');
    f.parent.createSync(recursive: true);
    final fm = name == null ? '' : 'name: $name\n';
    f.writeAsStringSync('---\n${fm}description: c\n---\n\n# body\n');
  }

  test('commands in sub-directories do not collide', () async {
    final r = tree();
    manifest(r, {});
    cmd(r, 'commands/git/commit.md');
    cmd(r, 'commands/svn/commit.md');
    cmd(r, 'commands/top.md');

    final m = await const ClaudePluginAdapter().inspect(r);
    final names = m.commands.map((c) => c.name).toSet();

    // Both `commit` files survive, namespaced by their directory.
    expect(names, containsAll(['git-commit', 'svn-commit', 'top']));
    expect(m.commands.length, 3, reason: 'no command silently dropped');
  });

  test('plugin.json "hooks" string is a FILE pointer', () async {
    final r = tree();
    manifest(r, {'hooks': './config/my-hooks.json'});
    File('${r.path}/config/my-hooks.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'hooks': {
          'PreToolUse': [
            {
              'matcher': 'Edit',
              'hooks': [
                {'type': 'command', 'command': 'echo hi', 'shell': 'bash'},
              ],
            },
          ],
        },
      }));

    final m = await const ClaudePluginAdapter().inspect(r);
    expect(m.hooks, isNotEmpty,
        reason: 'hooks at a custom file path must load, not be dropped');
    expect(m.hooks.first.event, 'pre_tool');
  });

  test('plugin.json "mcpServers" string points at a .mcp.json file', () async {
    final r = tree();
    manifest(r, {'mcpServers': './servers.json'});
    File('${r.path}/servers.json').writeAsStringSync(jsonEncode({
      'mcpServers': {
        'remote': {'type': 'http', 'url': 'https://mcp.example.com'},
      },
    }));

    final m = await const ClaudePluginAdapter().inspect(r);
    expect(m.mcpServers.map((s) => s.name), contains('remote'));
  });

  test('"commands" may be an array of directory pointers', () async {
    final r = tree();
    manifest(r, {
      'commands': ['./extra-a', './extra-b'],
    });
    cmd(r, 'extra-a/one.md');
    cmd(r, 'extra-b/two.md');

    final m = await const ClaudePluginAdapter().inspect(r);
    final names = m.commands.map((c) => c.name).toSet();
    expect(names, containsAll(['one', 'two']));
  });
}
