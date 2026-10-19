import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/studio_drafts.dart';

/// The P7 workspace gateway, faked for Studio widget tests.
///
/// Implements the routes the client calls over the built REST shapes:
/// `GET tree` (`?path=` subtree too), `GET file` (+ the presigned download
/// body), `PUT file` (with the `ifMatchSha256` / `ifNoneMatch` preconditions
/// answered like the server: 409 `baseline_mismatch` / `already_exists`),
/// `DELETE file`, `POST move`, `POST mkdir` and `POST hydrate`.
const String kFakeStudioSession = 's1';
const String kFakeStudioBase = 'https://cloud.test/cloud/v1';

String fakeStudioSha(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// One manifest node. A non-null [children] list means a directory.
class FakeNode {
  const FakeNode.file(this.path, {this.size})
      : children = null,
        prunedFiles = null;

  const FakeNode.dir(this.path, this.children)
      : size = null,
        prunedFiles = null;

  /// A folder the manifest pruned at its depth cap: rollups, no children.
  const FakeNode.pruned(this.path, int files)
      : children = const <FakeNode>[],
        size = null,
        prunedFiles = files;

  final String path;
  final int? size;
  final List<FakeNode>? children;
  final int? prunedFiles;
}

Map<String, dynamic> _nodeJson(FakeNode node) {
  final name = node.path.split('/').last;
  if (node.children != null) {
    return <String, dynamic>{
      'name': name,
      'path': node.path,
      'type': 'dir',
      if (node.prunedFiles == null)
        'children': [for (final child in node.children!) _nodeJson(child)]
      else ...{
        'files': node.prunedFiles,
        'dirs': 0,
        'bytes': 0,
      },
    };
  }
  return <String, dynamic>{
    'name': name,
    'path': node.path,
    'type': 'file',
    if (node.size != null) 'sizeBytes': node.size,
  };
}

http.Response _json(Map<String, Object?> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

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
  int hydrateCalls = 0;
  Map<String, dynamic>? lastPutBody;

  /// Every request as "METHOD path?query", in order.
  final List<String> log = <String>[];

  /// Workspace state the tree reports (`warm` / `cold` / `hydrating`).
  String state = 'warm';

  /// When set, the next tree responses answer this error (status, code).
  (int, String)? treeError;

  /// When true, PUTs answer 202 {status:'hydrating'} (a waking workspace).
  bool putHydrating = false;

  /// Subtree answers for `GET tree?path=`: folder path → its child nodes.
  final Map<String, List<FakeNode>> subtrees = <String, List<FakeNode>>{};

  /// Folders created through `POST mkdir`.
  final Set<String> folders = <String>{};

  CloudRestClient client() {
    final mock = MockClient((request) async {
      final path = request.url.path;
      log.add('${request.method} ${request.url.path}'
          '${request.url.hasQuery ? '?${request.url.query}' : ''}');
      final filePath = '/sessions/$kFakeStudioSession/workspace/file';
      final base = '/sessions/$kFakeStudioSession/workspace';
      if (request.method == 'POST' && path.endsWith('$base/hydrate')) {
        hydrateCalls++;
        return _json({'status': 'hydrating'}, 202);
      }
      if (request.method == 'POST' && path.endsWith('$base/mkdir')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final dir = body['path'] as String;
        final created = folders.add(dir);
        return _json({'path': dir, 'created': created});
      }
      if (request.method == 'POST' && path.endsWith('$base/move')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final from = body['from'] as String;
        final to = body['to'] as String;
        if (files.containsKey(to)) return _error(409, 'already_exists');
        final moved = <String, String>{};
        files.removeWhere((key, value) {
          if (key == from || key.startsWith('$from/')) {
            moved[key == from ? to : '$to${key.substring(from.length)}'] =
                value;
            return true;
          }
          return false;
        });
        if (moved.isEmpty && !folders.contains(from)) {
          return _error(404, 'not_found');
        }
        files.addAll(moved);
        return _json({'from': from, 'to': to});
      }
      if (request.method == 'DELETE' && path.endsWith(filePath)) {
        final target = request.url.queryParameters['path']!;
        final recursive = request.url.queryParameters['recursive'] == 'true';
        if (files.remove(target) != null) {
          return _json({'path': target, 'type': 'file'});
        }
        final inside =
            files.keys.where((k) => k.startsWith('$target/')).toList();
        if (inside.isNotEmpty && !recursive) return _error(409, 'not_empty');
        if (inside.isEmpty && !folders.contains(target)) {
          return _error(404, 'not_found');
        }
        for (final k in inside) {
          files.remove(k);
        }
        folders.remove(target);
        return _json({'path': target, 'type': 'dir'});
      }
      if (request.method == 'GET' &&
          path.endsWith('/sessions/$kFakeStudioSession/workspace/tree')) {
        treeCalls++;
        final error = treeError;
        if (error != null) return _error(error.$1, error.$2);
        final sub = request.url.queryParameters['path'];
        if (sub != null) {
          if (state != 'warm') return _error(409, 'not_warm');
          final children = subtrees[sub];
          if (children == null) return _error(404, 'not_found');
          return _json({
            'sessionId': kFakeStudioSession,
            'state': 'warm',
            'generation': 1,
            'source': 'live',
            'tree': {
              'version': 1,
              'truncated': false,
              'totals': {'files': children.length, 'dirs': 0, 'bytes': 0},
              'roots': [for (final node in children) _nodeJson(node)],
            },
          });
        }
        final bytes = files.values.fold<int>(
            0, (sum, content) => sum + utf8.encode(content).length);
        return http.Response(
          jsonEncode({
            'sessionId': kFakeStudioSession,
            'state': state,
            'generation': 1,
            'source': state == 'warm' ? 'live' : 'manifest',
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
        if (putHydrating) return _json({'status': 'hydrating'}, 202);
        final content = body['contentUtf8'] as String? ?? '';
        final requested = body['path'] as String? ?? '';
        final ifMatch = body['ifMatchSha256'] as String?;
        if (ifMatch != null) {
          final current = files[requested];
          if (current == null || fakeStudioSha(current) != ifMatch) {
            return _error(409, 'baseline_mismatch');
          }
        }
        if (body['ifNoneMatch'] == '*' && files.containsKey(requested)) {
          return _error(409, 'already_exists');
        }
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
  Duration wakePollInterval = const Duration(seconds: 2),
  Duration agentRefreshDebounce = const Duration(milliseconds: 800),
}) {
  final remote = StudioRemoteClient(
    // The fake session is a known server id; the in-memory test store keeps
    // the resolver off SharedPreferences.
    files: StudioFilesClient(
      fake.client(),
      sessions: CloudSessionStore.forTest(
        idMap: const {kFakeStudioSession: kFakeStudioSession},
      ),
      // The user's workspace bucket addresses the same fake session.
      anchor: () async => kFakeStudioSession,
    ),
    drafts: drafts ?? StudioDraftStore.I,
    wakePollInterval: wakePollInterval,
    agentRefreshDebounce: agentRefreshDebounce,
  );
  StudioRemoteClient.installForTest(remote);
  return remote;
}
