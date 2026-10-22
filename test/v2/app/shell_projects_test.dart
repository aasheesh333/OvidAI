import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_pins.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';
import 'package:ovid_ai/ui/v2/sidebar/project_detail_page.dart';
import 'package:ovid_ai/ui/v2/sidebar/projects_page.dart';

/// The shell must hand the rebuilt Projects page its real persistence hooks:
/// create/rename/delete mapped through [ProjectsController], the project's
/// real memory files, and the screen's own action menu (not a duplicate one).
class _ProjectsRest extends CloudRestClient {
  _ProjectsRest()
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<ProjectDto> projects = <ProjectDto>[
    ProjectDto(
      id: 'p1',
      name: 'Alpha',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 2),
      sessionCount: 2,
      fileCount: 1,
      fileCap: 80,
      fileBytes: 12,
      fileBreakdown: const ProjectFileBreakdown(memory: 1),
    ),
  ];

  final Map<String, String> memory = <String, String>{
    'MEMORY.md': 'Remember this project.',
  };

  bool memoryListed = false;
  int created = 0;
  int renamed = 0;
  int deleted = 0;

  @override
  Future<ProjectsPayload> listProjectsPayload() async =>
      ProjectsPayload(items: List<ProjectDto>.of(projects), turnProjectRefs: false);

  @override
  Future<ProjectDto> createProject(String name) async {
    created++;
    final dto = ProjectDto(
      id: 'p${projects.length + 1}',
      name: name,
      createdAt: DateTime(2026, 10, 3),
      updatedAt: DateTime(2026, 10, 3),
      sessionCount: 0,
      fileCount: 0,
      fileCap: 80,
    );
    projects.add(dto);
    return dto;
  }

  @override
  Future<ProjectDto> renameProject(String id, String name) async {
    renamed++;
    final index = projects.indexWhere((project) => project.id == id);
    final old = projects[index];
    final dto = ProjectDto(
      id: old.id,
      name: name,
      createdAt: old.createdAt,
      updatedAt: DateTime(2026, 10, 4),
      sessionCount: old.sessionCount,
      fileCount: old.fileCount,
      fileCap: old.fileCap,
      fileBytes: old.fileBytes,
      fileBreakdown: old.fileBreakdown,
    );
    projects[index] = dto;
    return dto;
  }

  @override
  Future<void> deleteProject(String id) async {
    deleted++;
    projects.removeWhere((project) => project.id == id);
  }

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path.endsWith('/memory')) {
      memoryListed = true;
      return <String, dynamic>{
        'items': [
          for (final entry in memory.entries)
            <String, dynamic>{
              'name': entry.key,
              'sizeBytes': entry.value.length,
            },
        ],
        'scope': 'project',
      };
    }
    final name = path.split('/').last;
    return <String, dynamic>{
      'name': name,
      'content': memory[name] ?? '',
      'revision': 'r1',
    };
  }

  @override
  Future<Map<String, dynamic>> putJson(
    String path, {
    Object? body,
    Duration? timeout,
  }) async {
    final name = path.split('/').last;
    final content = (body as Map?)?['content'] as String? ?? '';
    memory[name] = content;
    return <String, dynamic>{
      'name': name,
      'content': content,
      'revision': 'r2',
    };
  }

  @override
  Future<void> delete(String path, {Object? body, Duration? timeout}) async {
    memory.remove(path.split('/').last);
  }
}

class _ProjectsSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();
  int? _closeCode;

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String frame) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed.isClosed) return;
    _closeCode = code;
    if (!_frames.isClosed) await _frames.close();
    _closed.add(null);
    await _closed.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WsMultiplexer ws;
  late CloudAgentFacade facade;
  late _ProjectsRest rest;
  late ProjectsController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    // Building the app state is the side effect these tests need.
    AppState.createForTest();
    rest = _ProjectsRest();
    CloudRestClient.installForTest(rest);
    controller = ProjectsController(rest: rest);
    ProjectsController.installForTest(controller);
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async => _ProjectsSocket(),
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    facade = CloudAgentFacade(rest: rest, ws: ws, store: null);
    CloudAgentFacade.installForTest(facade);
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();
  });

  tearDown(() async {
    await ws.disconnect();
    facade.dispose();
    CloudAgentFacade.resetForTest();
    ProjectsController.resetForTest();
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();
    AppState.resetTestInstance();
    v2SessionRefResolver = null;
  });

  Future<void> openProjects(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('New project'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectsPage), findsOneWidget);
  }

  Future<void> openProjectMenu(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey<String>('v2-project-menu-$id')));
    await tester.pumpAndSettle();
  }

  testWidgets('the list uses the controller and its real memory endpoint', (
    tester,
  ) async {
    await openProjects(tester);
    expect(find.text('Alpha'), findsOneWidget);

    await openProjectMenu(tester, 'p1');
    // The screen's own menu: rename/delete/memory, no shell duplicate.
    expect(find.text('Project memory'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete project'), findsOneWidget);

    await tester.tap(find.text('Project memory'));
    await tester.pumpAndSettle();
    expect(rest.memoryListed, isTrue);
    expect(find.byType(ProjectDetailContent), findsOneWidget);
    expect(find.text('MEMORY.md'), findsOneWidget);
  });

  testWidgets('create, rename and delete map through ProjectsController', (
    tester,
  ) async {
    await openProjects(tester);

    // Create.
    await tester.tap(
      find.descendant(
        of: find.byType(ProjectsPage),
        matching: find.bySemanticsLabel('New project'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Beta',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pumpAndSettle();
    expect(rest.created, 1);
    expect(find.text('Beta'), findsOneWidget);

    // Rename.
    await openProjectMenu(tester, 'p1');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Alpha renamed',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-rename-project')));
    await tester.pumpAndSettle();
    expect(rest.renamed, 1);
    expect(find.text('Alpha renamed'), findsOneWidget);

    // Delete.
    await openProjectMenu(tester, 'p1');
    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-delete-project-confirm')));
    await tester.pumpAndSettle();
    expect(rest.deleted, 1);
    expect(find.text('Alpha renamed'), findsNothing);
  });
}
