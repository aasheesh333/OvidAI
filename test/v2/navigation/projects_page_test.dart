import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/projects_page.dart';

const _project = V2Project(
  id: 'pr1',
  name: 'Mobile App Redesign',
  chatCount: 12,
  shared: true,
);

const _brandProject = V2Project(
  id: 'pr2',
  name: 'Brand Voice Guidelines',
  chatCount: 4,
);

const _longProject = V2Project(
  id: 'long',
  name: 'Website redesign for the international launch campaign',
  chatCount: 1234,
  shared: true,
);

V2ProjectsData _contentData([
  List<V2Project> projects = const <V2Project>[_project, _brandProject],
]) => V2ProjectsData(projects: projects);

/// Four rows with distinct timestamps, names and counts so each order is
/// distinguishable. Four is the count at which the sort chips appear.
List<V2Project> _sortableProjects() {
  final now = DateTime.utc(2026, 10, 22, 12);
  return <V2Project>[
    V2Project(
      id: 'alpha',
      name: 'Alpha',
      chatCount: 9,
      updatedAt: now.subtract(const Duration(days: 3)),
    ),
    V2Project(id: 'zebra', name: 'Zebra', chatCount: 1, updatedAt: now),
    V2Project(
      id: 'mango',
      name: 'Mango',
      chatCount: 4,
      updatedAt: now.subtract(const Duration(days: 1)),
    ),
    V2Project(
      id: 'banana',
      name: 'Banana',
      chatCount: 1,
      updatedAt: now.subtract(const Duration(days: 2)),
    ),
  ];
}

/// The visible row order, top to bottom.
List<String> _rowOrder(WidgetTester tester) {
  const ids = <String>['alpha', 'zebra', 'mango', 'banana'];
  final rows = <(double, String)>[
    for (final id in ids)
      (
        tester.getTopLeft(find.byKey(ValueKey<String>('v2-project-$id'))).dy,
        id,
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return <String>[for (final row in rows) row.$2];
}

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

Widget _scaled(Widget child, {required double textScale, ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child,
      ),
    ),
  );
}

void _useScreen(
  WidgetTester tester, {
  required double width,
  double height = 800,
}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
}

