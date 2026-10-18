import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/studio_drafts.dart';

/// The P7 workspace gateway, faked for Studio widget tests.
///
/// The deleted local-git tests seeded `RepoCache`; the surviving behaviour
/// binds to `StudioRemoteClient` over the built REST shapes instead. This
/// fake implements exactly the three routes the client calls
/// (`GET tree`, `GET file`, `PUT file`) plus the presigned download body.
const String kFakeStudioSession = 's1';
const String kFakeStudioBase = 'https://cloud.test/cloud/v1';

String fakeStudioSha(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// One manifest node. A non-null [children] list means a directory.
class FakeNode {
  const FakeNode.file(this.path, {this.size})
      : children = null;

  const FakeNode.dir(this.path, this.children) : size = null;

  final String path;
  final int? size;
  final List<FakeNode>? children;
}

Map<String, dynamic> _nodeJson(FakeNode node) {
  final name = node.path.split('/').last;
  if (node.children != null) {
    return <String, dynamic>{
      'name': name,
      'path': node.path,
      'type': 'dir',
      'children': [for (final child in node.children!) _nodeJson(child)],
    };
  }
  return <String, dynamic>{
    'name': name,
    'path': node.path,
    'type': 'file',
    if (node.size != null) 'sizeBytes': node.size,
  };
}

http.Response _error(int status, String code) => http.Response(
      jsonEncode({
        'error': {'code': code, 'message': code},
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

class FakeStudioGateway {
  FakeStudioGateway({
    Map<String, String>? files,
    List<FakeNode>? roots,
    Map<String, int>? redirectPaths,
  })  : files = files ?? <String, String>{},
        roots = roots ?? const <FakeNode>[],
        redirectPaths = redirectPaths ?? <String, int>{};

  /// path → inline content (GET) and the accepted PUT bodies.
  final Map<String, String> files;

  /// The manifest's `roots` array.
  final List<FakeNode> roots;

  /// path → declared `sizeBytes` for a presigned-redirect response. The body
  /// is only fetched when the client actually downloads it.
  final Map<String, int> redirectPaths;

  int treeCalls = 0;
  int getFileCalls = 0;
  int downloadCalls = 0;
  int putCalls = 0;
  Map<String, dynamic>? lastPutBody;

  CloudRestClient client() {
    final mock = MockClient((request) async {
      final path = request.url.path;
      final filePath = '/sessions/$kFakeStudioSession/workspace/file';
      if (request.method == 'GET' &&
          path.endsWith('/sessions/$kFakeStudioSession/workspace/tree')) {
        treeCalls++;
        final bytes = files.values.fold<int>(
            0, (sum, content) => sum + utf8.encode(content).length);
        return http.Response(
          jsonEncode({
            'sessionId': kFakeStudioSession,
            'state': 'warm',
            'generation': 1,
            'source': 'live',
            'tree': {
              'version': 1,
              'truncated': false,
              'totals': {
                'files': files.length,
                'dirs': 0,
                'bytes': bytes,
              },
              'roots': [for (final node in roots) _nodeJson(node)],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && path.endsWith(filePath)) {
        getFileCalls++;
        final requested = request.url.queryParameters['path']!;
        final redirectSize = redirectPaths[requested];
        if (redirectSize != null) {
          return http.Response(
            jsonEncode({
              'path': requested,
              'sizeBytes': redirectSize,
              'contentType': 'text/plain',
              'downloadUrl': '$kFakeStudioBase/download/$requested',
              'expiresAt': '2026-10-18T00:00:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final content = files[requested];
        if (content == null) return _error(404, 'not_found');
        return http.Response(
          jsonEncode({
            'path': requested,
            'sizeBytes': utf8.encode(content).length,
            'contentType': 'text/plain',
            'encoding': 'utf8',
            'content': content,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && path.contains('/download/')) {
        downloadCalls++;
        final encoded = path.substring(path.indexOf('/download/') + 10);
        final requested = Uri.decodeComponent(encoded);
        return http.Response.bytes(
          utf8.encode(files[requested] ?? ''),
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }
      if (request.method == 'PUT' && path.endsWith(filePath)) {
        putCalls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        lastPutBody = body;
        final content = body['contentUtf8'] as String? ?? '';
        final requested = body['path'] as String? ?? '';
        files[requested] = content;
        return http.Response(
          jsonEncode({
            'path': requested,
            'sizeBytes': utf8.encode(content).length,
            'sha256': fakeStudioSha(content),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return _error(404, 'not_found');
    });
    return CloudRestClient(
      httpClient: mock,
      headers: CloudHeaders.forTest(),
      restBase: kFakeStudioBase,
    );
  }
}

/// Installs a [StudioRemoteClient] bound to [fake] as the test singleton.
StudioRemoteClient installFakeStudio(
  FakeStudioGateway fake, {
  StudioDraftStore? drafts,
}) {
  final remote = StudioRemoteClient(
    files: StudioFilesClient(fake.client()),
    drafts: drafts ?? StudioDraftStore.I,
  );
  StudioRemoteClient.installForTest(remote);
  return remote;
}
