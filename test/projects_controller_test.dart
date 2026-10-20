import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/state.dart';

Map<String, Object?> projectJson(
  String id,
  String name, {
  int sessionCount = 0,
  int fileCount = 0,
  int fileCap = 80,
}) =>
    {
      'id': id,
      'name': name,
      'createdAt': '2026-10-20T10:00:00.000Z',
      'updatedAt': '2026-10-20T10:00:00.000Z',
      'sessionCount': sessionCount,
      'fileCount': fileCount,
      'fileCap': fileCap,
    };

Map<String, Object?> sessionJson(String id, {String? projectId}) => {
      'id': id,
      'title': 'Chat',
      'mode': 'auto',
      'projectId': projectId,
      'createdAt': '2026-10-20T10:00:00.000Z',
      'updatedAt': '2026-10-20T10:00:00.000Z',
    };

CloudRestClient mockRest(
  List<http.Request> log,
  Future<http.Response> Function(http.Request) handler,
) =>
    CloudRestClient(
      restBase: 'https://cloud.test',
      headers: CloudHeaders.forTest(),
      httpClient: MockClient((request) async {
        log.add(request);
        return handler(request);
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppState.resetTestInstance();
    AppState.createForTest();
    ProjectsController.resetForTest();
  });

  tearDown(() {
    AppState.resetTestInstance();
    ProjectsController.resetForTest();
  });

  test('refresh lists owner projects and exposes the plan cap', () async {
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (_) async => http.Response(
            jsonEncode({
              'items': [projectJson('p1', 'Alpha', fileCount: 3)],
            }),
            200,
          )),
    );
    addTearDown(controller.dispose);

    expect(controller.loadedOnce, isFalse);
    await controller.refresh();

    expect(log.single.method, 'GET');
    expect(log.single.url.path, '/projects');
    expect(controller.loadedOnce, isTrue);
    expect(controller.projects.single.name, 'Alpha');
    expect(controller.projects.single.fileCount, 3);
    expect(controller.projects.single.fileCap, 80);
    expect(controller.error, isNull);
  });

  test('create posts the trimmed name and appends the server row', () async {
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode(projectJson('p-new', 'Research')),
            201,
          );
        }
        return http.Response('{"items":[]}', 200);
      }),
    );
    addTearDown(controller.dispose);

    final created = await controller.create('  Research  ');
    expect(created!.id, 'p-new');
    expect(log.single.method, 'POST');
    expect(jsonDecode(log.single.body), {'name': 'Research'});
    expect(controller.projects.map((p) => p.name), ['Research']);
  });

  test('rename patches the project and replaces the row', () async {
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [projectJson('p1', 'Old')],
            }),
            200,
          );
        }
        return http.Response(jsonEncode(projectJson('p1', 'New')), 200);
      }),
    );
    addTearDown(controller.dispose);
    await controller.refresh();

    expect(await controller.rename('p1', 'New'), isTrue);
    expect(log.last.method, 'PATCH');
    expect(log.last.url.path, '/projects/p1');
    expect(jsonDecode(log.last.body), {'name': 'New'});
    expect(controller.projects.single.name, 'New');
  });

  test('delete removes the project and detaches local chats', () async {
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [projectJson('p1', 'Alpha', sessionCount: 1)],
            }),
            200,
          );
        }
        return http.Response('', 204);
      }),
    );
    addTearDown(controller.dispose);
    final chat = ChatSession(id: 's1', title: 'Chat', model: 'm', projectId: 'p1');
    AppState.I.sessions.add(chat);
    await controller.refresh();

    expect(await controller.delete('p1'), isTrue);
    expect(log.last.method, 'DELETE');
    expect(log.last.url.path, '/projects/p1');
    expect(controller.projects, isEmpty);
    expect(chat.projectId, isNull);
  });

  test('moveSession updates the local chat and the visible counts', () async {
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [
                projectJson('p1', 'Alpha'),
                projectJson('p2', 'Beta', sessionCount: 1),
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode(sessionJson('s1', projectId: 'p1')),
          200,
        );
      }),
    );
    addTearDown(controller.dispose);
    final chat = ChatSession(id: 's1', title: 'Chat', model: 'm');
    AppState.I.sessions.add(chat);
    await controller.refresh();

    expect(await controller.moveSession('s1', 'p1'), isTrue);
    expect(log.last.method, 'POST');
    expect(log.last.url.path, '/sessions/s1/project');
    expect(jsonDecode(log.last.body), {'projectId': 'p1'});
    expect(chat.projectId, 'p1');
    expect(controller.byId('p1')!.sessionCount, 1);
    expect(controller.byId('p2')!.sessionCount, 1);
  });

  test('a server rejection surfaces the typed message without throwing', () async {
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (_) async => http.Response(
            '{"error":{"code":"not_found","message":"Project not found."}}',
            404,
          )),
    );
    addTearDown(controller.dispose);

    expect(await controller.moveSession('s1', 'missing'), isFalse);
    expect(controller.error, 'Project not found.');
  });
}