void _resetScreen(WidgetTester tester) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openMenu(WidgetTester tester, String projectId) async {
  await tester.tap(find.byKey(ValueKey<String>('v2-project-menu-$projectId')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('content shows one header and one-line project rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          onProjectTap: (_) {},
          deleteProject: (_) async => const V2ProjectMutation.ok(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('PROJECTS'), findsNothing);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('12 chats'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);
    expect(find.text('Brand Voice Guidelines'), findsOneWidget);
    expect(find.text('4 chats'), findsOneWidget);
    expect(find.text('Personal'), findsNothing);
    expect(find.text('340 MB'), findsNothing);
    expect(find.text('Updated 4m ago'), findsNothing);
    expect(find.text('Group chats that share files and memory.'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('v2-project-menu-pr1')),
      findsOneWidget,
    );
  });

  testWidgets('content renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(ProjectsPage(data: _contentData()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);
  });

  testWidgets('long names stay on one line and ellipsize', (tester) async {
    await tester.pumpWidget(
      _app(ProjectsPage(data: _contentData(const <V2Project>[_longProject]))),
    );
    await tester.pumpAndSettle();

    final name = tester.widget<Text>(
      find.byKey(const ValueKey<String>('v2-project-name-long')),
    );
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state offers create when the caller can persist', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: const V2ProjectsData(),
          createProject: (_) async => const V2ProjectMutation.ok(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No projects'), findsOneWidget);
    expect(find.text('Create a project to group chats and memory.'), findsOneWidget);
    expect(find.byKey(const Key('v2-empty-new-project')), findsOneWidget);

    await tester.tap(find.byKey(const Key('v2-empty-new-project')));
    await tester.pumpAndSettle();

    expect(find.text('New project'), findsWidgets);
    expect(find.text('Project name'), findsOneWidget);
    expect(find.text('Create project'), findsOneWidget);
  });

  testWidgets('no create affordance when the caller cannot persist', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const ProjectsPage(data: V2ProjectsData())));
    await tester.pumpAndSettle();

    expect(find.text('No projects'), findsOneWidget);
    expect(find.byKey(const Key('v2-empty-new-project')), findsNothing);
    expect(find.byKey(const Key('v2-new-project')), findsNothing);
    expect(find.text('New project'), findsNothing);
  });

  testWidgets('row menu only renders when an action is wired', (tester) async {
    await tester.pumpWidget(_app(ProjectsPage(data: _contentData())));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
  });

  testWidgets('tapping a project reports it to the caller', (tester) async {
    V2Project? tapped;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          onProjectTap: (project) => tapped = project,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mobile App Redesign'));
    expect(tapped?.id, 'pr1');
  });

  testWidgets('the legacy actions hook still opens from the row', (
    tester,
  ) async {
    V2Project? actions;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          onProjectActions: (project) => actions = project,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester, 'pr1');
    expect(actions?.id, 'pr1');
  });

  testWidgets('create rejects empty and duplicate names, then inserts', (
    tester,
  ) async {
    V2ProjectDraft? draft;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          createProject: (value) async {
            draft = value;
            return const V2ProjectMutation.ok(
              project: V2Project(id: 'pr3', name: 'Brand site', chatCount: 0),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('v2-new-project')));
    await tester.pumpAndSettle();

    var create = tester.widget<OButton>(
      find.byKey(const Key('v2-create-project')),
    );
    expect(create.onPressed, isNull, reason: 'an empty name cannot be saved');

    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      '   ',
    );
    await tester.pump();
    create = tester.widget<OButton>(find.byKey(const Key('v2-create-project')));
    expect(create.onPressed, isNull, reason: 'whitespace is not a name');

    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      ' mobile app redesign ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pumpAndSettle();

    expect(find.text('That name is already in use.'), findsOneWidget);
    expect(draft, isNull);
    expect(find.text('Create project'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Brand site',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pumpAndSettle();

    expect(draft?.name, 'Brand site');
    expect(find.text('Brand site'), findsOneWidget);
    expect(find.text('0 chats'), findsOneWidget);
    expect(find.text('No projects'), findsNothing);
  });

  testWidgets('create inserts a project from an empty list', (tester) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: const V2ProjectsData(),
          createProject: (_) async => const V2ProjectMutation.ok(
            project: V2Project(id: 'pr3', name: 'Brand site', chatCount: 0),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('v2-empty-new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Brand site',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pumpAndSettle();

    expect(find.text('No projects'), findsNothing);
    expect(find.text('Brand site'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('v2-project-pr3')),
      findsOneWidget,
    );
  });

  testWidgets('create reports a persistence failure inline and stays open', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: const V2ProjectsData(),
          createProject: (_) async =>
              const V2ProjectMutation.failed('Could not reach the server.'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('v2-empty-new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Brand site',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pumpAndSettle();

    expect(find.text('Could not reach the server.'), findsOneWidget);
    expect(find.text('Create project'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('v2-project-pr3')), findsNothing);
  });

  testWidgets('the legacy create hook still reaches the caller', (
    tester,
  ) async {
    V2ProjectDraft? created;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: const V2ProjectsData(),
          onCreateProject: (draft) => created = draft,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('v2-empty-new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Brand site',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pumpAndSettle();

    expect(created?.name, 'Brand site');
  });

  testWidgets('rename persists and updates the row', (tester) async {
    V2Project? renamedProject;
    String? renamedTo;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          renameProject: (project, name) async {
            renamedProject = project;
            renamedTo = name;
            return const V2ProjectMutation.ok();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester, 'pr1');
    expect(find.text('Rename'), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('v2-project-name-field')),
    );
    expect(field.controller?.text, 'Mobile App Redesign');

    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Customer app',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-rename-project')));
    await tester.pumpAndSettle();

    expect(renamedProject?.id, 'pr1');
    expect(renamedTo, 'Customer app');
    expect(find.text('Customer app'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsNothing);
  });

  testWidgets('rename rejects a duplicate other project name', (tester) async {
    var called = false;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          renameProject: (project, name) async {
            called = true;
            return const V2ProjectMutation.ok();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester, 'pr1');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Brand Voice Guidelines',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-rename-project')));
    await tester.pumpAndSettle();

    expect(find.text('That name is already in use.'), findsOneWidget);
    expect(called, isFalse);
  });

  testWidgets('failed rename rolls the row back and reports inline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          renameProject: (project, name) async =>
              const V2ProjectMutation.failed('Name was rejected.'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester, 'pr1');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Rejected name',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-rename-project')));
    await tester.pumpAndSettle();

    expect(find.text('Name was rejected.'), findsOneWidget);
    final rowName = tester.widget<Text>(
      find.byKey(const ValueKey<String>('v2-project-name-pr1')),
    );
    expect(rowName.data, 'Mobile App Redesign');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Mobile App Redesign'), findsOneWidget);
  });

  testWidgets('memory action reports the project to the caller', (
    tester,
  ) async {
    V2Project? opened;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          onProjectMemory: (project) => opened = project,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester, 'pr1');
    expect(find.text('Project memory'), findsOneWidget);
    await tester.tap(find.text('Project memory'));
    await tester.pumpAndSettle();

    expect(opened?.id, 'pr1');
  });

  testWidgets('delete names the project, asks first, then removes the row', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    V2Project? deleted;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(const <V2Project>[_project]),
          deleteProject: (project) async {
            deleted = project;
            return const V2ProjectMutation.ok();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester, 'pr1');
    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();

    expect(find.text('Delete project?'), findsOneWidget);
    expect(find.textContaining('"Mobile App Redesign"'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Delete Mobile App Redesign, destructive'),
      findsOneWidget,
    );

    await tester.tap(find.text('Keep project'));
    await tester.pumpAndSettle();
    expect(deleted, isNull);
    expect(
      find.byKey(const ValueKey<String>('v2-project-pr1')),
      findsOneWidget,
    );

    await _openMenu(tester, 'pr1');
    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-delete-project-confirm')));
    await tester.pumpAndSettle();

    expect(deleted?.id, 'pr1');
    expect(find.byKey(const ValueKey<String>('v2-project-pr1')), findsNothing);
    expect(find.text('No projects'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('failed delete restores the row and reports why', (tester) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          deleteProject: (project) async =>
              const V2ProjectMutation.failed('Server refused.'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester, 'pr1');
    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-delete-project-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('v2-project-pr1')),
      findsOneWidget,
    );
    expect(find.text('Server refused.'), findsOneWidget);
  });

  testWidgets('loading state shows a skeleton and no actions', (tester) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: const V2ProjectsData(status: V2ProjectsStatus.loading),
          createProject: (_) async => const V2ProjectMutation.ok(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.byKey(const Key('v2-new-project')), findsNothing);
    expect(find.byKey(const Key('v2-empty-new-project')), findsNothing);
  });

  testWidgets('error state retries through the caller', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: const V2ProjectsData(
            status: V2ProjectsStatus.error,
            errorMessage: 'Offline.',
          ),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Projects did not load'), findsOneWidget);
    expect(find.text('Offline.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('row semantics announce name, count and share state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          onProjectTap: (_) {},
          onProjectMemory: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Mobile App Redesign, 12 chats, shared'),
      ),
      isSemantics(
        label: 'Mobile App Redesign, 12 chats, shared',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    expect(
      find.bySemanticsLabel('Project options for Mobile App Redesign'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('every state fits 320 dp at 200 % text in light and dark', (
    tester,
  ) async {
    _useScreen(tester, width: 320, height: 640);
    _resetScreen(tester);

    const states = <V2ProjectsData>[
      V2ProjectsData(status: V2ProjectsStatus.loading),
      V2ProjectsData(),
      V2ProjectsData(status: V2ProjectsStatus.error, errorMessage: 'Offline.'),
      V2ProjectsData(projects: <V2Project>[_project, _brandProject]),
    ];

    for (final dark in <bool>[false, true]) {
      for (final data in states) {
        await tester.pumpWidget(
          _scaled(
            ProjectsPage(data: data, onRetry: () {}),
            textScale: 2,
            theme: dark ? OTheme.dark() : OTheme.light(),
          ),
        );
        // Loading skeletons animate forever, so settle one frame rather than
        // waiting for an animation count to reach zero.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.takeException(),
          isNull,
          reason: '${data.status} in ${dark ? 'dark' : 'light'}',
        );
      }
    }
  });

  testWidgets('rows fit 320 to 1280 at 100 % and 200 % in both themes', (
    tester,
  ) async {
    _resetScreen(tester);

    for (final width in <double>[320, 360, 412, 600, 800, 1024, 1280]) {
      for (final scale in <double>[1, 2]) {
        for (final dark in <bool>[false, true]) {
          _useScreen(tester, width: width);
          await tester.pumpWidget(
            _scaled(
              ProjectsPage(
                data: _contentData(const <V2Project>[_longProject]),
                onProjectTap: (_) {},
                onProjectMemory: (_) {},
              ),
              textScale: scale,
              theme: dark ? OTheme.dark() : OTheme.light(),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason:
                '${width.toInt()} dp / ${scale}x / '
                '${dark ? 'dark' : 'light'}',
          );
          final row = tester.getRect(
            find.byKey(const ValueKey<String>('v2-project-long')),
          );
          final cap = width >= 900
              ? 720.0
              : width >= 600
              ? 640.0
              : width;
          expect(
            row.width,
            lessThanOrEqualTo(cap),
            reason: 'the row must sit inside the ${cap.toInt()} dp cap',
          );
        }
      }
    }
  });

  testWidgets('create and delete sheets fit 320 dp at 200 % text', (
    tester,
  ) async {
    _useScreen(tester, width: 320, height: 640);
    _resetScreen(tester);

    await tester.pumpWidget(
      _scaled(
        ProjectsPage(
          data: const V2ProjectsData(),
          createProject: (_) async =>
              const V2ProjectMutation.failed('Could not reach the server.'),
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-empty-new-project')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Create project'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _scaled(
        ProjectsPage(
          data: _contentData(const <V2Project>[_project]),
          deleteProject: (_) async => const V2ProjectMutation.ok(),
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    await _openMenu(tester, 'pr1');
    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Delete project?'), findsOneWidget);
  });

  testWidgets('sort chips appear only once the list is long enough', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(const <V2Project>[
            _project,
            _brandProject,
            _longProject,
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('v2-projects-sort-recent')),
      findsNothing,
      reason: 'three rows do not need a sort control',
    );

    await tester.pumpWidget(
      _app(ProjectsPage(data: _contentData(_sortableProjects()))),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('v2-projects-sort-recent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('v2-projects-sort-name')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('v2-projects-sort-chats')),
      findsOneWidget,
    );
  });

  testWidgets('recent is the default and name/chats reorder the rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(ProjectsPage(data: _contentData(_sortableProjects()))),
    );
    await tester.pumpAndSettle();

    expect(_rowOrder(tester), <String>['zebra', 'mango', 'banana', 'alpha']);

    await tester.tap(
      find.byKey(const ValueKey<String>('v2-projects-sort-name')),
    );
    await tester.pumpAndSettle();
    expect(_rowOrder(tester), <String>['alpha', 'banana', 'mango', 'zebra']);

    await tester.tap(
      find.byKey(const ValueKey<String>('v2-projects-sort-chats')),
    );
    await tester.pumpAndSettle();
    expect(_rowOrder(tester), <String>['alpha', 'mango', 'banana', 'zebra']);
  });

  testWidgets('the sort row is a radio group and the active chip says so', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(ProjectsPage(data: _contentData(_sortableProjects()))),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Recent')),
      isSemantics(
        label: 'Recent',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Name')),
      isSemantics(
        label: 'Name',
        isButton: true,
        hasSelectedState: true,
        isSelected: false,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('v2-projects-sort-name')),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Recent')),
      isSemantics(label: 'Recent', hasSelectedState: true, isSelected: false),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Name')),
      isSemantics(label: 'Name', hasSelectedState: true, isSelected: true),
    );
    semantics.dispose();
  });
}
