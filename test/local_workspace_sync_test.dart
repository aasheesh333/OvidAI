import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final cache = RepoCache.I;

  setUp(() {
    root = Directory.systemTemp.createTempSync('local-sync-');
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.setSessionWorkspaceFolder(root.path);
    cache.bind('o/r', '', sessionId: app.activeSession!.id,
      workspaceFolder: root.path);
  });
  tearDown(() {
    cache.unbind();
    AppState.resetTestInstance();
    root.deleteSync(recursive: true);
  });

  test('local sync caps fetched files and reports the incomplete traversal', () async {
    for (var i = 0; i < 20; i++) {
      File('${root.path}/$i.txt').writeAsStringSync('$i');
    }
    final report = await cache.sync(maxFiles: 2);
    expect(cache.files.length, 2);
    expect(report.fetched, 2);
    expect(report.partial, isTrue);
  });

  test('expired local sync deadline does not read files', () async {
    File('${root.path}/a.txt').writeAsStringSync('disk');
    final report = await cache.sync(deadline: Duration.zero);
    expect(report.fetched, 0);
    expect(report.deadlineExceeded, isTrue);
    expect(report.partial, isTrue);
  });

  test('unsaved cache edits survive disk refresh and remain readable', () async {
    File('${root.path}/a.txt').writeAsStringSync('disk');
    cache.write('a.txt', 'draft');
    cache.create('new.txt', 'new draft');
    expect(cache.read('a.txt'), 'draft');
    final report = await cache.sync(maxFiles: 0);
    expect(cache.read('a.txt'), 'draft');
    expect(cache.read('new.txt'), 'new draft');
    expect(cache.files['a.txt'], 'draft');
    expect(cache.treePaths, containsAll(['a.txt', 'new.txt']));
    expect(report.preservedPaths, unorderedEquals(['a.txt', 'new.txt']));
    expect(File('${root.path}/a.txt').readAsStringSync(), 'disk');
  });

  test('editor save writes disk; later shell changes become visible', () async {
    final file = File('${root.path}/a.txt')..writeAsStringSync('disk');
    cache.write('a.txt', 'draft');
    await AgentService.I.saveStudioFile('a.txt', 'saved');
    expect(file.readAsStringSync(), 'saved');
    expect(cache.read('a.txt'), 'saved');
    file.writeAsStringSync('shell edit');
    await cache.sync();
    expect(cache.read('a.txt'), 'shell edit');
    expect(cache.hasPending, isTrue);
  });

  test('failed local sync and UI recovery keep unsaved drafts', () async {
    cache.write('draft.txt', 'keep');
    root.deleteSync(recursive: true);
    await expectLater(cache.sync(), throwsA(isA<FileSystemException>()));
    cache.clearWorkingCopy();
    expect(cache.files['draft.txt'], 'keep');
    expect(cache.hasPending, isTrue);
    root.createSync();
    expect(cache.read('draft.txt'), 'keep');
  });

  test('unreadable UTF-8 is reported while other files still sync', () async {
    File('${root.path}/bad.txt').writeAsBytesSync([0xff]);
    File('${root.path}/ok.txt').writeAsStringSync('valid');
    final report = await cache.sync();
    expect(report.failedPaths, ['bad.txt']);
    expect(report.partial, isTrue);
    expect(cache.read('ok.txt'), 'valid');
  });

  test('local reads and editor saves refuse symlink and traversal escapes', () async {
    final outside = Directory.systemTemp.createTempSync('outside-sync-');
    addTearDown(() => outside.deleteSync(recursive: true));
    final secret = File('${outside.path}/secret.txt')..writeAsStringSync('outside');
    Link('${root.path}/link').createSync(outside.path);
    Link('${root.path}/file.txt').createSync(secret.path);
    for (final path in ['link/secret.txt', 'file.txt', '../escape.txt']) {
      expect(cache.read(path), isNull);
      expect(() => cache.write(path, 'draft'), throwsStateError);
      await expectLater(AgentService.I.saveStudioFile(path, 'overwrite'), throwsStateError);
    }
    await expectLater(AgentService.I.saveStudioFile('link/new/deep.txt', 'new'), throwsStateError);
    expect(secret.readAsStringSync(), 'outside');
    expect(Directory('${outside.path}/new').existsSync(), isFalse);
    expect(cache.hasPending, isFalse);
  });
}
