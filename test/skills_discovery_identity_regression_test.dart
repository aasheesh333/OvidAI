import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/skills.dart';

void main() {
  late Directory root;
  late SkillService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('skills-identity-');
    service = SkillService.forTest();
  });
  tearDown(() => root.deleteSync(recursive: true));

  File write(String path, String body) {
    final file = File('${root.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
    return file;
  }

  test('unnamed contribution uses bundle directory, not SKILL filename', () async {
    final file = write('review/SKILL.md', 'Review the changed files.');
    final skill = await service.parseContributionFile(file);
    expect(skill!.name, 'review');
    expect(skill.content, 'Review the changed files.');
  });

  test('overlapping roots do not make one session skill ambiguous', () async {
    write('.agents/skills/review/SKILL.md', 'Review the changed files.');
    await service.publishSessionCatalog('a', roots: [
      '${root.path}/.agents/skills',
      '${root.path}/.agents',
    ]);
    final resolution = service.resolveForSession('a', 'review');
    expect(resolution.isUnique, isTrue);
    expect(resolution.unique!.content, 'Review the changed files.');
    expect(service.skillsForSession('b'), isEmpty);
  });

  test('compatibility catalog also deduplicates overlapping roots', () async {
    write('.agents/skills/review/SKILL.md', 'Review the changed files.');
    service.addRoot('${root.path}/.agents/skills');
    service.addRoot('${root.path}/.agents');
    await service.reload();
    expect(service.resolveAlias('review').isUnique, isTrue);
  });

  test('distinct files with the same name still require disambiguation', () async {
    write('one/review/SKILL.md', 'First instructions.');
    write('two/review/SKILL.md', 'Second instructions.');
    await service.publishSessionCatalog('a', roots: [root.path]);
    final resolution = service.resolveForSession('a', 'review');
    expect(resolution.isAmbiguous, isTrue);
    expect(resolution.options, hasLength(2));
  });
}
