import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/projects_port_adapter.dart';
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

  test('chat port follows the gateway-advertised @project capability (fail-safe)', () async {
    // The installed chat adapter must never hard-code support: an older
    // gateway that does not advertise `capabilities.turnProjectRefs` keeps
    // the feature hidden so a strict send body cannot 400.
    ProjectsControllerPort.serverSupportsTurnProjectRefs = null;

    final ids = ['0192f0a0-0000-7000-8000-0000000000a1'];
    ProjectsController controllerFor(Map<String, Object?> body) {
      final controller = ProjectsController(
        rest: mockRest(<http.Request>[], (_) async => http.Response(jsonEncode(body), 200)),
      );
      addTearDown(controller.dispose);
      return controller;
    }

    final advertised = controllerFor({
      'items': [projectJson(ids[0], 'Work')],
      'capabilities': {'turnProjectRefs': true},
    });
    await advertised.refresh();
    expect(ProjectsControllerPort(controller: advertised).supportsTurnProjectRefs, isTrue);

    final old = controllerFor({
      'items': [projectJson(ids[0], 'Work')],
      'capabilities': {'turnProjectRefs': false},
    });
    await old.refresh();
    expect(ProjectsControllerPort(controller: old).supportsTurnProjectRefs, isFalse);

    // No successful load yet (offline start) -> still false.
    final offline = controllerFor({'items': <Object>[], 'capabilities': {'turnProjectRefs': true}});
    expect(ProjectsControllerPort(controller: offline).supportsTurnProjectRefs, isFalse);

    ProjectsControllerPort.serverSupportsTurnProjectRefs = null;
  });

  test('port enables @project refs and resolves only known uuid tokens', () async {
    // Project ids are UUIDs on the wire; the composer token is `@project:<uuid>`.
    final ids = [
      for (var i = 1; i <= 6; i++)
        '0192f0a0-0000-7000-8000-00000000000$i',
    ];
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (_) async => http.Response(
            jsonEncode({
              'items': [
                for (var i = 0; i < ids.length; i++)
                  projectJson(ids[i], 'Project ${i + 1}'),
              ],
              'capabilities': {'turnProjectRefs': true},
            }),
            200,
          )),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    final port = ProjectsPortAdapter(controller);
    addTearDown(port.dispose);

    expect(port.supportsTurnProjectRefs, isTrue);
    expect(port.supportsPin, isTrue);
    expect(port.ready, isTrue);
    expect(port.projects.map((p) => p.id), ids);
    expect(port.mentionToken(port.projects.first), '@project:${ids[0]} ');

    // Exact token the menu writes; surrounding prose is preserved.
    expect(
      port.projectRefsIn('use @project:${ids[0]} and @project:${ids[1]} please'),
      [ids[0], ids[1]],
    );
    // Malformed and unknown ids never become refs (a stale token must not
    // turn the whole send into a 400).
    expect(
      port.projectRefsIn(
        '@project:not-a-uuid @project:00000000-0000-7000-8000-000000000000',
      ),
      isEmpty,
    );
    // Duplicates collapse (the server rejects duplicates) and the list is
    // capped at the server's MAX_PROJECT_REFS = 5.
    expect(
      port.projectRefsIn('@project:${ids[0]} @project:${ids[0]} @project:${ids[1]}'),
      [ids[0], ids[1]],
    );
    expect(
      port.projectRefsIn([for (final id in ids) '@project:$id'].join(' ')),
      ids.take(5).toList(),
    );
  });

  test('the @project capability is FAIL-SAFE: false until the server advertises it', () async {
    final ids = ['0192f0a0-0000-7000-8000-000000000001'];
    final log = <http.Request>[];
    final controller = ProjectsController(
      rest: mockRest(log, (_) async => http.Response(
            jsonEncode({
              'items': [projectJson(ids[0], 'Alpha')],
              // An older gateway: no capabilities object at all.
            }),
            200,
          )),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    final port = ProjectsPortAdapter(controller);
    addTearDown(port.dispose);

    expect(port.supportsTurnProjectRefs, isFalse);
    // No token is parsed, so no send can carry a field the strict body
    // would reject.
    expect(port.projectRefsIn('@project:${ids[0]}'), isEmpty);

    // A capability payload that says false stays false.
    final explicitFalse = ProjectsPayload.fromJson({
      'items': <Object>[],
      'capabilities': {'turnProjectRefs': false},
    });
    expect(explicitFalse.turnProjectRefs, isFalse);
  });

  test('ProjectDto parses fileBytes and the per-bucket breakdown additively', () {
    final dto = ProjectDto.fromJson({
      ...projectJson('p1', 'Alpha', fileCount: 3, fileCap: 80),
      'fileBytes': 4096,
      'fileBreakdown': {'memory': 1, 'attachments': 1, 'artifacts': 1},
    });
    expect(dto.fileBytes, 4096);
    expect(dto.fileBreakdown.memory, 1);
    expect(dto.fileBreakdown.attachments, 1);
    expect(dto.fileBreakdown.artifacts, 1);

    // Older servers omit the fields: defaults stay truthful (zero), not null.
    final legacy = ProjectDto.fromJson(projectJson('p2', 'Legacy'));
    expect(legacy.fileBytes, 0);
    expect(legacy.fileBreakdown.memory, 0);
  });
}
