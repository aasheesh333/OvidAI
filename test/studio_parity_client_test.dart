import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_git_api.dart';

const String _base = 'https://cloud.test/cloud/v1';
const String _session = 'studio-local';
const String _serverSession = '0199aaaa-0000-7000-8000-00000000e702';
const String _patCanary = 'ghp_1234567890abcdefghijklmnopQRSTUVWXYZ';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _status({bool includeCounts = true}) => <String, Object?>{
  'branch': 'main',
  'headSha': 'abc123',
  'upstream': null,
  'dirty': true,
  if (includeCounts) 'ahead': 2,
  if (includeCounts) 'behind': 3,
  'reason': 'diverged',
  'fetchedAt': null,
};

void main() {
  late List<http.Request> requests;

  StudioGitApi apiWith(Future<http.Response> Function(http.Request) handler) {
    requests = <http.Request>[];
    return StudioGitApi(
      rest: CloudRestClient(
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
        headers: CloudHeaders.forTest(),
        restBase: _base,
      ),
      sessions: CloudSessionStore.forTest(
        idMap: const <String, String>{_session: _serverSession},
      ),
    );
  }

  test(
    'inspect uses fetch only preflight and preserves real nullable status',
    () async {
      final api = apiWith((request) async => _json(_status()));

      final status = await api.inspect(_session);

      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.path,
        '/cloud/v1/studio/sessions/$_serverSession/git/preflight',
      );
      expect(jsonDecode(requests.single.body), <String, Object>{});
      expect(status.branch, 'main');
      expect(status.headSha, 'abc123');
      expect(status.upstream, isNull);
      expect(status.dirty, isTrue);
      expect(status.ahead, 2);
      expect(status.behind, 3);
      expect(status.reason, 'diverged');
      expect(status.fetchedAt, isNull);
      final wire = requests.single;
      expect('${wire.url} ${wire.body}', isNot(contains('repoDir')));
      expect('${wire.url} ${wire.body}', isNot(contains('reset')));
      expect('${wire.url} ${wire.body}', isNot(contains('stash')));
      expect(
        '${wire.url} ${wire.body} ${wire.headers}',
        isNot(contains(_patCanary)),
      );
    },
  );

  test('local status is a GET and absent counts never become zero', () async {
    final api = apiWith(
      (request) async => _json(_status(includeCounts: false)),
    );

    final status = await api.status(_session);

    expect(requests.single.method, 'GET');
    expect(
      requests.single.url.path,
      '/cloud/v1/studio/sessions/$_serverSession/git/status',
    );
    expect(requests.single.url.query, isEmpty);
    expect(status.ahead, isNull);
    expect(status.behind, isNull);
    expect(status.dirty, isTrue);
  });

  test(
    'diff uses the canonical path query and redacts bounded real patches',
    () async {
      final patch =
          'diff --git a/lib/main.dart b/lib/main.dart\n'
          '--- a/lib/main.dart\n'
          '+++ b/lib/main.dart\n'
          '@@ -1 +1 @@\n'
          '-void old() {}\n'
          '+const token = "$_patCanary";\n';
      final api = apiWith(
        (request) async =>
            _json(<String, Object>{'patch': patch, 'truncated': true}),
      );

      final diff = await api.diff(_session, path: 'lib/main.dart');

      expect(requests.single.method, 'GET');
      expect(
        requests.single.url.path,
        '/cloud/v1/studio/sessions/$_serverSession/git/diff',
      );
      expect(requests.single.url.queryParameters, <String, String>{
        'path': 'lib/main.dart',
      });
      expect(diff.patch, contains('diff --git'));
      expect(diff.patch, contains('[redacted]'));
      expect(diff.patch, isNot(contains(_patCanary)));
      expect(diff.truncated, isTrue);
    },
  );

  test(
    'combined diff reads staged and unstaged records without mutation',
    () async {
      final api = apiWith((request) async {
        final staged = request.url.queryParameters['staged'] == 'true';
        return _json(<String, Object>{
          'patch': staged
              ? 'diff --git a/lib/staged.dart b/lib/staged.dart\n'
                    '@@ -0,0 +1 @@\n'
                    '+staged\n'
              : 'diff --git a/lib/worktree.dart b/lib/worktree.dart\n'
                    '@@ -1 +1 @@\n'
                    '-old\n'
                    '+new\n',
          'truncated': false,
        });
      });

      final diff = await api.combinedDiff(_session);

      expect(requests, hasLength(2));
      expect(requests.every((request) => request.method == 'GET'), isTrue);
      expect(requests.first.url.queryParameters, isEmpty);
      expect(requests.last.url.queryParameters, <String, String>{
        'staged': 'true',
      });
      expect(diff.patch, contains('lib/worktree.dart'));
      expect(diff.patch, contains('lib/staged.dart'));
      expect(diff.parts, hasLength(2));
      expect(diff.parts.first.staged, isFalse);
      expect(diff.parts.last.staged, isTrue);
      expect(diff.parts.first.patch, contains('lib/worktree.dart'));
      expect(diff.parts.last.patch, contains('lib/staged.dart'));
      expect(diff.truncated, isFalse);
      expect(requests.any((request) => request.body.isNotEmpty), isFalse);
    },
  );

  test(
    'combined diff shares one byte budget across exact scoped content',
    () async {
      final unstagedPatch = 'u' * (studioDiffMaxBytes - 20);
      final stagedPatch = 's' * studioDiffMaxBytes;
      final api = apiWith((request) async {
        final staged = request.url.queryParameters['staged'] == 'true';
        return _json(<String, Object>{
          'patch': staged ? stagedPatch : unstagedPatch,
          'truncated': false,
        });
      });

      final diff = await api.combinedDiff(_session);
      final joinedParts = <String>[
        for (final part in diff.parts) part.patch,
      ].join('\n');

      expect(diff.parts, hasLength(2));
      expect(diff.parts.first.staged, isFalse);
      expect(diff.parts.last.staged, isTrue);
      expect(joinedParts, diff.patch);
      expect(utf8.encode(joinedParts).length, studioDiffMaxBytes);
      expect(utf8.encode(diff.patch).length, studioDiffMaxBytes);
      expect(
        utf8.encode(diff.parts.last.patch).length,
        lessThan(studioDiffMaxBytes),
      );
      expect(diff.patch, endsWith(diff.parts.last.patch));
      expect(diff.truncated, isTrue);
      expect(requests, hasLength(2));
    },
  );

  test(
    'diff enforces the gateway byte cap without pretending completeness',
    () async {
      final api = apiWith(
        (request) async => _json(<String, Object>{
          'patch': 'a' * ((256 * 1024) + 100),
          'truncated': false,
        }),
      );

      final diff = await api.diff(_session);

      expect(utf8.encode(diff.patch).length, lessThanOrEqualTo(256 * 1024));
      expect(diff.truncated, isTrue);
    },
  );

  test(
    'logs return bounded redacted commit records with no invented cursor',
    () async {
      final api = apiWith(
        (request) async => _json(<String, Object>{
          'items': <Object>[
            for (var index = 0; index < 60; index++)
              <String, Object>{
                'sha': 'sha-$index',
                'subject': index == 0
                    ? 'credential $_patCanary'
                    : 'commit $index',
                'authoredAt': '2026-10-24T18:00:00.000Z',
              },
          ],
        }),
      );

      final page = await api.logs(_session, limit: 500);

      expect(requests.single.method, 'GET');
      expect(
        requests.single.url.path,
        '/cloud/v1/studio/sessions/$_serverSession/git/logs',
      );
      expect(requests.single.url.queryParameters, <String, String>{
        'limit': '50',
      });
      expect(page.items, hasLength(50));
      expect(page.items.first.sha, 'sha-0');
      expect(page.items.first.subject, isNot(contains(_patCanary)));
      expect(
        page.items.first.authoredAt,
        DateTime.parse('2026-10-24T18:00:00.000Z'),
      );
      expect(page.truncated, isTrue);
      expect(page.nextCursor, isNull);
      expect(
        '${requests.single.url} ${requests.single.body}',
        isNot(contains(_patCanary)),
      );
    },
  );

  test(
    'a cursor is refused because the current gateway only supports bounded limit',
    () async {
      final api = apiWith(
        (request) async => _json(<String, Object>{'items': <Object>[]}),
      );

      await expectLater(
        api.logs(_session, cursor: 'older-page'),
        throwsA(
          isA<CloudApiException>().having(
            (error) => error.code,
            'code',
            'unsupported_cursor',
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'dirty diverged sync stays needs merge without reset stash or zero counts',
    () async {
      final api = apiWith(
        (request) async => _json(<String, Object>{
          'status': 'needs_merge',
          'dirty': true,
          'branch': 'main',
          'message': 'Commit or merge your changes before syncing.',
          'reason': 'diverged',
        }),
      );

      final result = await api.sync(_session);

      expect(result.status, 'needs_merge');
      expect(result.needsMerge, isTrue);
      expect(result.reason, 'diverged');
      expect(result.ahead, isNull);
      expect(result.behind, isNull);
      expect(result.message, contains('merge'));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, endsWith('/git/sync'));
      expect(requests.single.body, isEmpty);
      expect(
        '${requests.single.url} ${requests.single.body}',
        isNot(contains('reset')),
      );
      expect(
        '${requests.single.url} ${requests.single.body}',
        isNot(contains('stash')),
      );
    },
  );

  test('file search reads real bounded path records', () async {
    final api = apiWith(
      (request) async => _json(<String, Object>{
        'items': <Object>[
          <String, Object>{'path': 'lib/main.dart', 'name': 'main.dart'},
        ],
        'truncated': true,
      }),
    );

    final page = await api.search(
      _session,
      query: 'main',
      path: 'lib',
      limit: 500,
    );

    expect(requests.single.method, 'GET');
    expect(
      requests.single.url.path,
      '/cloud/v1/studio/sessions/$_serverSession/files/search',
    );
    expect(requests.single.url.queryParameters, <String, String>{
      'q': 'main',
      'path': 'lib',
      'limit': '100',
    });
    expect(page.items.single.path, 'lib/main.dart');
    expect(page.items.single.name, 'main.dart');
    expect(page.truncated, isTrue);
  });
}
