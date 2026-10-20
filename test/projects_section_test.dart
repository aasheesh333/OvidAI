import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/projects_section.dart';

ProjectDto project(String id, String name, {int sessions = 0, int files = 0, int cap = 80}) =>
    ProjectDto(
      id: id,
      name: name,
      createdAt: DateTime.utc(2026, 10, 20),
      updatedAt: DateTime.utc(2026, 10, 20),
      sessionCount: sessions,
      fileCount: files,
      fileCap: cap,
    );

void main() {
  testWidgets('renders project rows with plan file counts and nested sessions', (tester) async {
    String? toggled;
    var created = 0;
    ProjectDto? renamed;
    ProjectDto? deleted;

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: ProjectsSection(
            projects: [
              project('p1', 'Alpha', sessions: 1, files: 3),
              project('p2', 'Beta', files: 9, cap: 150),
            ],
            expanded: const {'p1'},
            sessionTiles: const {
              'p1': [Text('Session A')],
            },
            onToggle: (id) => toggled = id,
            onCreate: () => created++,
            onRename: (p) => renamed = p,
            onDelete: (p) => deleted = p,
          ),
        ),
      ),
    );

    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('3/80 files · 1 session'), findsOneWidget);
    expect(find.text('9/150 files · 0 sessions'), findsOneWidget);
    expect(find.text('Session A'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    expect(toggled, 'p1');

    await tester.tap(find.byKey(const ValueKey('projects-create')));
    expect(created, 1);

    await tester.tap(find.byTooltip('Project actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename project'));
    await tester.pumpAndSettle();
    expect(renamed?.id, 'p1');

    await tester.tap(find.byTooltip('Project actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();
    expect(deleted?.id, 'p1');
  });

  testWidgets('shows an empty hint when there are no projects', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: ProjectsSection(
            projects: const [],
            expanded: const {},
            sessionTiles: const {},
            onToggle: (_) {},
            onCreate: () {},
            onRename: (_) {},
            onDelete: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('No projects yet'), findsOneWidget);
  });

  testWidgets('Add to Project sheet offers No project and every project', (tester) async {
    ProjectSelection? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showAddToProjectSheet(
                  context,
                  sessionTitle: 'Chat one',
                  projects: [project('p1', 'Alpha', files: 2)],
                  currentProjectId: 'p1',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add to Project'), findsOneWidget);
    expect(find.text('Chat one'), findsOneWidget);
    expect(find.text('No project'), findsOneWidget);
    expect(find.text('2/80 files'), findsOneWidget);
    // The current project is checked.
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(result?.projectId, 'p1');
  });
}
