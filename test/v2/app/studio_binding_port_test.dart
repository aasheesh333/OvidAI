import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_git_api.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/app/v2_work_routes.dart';

/// The Studio binding is the GATEWAY's binding: a clone is only recorded when
/// the gateway says it happened, and the Studio send gate never opens on a
/// refused clone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String base = 'https://cloud.test/cloud/v1';
  const String localId = 'studio-session';
  const String serverId = '0199aaaa-0000-7000-8000-00000000e001';

  late AppState app;
  late List<http.Request> requests;

  GitHubStudioBindingPort portWith(
    Future<http.Response> Function(http.Request) handler,
  ) {
    requests = <http.Request>[];
    final rest = CloudRestClient(
      httpClient: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
      headers: CloudHeaders.forTest(),
      restBase: base,
    );
    return GitHubStudioBindingPort(api: StudioGitApi(rest: rest));
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    final session = ChatSession(
      id: localId,
      title: 'Studio',
      model: 'auto',
      createdAt: DateTime(2026, 10, 21),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    CloudSessionStore.installForTest(
      CloudSessionStore.forTest(idMap: const {localId: serverId}),
    );
  });

  tearDown(() {
    StudioBindingPort.instance?.dispose();
    StudioBindingPort.installForTest(null);
    CloudSessionStore.resetForTest();
    AppState.resetTestInstance();
  });

  test('before the gateway answers, the port is not ready', () {
    final port = portWith((r) async => json(<String, Object>{}));
    StudioBindingPort.installForTest(port);

    expect(port.ready, isFalse);
    expect(port.bindingFor(localId), isNull);
  });

  test('loadConnection is the gateway answer, not a device login', () async {
    final port = portWith(
      (r) async =>
          json({'connected': true, 'login': 'octocat', 'source': 'mcp'}),
    );
    StudioBindingPort.installForTest(port);

    final connection = await port.loadConnection();

    expect(requests.single.url.toString(), '$base/studio/github');
    expect(connection?.connected, isTrue);
    expect(port.ready, isTrue);
    expect(port.accountLabel, 'octocat');
  });

  test('a disconnected gateway is not ready', () async {
    final port = portWith(
      (r) async => json({'connected': false, 'login': null, 'source': 'mcp'}),
    );
    StudioBindingPort.installForTest(port);

    await port.loadConnection();

    expect(port.ready, isFalse);
  });

  test('bind records the binding the clone returned', () async {
    final port = portWith(
      (r) async => json({
        'sessionId': serverId,
        'repo': 'ovid/app',
        'repoDir': 'app',
        'branch': 'feature/x',
        'bindingStored': true,
      }, 201),
    );
    StudioBindingPort.installForTest(port);

    await port.bind(localId, repo: 'ovid/app', branch: 'feature/x');

    expect(requests.single.method, 'POST');
    expect(
      requests.single.url.toString(),
      '$base/studio/sessions/$serverId/git/clone',
    );
    final session = app.sessionById(localId)!;
    expect(session.repo, 'ovid/app');
    expect(session.branch, 'feature/x');
    final binding = port.bindingFor(localId);
    expect(binding?.repo, 'ovid/app');
    expect(binding?.branch, 'feature/x');
    expect(binding?.ready, isTrue);
  });

  test('a 503 clone leaves the Studio gate closed', () async {
    final port = portWith(
      (r) async => json({
        'error': {
          'code': 'studio_git_unavailable',
          'message': 'Git operations are not available on this deployment yet.',
        },
      }, 503),
    );
    StudioBindingPort.installForTest(port);

    await expectLater(
      port.bind(localId, repo: 'ovid/app', branch: 'main'),
      throwsA(
        isA<StudioAccessException>().having(
          (e) => e.message,
          'message',
          'Git operations are not available on this deployment yet.',
        ),
      ),
    );
    expect(app.sessionById(localId)!.repo, isNull);
    expect(port.bindingFor(localId), isNull);
  });

  test('loadSessionGit hydrates the binding and the capability flag', () async {
    final port = portWith(
      (r) async => json({
        'sessionId': serverId,
        'repo': {
          'repo': 'ovid/app',
          'repoDir': 'app',
          'branch': 'main',
          'updatedAt': '2026-10-02T08:00:00Z',
        },
        'git': {'available': false, 'reason': 'studio_git_unavailable'},
      }),
    );
    StudioBindingPort.installForTest(port);

    final state = await port.loadSessionGit(localId);

    expect(
      requests.single.url.toString(),
      '$base/studio/sessions/$serverId/git',
    );
    expect(state?.available, isFalse);
    expect(state?.reason, 'studio_git_unavailable');
    expect(port.bindingFor(localId)?.repo, 'ovid/app');
    expect(port.bindingFor(localId)?.branch, 'main');
  });

  test('another chat\'s selection never opens a new chat\'s gate', () async {
    final other = ChatSession(
      id: 'other-session',
      title: 'Other',
      model: 'auto',
      createdAt: DateTime(2026, 10, 20),
    );
    app.sessions.add(other);
    app.setRepoForSession(other.id, 'acme/legacy');
    app.setBranchForSession(other.id, 'main');

    final port = portWith((r) async => json(<String, Object>{}));
    StudioBindingPort.installForTest(port);

    // `getRepoForSession` falls back to the last global selection; the send
    // gate must not, or a fresh Studio chat would look bound.
    expect(port.bindingFor(localId), isNull);
    expect(port.bindingFor(other.id)?.repo, 'acme/legacy');
  });
}
