import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    ProjectsController.resetForTest();
  });

  tearDown(() {
    AppState.resetTestInstance();
    ProjectsController.resetForTest();
  });

  testWidgets('sidebar groups project chats and offers Add to Project', (tester) async {
    final rest = CloudRestClient(
      restBase: 'https://cloud.test',
      headers: CloudHeaders.forTest(),
      httpClient: MockClient((request) async {
        if (request.url.path == '/projects') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'p1',
                  'name': 'Alpha',
                  'createdAt': '2026-10-20T10:00:00.000Z',
                  'updatedAt': '2026-10-20T10:00:00.000Z',
                  'sessionCount': 1,
                  'fileCount': 4,
                  'fileCap': 80,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{"items":[]}', 200);
      }),
    );
    final controller = ProjectsController(rest: rest);
    addTearDown(controller.dispose);
    await controller.refresh();
    ProjectsController.installForTest(controller);

    AppState.I.sessions
      ..clear()
      ..addAll([
        ChatSession(id: 's1', title: 'Standalone', model: 'm'),
        ChatSession(id: 's2', title: 'Projected', model: 'm', projectId: 'p1'),
      ]);
    AppState.I.activeSessionId = 's1';

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: Row(children: [SessionsSidebar(isDrawer: false)])),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.textContaining('4/80 files'), findsOneWidget);
    // Ungrouped chats stay in the main list; project chats are nested and
    // hidden while the folder is collapsed.
    expect(find.text('Standalone'), findsOneWidget);
    expect(find.text('Projected'), findsNothing);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Projected'), findsOneWidget);

    await tester.longPress(find.text('Standalone'));
    await tester.pumpAndSettle();
    expect(find.text('Add to Project'), findsOneWidget);

    await tester.tap(find.text('Add to Project'));
    await tester.pumpAndSettle();
    expect(find.text('No project'), findsOneWidget);
    expect(find.text('Alpha'), findsWidgets);
  });
}
