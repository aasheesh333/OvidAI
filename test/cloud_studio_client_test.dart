import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';

const String _base = 'https://cloud.test/cloud/v1';
const String _session = 's1';

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

String _treeJson() => jsonEncode({
      'sessionId': _session,
      'state': 'warm',
      'generation': 3,
      'source': 'live',
      'tree': {
        'version': 1,
        'generatedAt': '2026-10-17T00:00:00.000Z',
        'truncated': false,
        'totals': {'files': 2, 'dirs': 1, 'bytes': 30},
        'roots': [
          {
            'name': 'src',
            'path': 'src',
            'type': 'dir',
            'children': [
              {
                'name': 'main.dart',
                'path': 'src/main.dart',
                'type': 'file',
                'sizeBytes': 10,
                'mtime': '2026-10-17T00:00:00Z',
              },
            ],
          },
          {
            'name': 'README.md',
            'path': 'README.md',
            'type': 'file',
            'sizeBytes': 20,
          },
        ],
      },
    });

String _fileJson(String path, String content) => jsonEncode({
      'path': path,
      'sizeBytes': utf8.encode(content).length,
      'contentType': 'text/plain',
      'encoding': 'utf8',
      'content': content,
    });

/// A fake gateway: tree + file read + file write, with per-test overrides.
class _FakeRest {
  _FakeRest({
    this.reads = const [],
    this.putStatus = 200,
  });

  /// Contents returned by successive GET file calls (last one repeats).
  final List<String> reads;
  final int putStatus;

  int getFileCalls = 0;
  int putCalls = 0;
  Map<String, dynamic>? lastPutBody;

  CloudRestClient client() {
    final mock = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' &&
          path.endsWith('/sessions/$_session/workspace/tree')) {
        return http.Response(_treeJson(), 200,
            headers: {'content-type': 'application/json'});
      }
      if (request.method == 'GET' &&
          path.endsWith('/sessions/$_session/workspace/file')) {
        final index = getFileCalls < reads.length
            ? getFileCalls
            : reads.length - 1;
        getFileCalls++;
        return http.Response(_fileJson(request.url.queryParameters['path']!,
                reads[index]),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.method == 'PUT' &&
          path.endsWith('/sessions/$_session/workspace/file')) {
        putCalls++;
        lastPutBody = jsonDecode(request.body) as Map<String, dynamic>;
        if (putStatus != 200) {
          return http.Response(
              jsonEncode({
                'error': {
                  'code': 'baseline_mismatch',
                  'message': 'The file changed on the server.',
                },
              }),
              putStatus,
              headers: {'content-type': 'application/json'});
        }
        final content = lastPutBody!['contentUtf8'] as String? ?? '';
        return http.Response(
            jsonEncode({
              'path': lastPutBody!['path'],
              'sizeBytes': utf8.encode(content).length,
              'sha256': _sha(content),
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"error":{"code":"not_found","message":"no"}}', 404,
          headers: {'content-type': 'application/json'});
    });
    return CloudRestClient(
      httpClient: mock,
      headers: CloudHeaders.forTest(),
      restBase: _base,
    );
  }
}

StudioRemoteClient _remote(_FakeRest fake) {
  StudioDraftStore.I.disableForTest();
  final remote = StudioRemoteClient(
    files: StudioFilesClient(
      fake.client(),
      sessions: CloudSessionStore.forTest(idMap: const {_session: _session}),
    ),
    drafts: StudioDraftStore.I,
  );
  StudioRemoteClient.installForTest(remote);
  return remote;
}

/// Records the exact path of every workspace call and answers for any session
/// id, so a test can prove which id went on the wire.
class _RecordingRest {
  final List<String> paths = <String>[];
  final List<String> methods = <String>[];

