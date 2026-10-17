import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_pty.dart';
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
    files: StudioFilesClient(fake.client()),
    drafts: StudioDraftStore.I,
  );
  StudioRemoteClient.installForTest(remote);
  return remote;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StudioFilesClient parses the built P7 shapes', () {
    test('tree parses nested FileNodes from the manifest response', () async {
      final files = StudioFilesClient(_FakeRest().client());
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
      expect(fake.lastPutBody, {'path': 'a.txt', 'contentUtf8': 'new'});
      expect(remote.isStudioFileDirty(_session, 'a.txt'), isFalse);
      expect(remote.baselines(_session)['a.txt'], _sha('new'));
    });

    test('PUT 409 becomes a conflict entry and keeps the draft', () async {
      // First read (open) and the optimistic pre-check both see "old"; the
      // conflict refetch after the 409 sees what actually landed upstream.
      final fake = _FakeRest(
        reads: ['old', 'old', 'remote-new'],
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
        reads: ['old', 'old', 'remote-new'],
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

      expect(find.textContaining('changed externally'), findsOneWidget);

      await tester.tap(find.text('Use external'));
      await tester.pump();

      expect(remote.fileBuffer(_session)['a.txt'], 'remote-new');
      expect(remote.conflicts(_session), isEmpty);
      expect(remote.isStudioFileDirty(_session, 'a.txt'), isFalse);
    });
  });

  group('CloudPtyChannel offset reassembly (P2 contract)', () {
    late StreamController<Map<String, dynamic>> frames;
    late List<Map<String, dynamic>> sent;
    late CloudPtyChannel channel;

    WsMultiplexer idleWs() => WsMultiplexer(
          mintTicket: () async => 'ticket',
          heartbeatInterval: const Duration(hours: 1),
          pongTimeout: const Duration(hours: 1),
        );

    setUp(() {
      frames = StreamController<Map<String, dynamic>>.broadcast();
      sent = <Map<String, dynamic>>[];
      channel = CloudPtyChannel(
        sessionId: _session,
        tabId: 't1',
        ws: idleWs(),
        settleWindow: Duration.zero,
        rawFramesOverride: frames.stream,
        sendOverride: (frame) async => sent.add(frame),
      );
    });

    tearDown(() async {
      await channel.close();
      await frames.close();
    });

    Future<void> open() async {
      frames.add({'op': 'pty_opened', 'ptyId': 'p1', 'sessionId': _session});
      await Future<void>.delayed(Duration.zero);
    }

    void output(int offset, String text) {
      frames.add({
        'op': 'pty_output',
        'ptyId': 'p1',
        'offset': offset,
        'data': base64Encode(utf8.encode(text)),
      });
    }

    test('repaint and live bytes are emitted in OFFSET order, not arrival order',
        () async {
      final out = <int>[];
      final sub = channel.output.listen(out.addAll);
      await open();

      // REVERSE arrival: the live chunk (offset 7) lands BEFORE the repaint
      // (offset 0). The channel must hold the live bytes and emit the repaint
      // first.
      output(7, 'LIVE');
      output(0, 'REPAINT');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(utf8.decode(out), 'REPAINTLIVE');

      // A late duplicate below the emitted high-water mark is discarded.
      output(0, 'DUP');
      await Future<void>.delayed(Duration.zero);
      expect(utf8.decode(out), 'REPAINTLIVE');

      await sub.cancel();
    });

    test('a gap is not emitted until the missing range arrives', () async {
      final out = <int>[];
      final sub = channel.output.listen(out.addAll);
      await open();

      output(0, 'AAA');
      output(6, 'CCC'); // gap 3..5 missing
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(utf8.decode(out), 'AAA');

      output(3, 'BBB');
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(utf8.decode(out), 'AAABBBCCC');
      await sub.cancel();
    });

    test('resize sends the pinned pty_resize shape', () async {
      await open();
      channel.resize(120, 40);
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.where((f) => f['op'] == 'pty_resize').last,
        {'op': 'pty_resize', 'ptyId': 'p1', 'cols': 120, 'rows': 40},
      );
    });

    test('write sends base64 pty_input', () async {
      await open();
      channel.write(Uint8List.fromList(utf8.encode('ls\n')));
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.where((f) => f['op'] == 'pty_input').last,
        {'op': 'pty_input', 'ptyId': 'p1', 'data': base64Encode(utf8.encode('ls\n'))},
      );
    });

    test('open sends pty_open for the session with the initial dimensions',
        () async {
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.first,
        {'op': 'pty_open', 'sessionId': _session, 'cols': 80, 'rows': 24},
      );
    });
  });
}
