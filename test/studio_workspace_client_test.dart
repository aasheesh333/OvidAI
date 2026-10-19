import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/studio_drafts.dart';

import 'support/studio_fake_gateway.dart';

// Wave 2 Studio — the cloud workspace client against the faked gateway.
// Finding ids from docs/audit-2026-10-19/02-studio.md.

const String _s = kFakeStudioSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => StudioDraftStore.I.disableForTest());

  group('ST-002 binding: no server session → no request, a clear state', () {
    test('the workspace bucket with no anchor session never hits the wire',
        () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'x'});
      final remote = StudioRemoteClient(
        files: StudioFilesClient(
          fake.client(),
          sessions: CloudSessionStore.forTest(),
          anchor: () async => null,
        ),
        drafts: StudioDraftStore.I,
      );

      final snapshot = await remote.refreshWorkspace(kStudioWorkspaceKey);

      expect(snapshot, isNull);
      expect(fake.log, isEmpty);
      expect(remote.hasNoWorkspace(kStudioWorkspaceKey), isTrue);
      expect(remote.treeFailure(kStudioWorkspaceKey),
          isA<StudioNoWorkspaceException>());
    });

    test('the workspace bucket resolves through the anchor session', () async {
      final fake = FakeStudioGateway(
        files: {'a.txt': 'x'},
        roots: const [FakeNode.file('a.txt')],
      );
      final remote = installFakeStudio(fake);

      final snapshot = await remote.refreshWorkspace(kStudioWorkspaceKey);

      expect(snapshot?.root.children.single.path, 'a.txt');
      expect(fake.log.single, 'GET /cloud/v1/sessions/$_s/workspace/tree');
    });
  });

  group('ST-009 typed tree failures', () {
    test('a failed tree load keeps the typed error, not a string', () async {
      final fake = FakeStudioGateway()..treeError = (503, 'unavailable');
      final remote = installFakeStudio(fake);

      await remote.refreshWorkspace(_s);

      final failure = remote.treeFailure(_s);
      expect(failure, isA<CloudApiException>());
      expect((failure! as CloudApiException).code, 'unavailable');
      expect(remote.hasNoWorkspace(_s), isFalse);
    });
  });

  group('ST-005 new file never wipes a draft or overwrites a server file', () {
    test('an open path with a draft is focused, the draft kept', () async {
      final fake = FakeStudioGateway(files: {'README.md': 'real'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'README.md');
      remote.updateStudioDraft(_s, 'README.md', 'my unsaved edit');

      final outcome = await remote.newStudioFile(_s, 'README.md');

      expect(outcome, StudioNewFileOutcome.openedExisting);
      expect(remote.fileBuffer(_s)['README.md'], 'my unsaved edit');
      expect(remote.isStudioFileDirty(_s, 'README.md'), isTrue);
    });

    test('a path that exists on the server opens with its real content',
        () async {
      final fake = FakeStudioGateway(files: {'src/a.ts': 'export {};'});
      final remote = installFakeStudio(fake);

      final outcome = await remote.newStudioFile(_s, ' src/a.ts ');

      expect(outcome, StudioNewFileOutcome.openedExisting);
      expect(remote.fileBuffer(_s)['src/a.ts'], 'export {};');
      expect(remote.isStudioFileDirty(_s, 'src/a.ts'), isFalse);

      // Its save is a guarded overwrite of THOSE bytes.
      remote.updateStudioDraft(_s, 'src/a.ts', 'x');
      await remote.saveStudioFile(_s, 'src/a.ts');
      expect(fake.lastPutBody!['ifMatchSha256'], fakeStudioSha('export {};'));
    });

    test('a new path is created empty and its first save is create-only',
        () async {
      final fake = FakeStudioGateway();
      final remote = installFakeStudio(fake);

      final outcome = await remote.newStudioFile(_s, 'notes/todo.md');
      expect(outcome, StudioNewFileOutcome.created);
      remote.updateStudioDraft(_s, 'notes/todo.md', '- ship');
      await remote.saveStudioFile(_s, 'notes/todo.md');

      expect(fake.lastPutBody, {
        'path': 'notes/todo.md',
        'contentUtf8': '- ship',
        'ifNoneMatch': '*',
      });
      expect(fake.files['notes/todo.md'], '- ship');
      expect(remote.isStudioFileDirty(_s, 'notes/todo.md'), isFalse);
    });

    test('the server refusing a create (agent wrote it meanwhile) is a '
        'conflict, not an overwrite', () async {
      final fake = FakeStudioGateway();
      final remote = installFakeStudio(fake);
      await remote.newStudioFile(_s, 'a.txt');
      remote.updateStudioDraft(_s, 'a.txt', 'mine');
      fake.files['a.txt'] = 'agent-wrote-this';

      await expectLater(
        remote.saveStudioFile(_s, 'a.txt'),
        throwsA(isA<CloudApiException>()
            .having((e) => e.code, 'code', 'already_exists')),
      );

      expect(fake.files['a.txt'], 'agent-wrote-this');
      expect(remote.tabsState(_s).conflicts['a.txt'], 'agent-wrote-this');
      expect(remote.fileBuffer(_s)['a.txt'], 'mine');
    });

    test('unusable paths are refused without a request', () async {
      final fake = FakeStudioGateway();
      final remote = installFakeStudio(fake);
      for (final bad in ['', '   ', '/etc/passwd', '../x', 'a/../../b', 'dir/']) {
        expect(await remote.newStudioFile(_s, bad), StudioNewFileOutcome.invalid,
            reason: bad);
      }
      expect(fake.log, isEmpty);
    });

    test('a folder path is reported, not opened as a file', () async {
      final fake = FakeStudioGateway(roots: const [
        FakeNode.dir('src', [FakeNode.file('src/a.ts')]),
      ]);
      final remote = installFakeStudio(fake);
      await remote.refreshWorkspace(_s);

      expect(await remote.newStudioFile(_s, 'src'), StudioNewFileOutcome.isFolder);
    });
  });

  group('ST-007 / ST-014 saves', () {
    test('a stale baseline is refused by the server: conflict, draft kept',
        () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'old'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');
      remote.updateStudioDraft(_s, 'a.txt', 'draft');
      fake.files['a.txt'] = 'agent-edit';

      await expectLater(remote.saveStudioFile(_s, 'a.txt'),
          throwsA(isA<CloudApiException>()));

      expect(fake.files['a.txt'], 'agent-edit');
      expect(remote.tabsState(_s).conflicts['a.txt'], 'agent-edit');
    });

    test('a double save sends ONE PUT and reports saving meanwhile', () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'old'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');
      remote.updateStudioDraft(_s, 'a.txt', 'new');

      final first = remote.saveStudioFile(_s, 'a.txt');
      expect(remote.isSaving(_s, 'a.txt'), isTrue);
      expect(remote.tabsState(_s).savingPaths, ['a.txt']);
      final second = remote.saveStudioFile(_s, 'a.txt');
      await Future.wait([first, second]);

      expect(fake.putCalls, 1);
      expect(remote.isSaving(_s, 'a.txt'), isFalse);
      expect(remote.tabsState(_s).conflicts, isEmpty,
          reason: 'no false conflict from a second, racing PUT');
    });
  });

  group('ST-006 freshness from the server', () {
    test('refresh adopts agent edits into a clean open buffer', () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'v1'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');
      fake.files['a.txt'] = 'v2 by the agent';

      await remote.refreshWorkspace(_s);

      expect(remote.fileBuffer(_s)['a.txt'], 'v2 by the agent');
      expect(remote.baselines(_s)['a.txt'], fakeStudioSha('v2 by the agent'));
      expect(remote.isStudioFileDirty(_s, 'a.txt'), isFalse);
    });

    test('refresh flags a conflict on a draft whose file changed', () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'v1'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');
      remote.updateStudioDraft(_s, 'a.txt', 'my draft');
      fake.files['a.txt'] = 'v2';

      await remote.refreshWorkspace(_s);

      expect(remote.fileBuffer(_s)['a.txt'], 'my draft');
      expect(remote.tabsState(_s).conflicts['a.txt'], 'v2');
    });

    test('a clean open file the agent deleted closes', () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'v1'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');
      fake.files.remove('a.txt');

      await remote.refreshWorkspace(_s);

      expect(remote.openFiles(_s), isEmpty);
      expect(remote.fileBuffer(_s), isEmpty);
    });

    test('closing a clean tab drops its buffer so a reopen reads the server',
        () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'v1'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');
      remote.closeStudioFile(_s, 'a.txt');
      fake.files['a.txt'] = 'v2';

      await remote.openStudioFile(_s, 'a.txt');

      expect(fake.getFileCalls, 2);
      expect(remote.fileBuffer(_s)['a.txt'], 'v2');
    });

    test('concurrent refreshes share one tree GET (ST-019)', () async {
      final fake = FakeStudioGateway();
      final remote = installFakeStudio(fake);

      await Future.wait([
        remote.refreshWorkspace(_s),
        remote.refreshWorkspace(_s),
        remote.refreshWorkspace(_s),
      ]);

      expect(fake.treeCalls, 1);
    });

    testWidgets('agent file events trigger ONE debounced refresh',
        (tester) async {
      final fake = FakeStudioGateway(files: {'a.txt': 'v1'});
      final remote = installFakeStudio(fake,
          agentRefreshDebounce: const Duration(milliseconds: 500));
      await remote.openStudioFile(_s, 'a.txt');
      fake.files['a.txt'] = 'v2';

      remote.noteAgentEvent(_s, 'tool_started', {'name': 'write_file'});
      remote.noteAgentEvent(_s, 'tool_completed', {'name': 'read_file'});
      await tester.pump(const Duration(seconds: 1));
      expect(fake.treeCalls, 0, reason: 'reads never refresh');

      remote.noteAgentEvent(_s, 'tool_completed', {'name': 'write_file'});
      remote.noteAgentEvent(_s, 'tool_completed', {'name': 'edit_file'});
      remote.noteAgentEvent(_s, 'run_completed');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(fake.treeCalls, 1);
      expect(remote.fileBuffer(_s)['a.txt'], 'v2');
    });
  });

  group('ST-008 rename / delete / new folder', () {
    test('delete a file closes its tab and refreshes the tree', () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'x', 'b.txt': 'y'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');

      await remote.deleteStudioPath(_s, 'a.txt');

      expect(fake.files.containsKey('a.txt'), isFalse);
      expect(remote.openFiles(_s), isEmpty);
      expect(fake.log, contains('DELETE /cloud/v1/sessions/$_s/workspace/file?path=a.txt'));
      expect(fake.treeCalls, greaterThanOrEqualTo(1));
    });

    test('delete a folder is recursive and drops drafts inside it', () async {
      final fake = FakeStudioGateway(files: {'src/a.ts': 'a', 'src/b.ts': 'b'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'src/a.ts');
      remote.updateStudioDraft(_s, 'src/a.ts', 'draft');
      expect(remote.dirtyFilesUnder(_s, 'src'), ['src/a.ts']);

      await remote.deleteStudioPath(_s, 'src', isFolder: true);

      expect(fake.files, isEmpty);
      expect(remote.dirtyFiles(_s), isEmpty);
      expect(fake.log.any((l) => l.contains('recursive=true')), isTrue);
    });

    test('rename moves the file on the server and its open draft follows',
        () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'x'});
      final remote = installFakeStudio(fake);
      await remote.openStudioFile(_s, 'a.txt');
      remote.updateStudioDraft(_s, 'a.txt', 'draft');

      expect(await remote.renameStudioPath(_s, 'a.txt', 'docs/b.txt'), isTrue);

      expect(fake.files, {'docs/b.txt': 'x'});
      expect(remote.openFiles(_s), ['docs/b.txt']);
      expect(remote.activeFilePath(_s), 'docs/b.txt');
      expect(remote.fileBuffer(_s)['docs/b.txt'], 'draft');
      expect(remote.isStudioFileDirty(_s, 'docs/b.txt'), isTrue);
      expect(remote.baselines(_s)['docs/b.txt'], fakeStudioSha('x'));
    });

    test('rename onto an existing file is refused by the server', () async {
      final fake = FakeStudioGateway(files: {'a.txt': 'a', 'b.txt': 'b'});
      final remote = installFakeStudio(fake);

      await expectLater(remote.renameStudioPath(_s, 'a.txt', 'b.txt'),
          throwsA(isA<CloudApiException>()
              .having((e) => e.code, 'code', 'already_exists')));
      expect(fake.files, {'a.txt': 'a', 'b.txt': 'b'});
    });

    test('new folder', () async {
      final fake = FakeStudioGateway();
      final remote = installFakeStudio(fake);

      expect(await remote.createStudioFolder(_s, 'src/new/'), isTrue);
      expect(fake.folders, {'src/new'});
      expect(await remote.createStudioFolder(_s, '../x'), isFalse);
    });
  });

  group('ST-013 cold workspace', () {
    testWidgets('a cold tree wakes the workspace and polls until warm',
        (tester) async {
      final fake = FakeStudioGateway()..state = 'cold';
      final remote = installFakeStudio(fake,
          wakePollInterval: const Duration(seconds: 1));

      await remote.refreshWorkspace(_s);
      await tester.pump(); // the hydrate POST is fire-and-forget
      expect(fake.hydrateCalls, 1);
      expect(remote.isWaking(_s), isTrue);

      fake.state = 'warm';
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(remote.isWaking(_s), isFalse);
      expect(remote.snapshotFor(_s)?.state, 'warm');
    });

    testWidgets('a save answered 202 is retried automatically once warm',
        (tester) async {
      final fake = FakeStudioGateway(files: {'a.txt': 'old'});
      final remote = installFakeStudio(fake,
          wakePollInterval: const Duration(seconds: 1));
      await remote.openStudioFile(_s, 'a.txt');
      remote.updateStudioDraft(_s, 'a.txt', 'new');
      fake.putHydrating = true;

      await expectLater(remote.saveStudioFile(_s, 'a.txt'),
          throwsA(isA<StudioFileHydratingException>()));
      expect(remote.isSavePending(_s, 'a.txt'), isTrue);
      expect(remote.isWaking(_s), isTrue);

      fake.putHydrating = false;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();

      expect(fake.files['a.txt'], 'new');
      expect(remote.isStudioFileDirty(_s, 'a.txt'), isFalse);
      expect(remote.isSavePending(_s, 'a.txt'), isFalse);
    });
  });

  group('ST-015 pruned folders', () {
    test('loading a pruned folder merges its children into the tree',
        () async {
      final fake = FakeStudioGateway(roots: const [FakeNode.dir('big', [])])
        ..subtrees['big'] = const [
          FakeNode.file('big/a.ts'),
          FakeNode.file('big/b.ts'),
        ];
      final remote = installFakeStudio(fake);
      await remote.refreshWorkspace(_s);

      await remote.loadStudioSubtree(_s, 'big');

      final big = remote.treeFor(_s)!.children.single;
      expect(big.children.map((n) => n.path), ['big/a.ts', 'big/b.ts']);
      expect(remote.subtreeLoaded(_s, 'big'), isTrue);
      expect(fake.log, contains('GET /cloud/v1/sessions/$_s/workspace/tree?path=big'));
    });
  });
}