  CloudRestClient client() {
    final mock = MockClient((request) async {
      final path = request.url.path;
      paths.add(path);
      methods.add(request.method);
      final segments = request.url.pathSegments;
      final sessionId = segments.length > 3 ? segments[3] : 'unknown-session';
      if (request.method == 'GET' && path.endsWith('/workspace/tree')) {
        return http.Response(
          jsonEncode({
            'sessionId': sessionId,
            'state': 'warm',
            'generation': 1,
            'source': 'live',
            'tree': {
              'truncated': false,
              'totals': {'files': 0, 'dirs': 0, 'bytes': 0},
              'roots': <Object>[],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && path.endsWith('/workspace/file')) {
        return http.Response(
          jsonEncode({
            'path': request.url.queryParameters['path'],
            'sizeBytes': 5,
            'contentType': 'text/plain',
            'encoding': 'utf8',
            'content': 'hello',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'PUT' && path.endsWith('/workspace/file')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final content = body['contentUtf8'] as String? ?? '';
        return http.Response(
          jsonEncode({
            'path': body['path'],
            'sizeBytes': utf8.encode(content).length,
            'sha256': _sha(content),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"error":{"code":"not_found","message":"no"}}',
        404,
        headers: {'content-type': 'application/json'},
      );
    });
    return CloudRestClient(
      httpClient: mock,
      headers: CloudHeaders.forTest(),
      restBase: _base,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('local→server session id resolution', () {
    const local = 'local-1';
    const server = '018f3b0e-7a2c-7c4d-9e5f-123456789abc';

    CloudSessionStore mappedStore() =>
        CloudSessionStore.forTest(idMap: const {local: server});

    test('treeSnapshot sends the mapped server UUID in the path', () async {
      final rest = _RecordingRest();
      final files = StudioFilesClient(
        rest.client(),
        sessions: mappedStore(),
      );

      final snapshot = await files.treeSnapshot(local);

      expect(rest.paths.single,
          '/cloud/v1/sessions/$server/workspace/tree');
      expect(rest.paths.single, isNot(contains(local)));
      expect(snapshot.sessionId, server);
    });

    test('readFile sends the mapped server UUID in the path', () async {
      final rest = _RecordingRest();
      final files = StudioFilesClient(
        rest.client(),
        sessions: mappedStore(),
      );

      expect(await files.readFile(local, 'a.txt'), 'hello');

      expect(rest.paths.single,
          '/cloud/v1/sessions/$server/workspace/file');
      expect(rest.paths.single, isNot(contains(local)));
    });

    test('writeFile sends the mapped server UUID in the path', () async {
      final rest = _RecordingRest();
      final files = StudioFilesClient(
        rest.client(),
        sessions: mappedStore(),
      );

      final result = await files.writeFile(local, 'a.txt', 'new');

      expect(result.sha256, _sha('new'));
      expect(rest.paths.single,
          '/cloud/v1/sessions/$server/workspace/file');
      expect(rest.methods.single, 'PUT');
      expect(rest.paths.single, isNot(contains(local)));
    });

    // ST-002: a chat that never reached the server has a LOCAL id
    // (microseconds since epoch). Putting it on the wire produced a 404 for a
    // non-UUID path; it is now refused before any request.
    test('an unmapped local id is never put on the wire (ST-002)', () async {
      final rest = _RecordingRest();
      final files = StudioFilesClient(
        rest.client(),
        sessions: CloudSessionStore.forTest(),
      );

      await expectLater(
        files.treeSnapshot(local),
        throwsA(isA<StudioNoWorkspaceException>()
            .having((e) => e.code, 'code', 'no_workspace')),
      );
      expect(rest.paths, isEmpty);
    });


  });

  group('StudioFilesClient parses the built P7 shapes', () {
    test('tree parses nested FileNodes from the manifest response', () async {
      final files = StudioFilesClient(
        _FakeRest().client(),
        sessions: CloudSessionStore.forTest(idMap: const {_session: _session}),
      );
      final root = await files.tree(_session);

      expect(root.children, hasLength(2));
      final src = root.children.first;
      expect(src.kind, 'dir');
      expect(src.isDir, isTrue);
      expect(src.children.single.path, 'src/main.dart');
      expect(src.children.single.kind, 'file');
      expect(src.children.single.size, 10);
      expect(src.children.single.mtime, isNotNull);
      expect(root.children.last.path, 'README.md');
    });
  });

  group('StudioRemoteClient', () {
    test('openStudioFile lazily fetches once and fills buffer + baseline',
        () async {
      final fake = _FakeRest(reads: ['void main() {}']);
      final remote = _remote(fake);

      await remote.openStudioFile(_session, 'src/main.dart');
      await remote.openStudioFile(_session, 'src/main.dart');

      expect(fake.getFileCalls, 1,
          reason: 'a repeat open of the same path must not refetch');
      expect(remote.fileBuffer(_session)['src/main.dart'], 'void main() {}');
      expect(remote.baselines(_session)['src/main.dart'], _sha('void main() {}'));
      expect(remote.openFiles(_session), ['src/main.dart']);
      expect(remote.activeFilePath(_session), 'src/main.dart');
    });

    test('edit marks dirty; save PUTs and clears dirty + updates baseline',
        () async {
      final fake = _FakeRest(reads: ['old']);
      final remote = _remote(fake);
      await remote.openStudioFile(_session, 'a.txt');

      remote.updateStudioDraft(_session, 'a.txt', 'new');
      expect(remote.isStudioFileDirty(_session, 'a.txt'), isTrue);

      await remote.saveStudioFile(_session, 'a.txt');

      expect(fake.putCalls, 1);
      // ST-007: the baseline travels as the server-side precondition; there
      // is no client-side pre-read GET any more.
      expect(fake.lastPutBody, {
        'path': 'a.txt',
        'contentUtf8': 'new',
        'ifMatchSha256': _sha('old'),
      });
      expect(fake.getFileCalls, 1, reason: 'only the open read, no pre-check');
      expect(remote.isStudioFileDirty(_session, 'a.txt'), isFalse);
      expect(remote.baselines(_session)['a.txt'], _sha('new'));
    });

    test('PUT 409 becomes a conflict entry and keeps the draft', () async {
      // The open read sees "old"; the server refuses the guarded PUT (409)
      // and the conflict refetch sees what actually landed upstream.
      final fake = _FakeRest(
        reads: ['old', 'remote-new'],
        putStatus: 409,
      );
      final remote = _remote(fake);
      await remote.openStudioFile(_session, 'a.txt');
      remote.updateStudioDraft(_session, 'a.txt', 'my-draft');

      await expectLater(
        remote.saveStudioFile(_session, 'a.txt'),
        throwsA(isA<CloudApiException>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.code, 'code', 'baseline_mismatch')),
      );

      expect(remote.conflicts(_session)['a.txt']?.kind, 'baseline');
      expect(remote.isStudioFileDirty(_session, 'a.txt'), isTrue,
          reason: 'a rejected save must never clear the draft');
      expect(remote.fileBuffer(_session)['a.txt'], 'my-draft');
    });

    testWidgets('409 routes into the editor conflict-resolution path',
        (tester) async {
      final fake = _FakeRest(
        reads: ['old', 'remote-new'],
        putStatus: 409,
      );
      final remote = _remote(fake);
      await remote.openStudioFile(_session, 'a.txt');
      remote.updateStudioDraft(_session, 'a.txt', 'my-draft');
      await expectLater(
        remote.saveStudioFile(_session, 'a.txt'),
        throwsA(isA<CloudApiException>()),
      );

      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(body: StudioEditor(sessionId: _session)),
      ));
      await tester.pump();

      expect(find.textContaining('changed in the workspace'), findsOneWidget);

      await tester.tap(find.text('Use workspace version'));
      await tester.pump();

      expect(remote.fileBuffer(_session)['a.txt'], 'remote-new');
      expect(remote.conflicts(_session), isEmpty);
      expect(remote.isStudioFileDirty(_session, 'a.txt'), isFalse);
    });
  });
}
