import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';

/// Codex plugin contributions (2026-09-24).
///
/// The Codex adapter scanned only `.agents/skills` and `.agents/personas`, while
/// the Claude adapter also scanned the plain top-level `commands/`, `agents/` and
/// `skills/` directories. A Codex tree using that layout therefore contributed
/// NOTHING — no commands, no agents — while an identical Claude tree worked.
/// That is most of what "Codex plugins don't work" actually meant.
///
/// Separately, `_parseCodexInlineHooks` had ZERO tests and its header regex only
/// accepted bare identifiers, so the legal TOML spelling `[[hooks."SessionStart"]]`
/// was silently skipped.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('codex-tree-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void write(String rel, String body) {
    final f = File('${root.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  /// A Codex-only tree: no `.claude-plugin/`, so the registry routes it to
  /// [CodexPluginAdapter].
  void writeCodexTree({required String hooksToml}) {
    write('config.toml', '''
name = "acme-toolkit"
version = "1.2.3"

$hooksToml
''');
    write('.codex-plugin/plugin.json', '''
{"name": "Acme Toolkit", "publisher": {"name": "acme"}, "version": "1.2.3"}
''');
    write('commands/lint.md', '---\nname: lint\n---\nRun the linter.');
    write('agents/tester.md', '---\nname: tester\n---\nYou test things.');
    write('skills/greet/SKILL.md', '---\nname: greet\n---\nSay hello.');
    write('.agents/skills/legacy/SKILL.md', '---\nname: legacy\n---\nOld layout.');
  }

  group('the plain (non-dotted) layout contributes like Claude does', () {
    test('top-level commands, agents and skills are all picked up', () async {
      writeCodexTree(hooksToml: '');
      final m = await const PluginAdapterRegistry().inspect(root);

      expect(m.format, PluginFormat.codex);
      expect(m.commands.map((c) => c.name), contains('lint'));
      expect(m.agents.map((a) => a.name), contains('tester'));
      expect(m.skills.map((s) => s.name), containsAll(['greet', 'legacy']));
    });

    test('the pre-existing .agents layout still works', () async {
      writeCodexTree(hooksToml: '');
      write('.agents/personas/reviewer.md', '---\nname: reviewer\n---\nReview.');
      final m = await const PluginAdapterRegistry().inspect(root);

      expect(m.agents.map((a) => a.name), containsAll(['tester', 'reviewer']));
    });
  });

  // NOTE (2026-09-24): `_parseCodexInlineHooks` was hardened here — its header
  // regex now accepts the legal TOML quoted spelling `[[hooks."SessionStart"]]`
  // and hyphenated event names, where before it matched only bare
  // `[A-Za-z0-9_]+` and silently skipped everything else. End-to-end coverage of
  // that parser is recorded as REMAINING WORK in the design doc: an inspection of
  // a minimal Codex tree produced no `PluginHook`s even for the bare spelling the
  // old regex already accepted, so there is a second defect downstream of the
  // header match that needs its own investigation. This is stated rather than
  // papered over with a passing assertion.
}
