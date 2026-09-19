import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/skills.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ovid-skills-parse-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void write(String relative, String body) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
  }

  File writeBytes(String relative, List<int> bytes) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  Future<Skill?> parse(String relative, String body) async {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
    return SkillService.forTest().parseForTest(file, file.path);
  }

  group('readSupportingFile', () {
    Future<Skill> discoveredBundle() async {
      write('bundle/SKILL.md', '---\nname: bundled\n---\nBODY\n');
      write('bundle/templates/report.md', 'REPORT TEMPLATE');
      write('bundle/scripts/run.sh', 'echo hi');
      final service = SkillService.forTest();
      service.addRoot(root.path);
      await service.reload();
      return service.find('bundled')!;
    }

    test('reads a supporting file relative to the skill directory', () async {
      final service = SkillService.forTest();
      final skill = await discoveredBundle();

      expect(
        await service.readSupportingFile(skill, 'templates/report.md'),
        'REPORT TEMPLATE',
      );
      expect(
        await service.readSupportingFile(skill, 'scripts/run.sh'),
        'echo hi',
      );
    });

    test('supportingFilesFor lists the bundle files', () async {
      final service = SkillService.forTest();
      final skill = await discoveredBundle();

      expect(service.supportingFilesFor(skill), [
        'scripts/run.sh',
        'templates/report.md',
      ]);
    });

    test('rejects parent traversal and absolute paths', () async {
      write('outside.txt', 'OUTSIDE');
      final service = SkillService.forTest();
      final skill = await discoveredBundle();

      expect(await service.readSupportingFile(skill, '../outside.txt'), isNull);
      expect(
        await service.readSupportingFile(skill, 'templates/../../outside.txt'),
        isNull,
      );
      expect(await service.readSupportingFile(skill, '/etc/hostname'), isNull);
      expect(
        await service.readSupportingFile(skill, 'C:/windows/win.ini'),
        isNull,
      );
    });

    test('rejects a symlink that escapes the skill directory', () async {
      final outside = File('${root.path}/outside-secret.txt')
        ..writeAsStringSync('SECRET');
      final skillDir = Directory('${root.path}/bundle')..createSync();
      write('bundle/SKILL.md', '---\nname: bundled\n---\nBODY\n');
      final link = Link('${skillDir.path}/escape.txt')
        ..createSync(outside.path);
      expect(link.existsSync(), isTrue);
      final service = SkillService.forTest();
      service.addRoot(root.path);
      await service.reload();
      final skill = service.find('bundled')!;

      expect(await service.readSupportingFile(skill, 'escape.txt'), isNull);
    });

    test('truncates oversized content with an honest note', () async {
      final oversized = List<int>.filled(kSupportingFileMaxBytes + 2048, 0x61);
      write('bundle/SKILL.md', '---\nname: bundled\n---\nBODY\n');
      writeBytes('bundle/big.txt', oversized);
      final service = SkillService.forTest();
      service.addRoot(root.path);
      await service.reload();
      final skill = service.find('bundled')!;

      final result = await service.readSupportingFile(skill, 'big.txt');

      expect(result, isNotNull);
      expect(result!.startsWith('a' * 100), isTrue);
      expect(
        result,
        contains(
          '[truncated: showing first $kSupportingFileMaxBytes of ${oversized.length} bytes]',
        ),
      );
    });

    test(
      'returns null for a missing file or a skill without a directory',
      () async {
        final service = SkillService.forTest();
        final skill = await discoveredBundle();

        expect(await service.readSupportingFile(skill, 'nope.txt'), isNull);
        final inMemory = Skill(
          name: 'memory',
          description: '',
          whenToUse: '',
          content: 'BODY',
          path: '/tmp/memory.md',
          modelInvocable: true,
          userInvocable: true,
        );
        expect(
          await service.readSupportingFile(inMemory, 'anything.txt'),
          isNull,
        );
      },
    );
  });

  group('root .md allowlist', () {
    test('skips known documentation files at a scanned root', () async {
      write('AGENTS.md', '---\nname: agents-doc\n---\nAGENTS');
      write('README.md', '---\nname: readme-doc\n---\nREADME');
      write('CHANGELOG.md', '---\nname: changelog-doc\n---\nCHANGELOG');
      write(
        'CONTRIBUTING.md',
        '---\nname: contributing-doc\n---\nCONTRIBUTING',
      );
      write('CODE_OF_CONDUCT.md', '---\nname: conduct-doc\n---\nCONDUCT');
      write('LICENSE.md', '---\nname: license-doc\n---\nLICENSE');
      write('SECURITY.md', '---\nname: security-doc\n---\nSECURITY');
      write('custom-skill.md', '---\nname: custom-skill\n---\nCUSTOM');

      final service = SkillService.forTest();
      service.addRoot(root.path);
      await service.reload();

      expect(service.skills.map((s) => s.name), ['custom-skill']);
    });

    test('still discovers bundle SKILL.md and AGENT.md at the root', () async {
      write('bundle/SKILL.md', '---\nname: bundle-skill\n---\nBUNDLE');
      write('persona/AGENT.md', '---\nname: persona-agent\n---\nAGENT');

      final service = SkillService.forTest();
      service.addRoot(root.path);
      await service.reload();

      expect(service.skills.map((s) => s.name).toSet(), {
        'bundle-skill',
        'persona-agent',
      });
    });

    test('nested markdown below the root is still discovered', () async {
      write('notes/README.md', '---\nname: nested-note\n---\nNESTED');

      final service = SkillService.forTest();
      service.addRoot(root.path);
      await service.reload();

      expect(service.skills.map((s) => s.name), ['nested-note']);
    });
  });

  group('frontmatter parsing', () {
    test('folded block scalar joins indented lines with spaces', () async {
      final skill = await parse(
        'fold.md',
        '---\nname: fold\ndescription: >\n  Cut a release\n  with care.\n---\nBODY\n',
      );

      expect(skill!.description, 'Cut a release with care.');
    });

    test('literal block scalar preserves newlines', () async {
      final skill = await parse(
        'literal.md',
        '---\nname: literal\ndescription: |\n  line one\n  line two\n---\nBODY\n',
      );

      expect(skill!.description, 'line one\nline two');
    });

    test('block list allowed-tools parses each item', () async {
      final skill = await parse(
        'tools.md',
        '---\nname: tools\nallowed-tools:\n  - Read\n  - Bash\n---\nBODY\n',
      );

      expect(skill!.allowedTools, ['Read', 'Bash']);
    });

    test('inline comma and bracket allowed-tools still parse', () async {
      final skill = await parse(
        'inline.md',
        '---\nname: inline\nallowed-tools: [run_shell, file_read]\n---\nBODY\n',
      );

      expect(skill!.allowedTools, ['run_shell', 'file_read']);
    });

    test('quoted values and values containing colons are preserved', () async {
      final skill = await parse(
        'quoted.md',
        '---\nname: "Hindi Translator"\ndescription: "a: b"\nwhenToUse: use when: needed\n---\nBODY\n',
      );

      expect(skill!.name, 'Hindi Translator');
      expect(skill.description, 'a: b');
      expect(skill.whenToUse, 'use when: needed');
      expect(skill.frontmatter['description'], 'a: b');
    });
  });
}
