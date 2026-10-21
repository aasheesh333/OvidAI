import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/projects_page.dart';

const _project = V2Project(
  id: 'pr1',
  name: 'Mobile App Redesign',
  chatCount: 12,
  storageLabel: '340 MB',
  shared: true,
  memberInitials: <String>['Alex Rivera', 'Sam Lee', 'Priya Patel', 'Noah Kim'],
  updatedLabel: 'Updated 4m ago',
);

const _brandProject = V2Project(
  id: 'pr2',
  name: 'Brand Voice Guidelines',
  chatCount: 4,
  storageLabel: '18 MB',
  colorKey: 'coral',
  updatedLabel: 'Yesterday',
);

V2ProjectsData _contentData() => const V2ProjectsData(
  projects: <V2Project>[_project, _brandProject],
);

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

/// Phone-width surface at 200 % text, the accessibility stress case.
Widget _narrow(Widget child, {ThemeData? theme, double textScale = 2}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child,
      ),
    ),
  );
}

void _useNarrowScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('projects page renders explainer and project card in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(ProjectsPage(data: _contentData())));
    await tester.pumpAndSettle();

    expect(find.text('Projects'), findsOneWidget);
    expect(
      find.text('Group chats that share files and memory.'),
      findsOneWidget,
    );
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('12 chats · 340 MB'), findsOneWidget);
    expect(find.text('Updated 4m ago'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
  });

  testWidgets('projects page renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(ProjectsPage(data: _contentData()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);
  });

  testWidgets('empty state opens the New project sheet', (tester) async {
    await tester.pumpWidget(_app(const ProjectsPage(data: V2ProjectsData())));
    await tester.pumpAndSettle();

    expect(find.text('No projects yet'), findsOneWidget);
    await tester.tap(find.text('New project'));
    await tester.pumpAndSettle();

    expect(find.text('Project name'), findsOneWidget);
    expect(find.text('Create project'), findsOneWidget);
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

  testWidgets('project options reports the project to the caller', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
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

    await tester.tap(
      find.bySemanticsLabel('Project options for Mobile App Redesign'),
    );
    expect(actions?.id, 'pr1');
    semantics.dispose();
  });

  testWidgets('filter narrows the list and clear search restores it', (
    tester,
  ) async {
    await tester.pumpWidget(_app(ProjectsPage(data: _contentData())));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('v2-project-filter')),
      'brand',
    );
    await tester.pumpAndSettle();

    expect(find.text('Brand Voice Guidelines'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsNothing);
    expect(find.text('1'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('v2-project-filter')),
      'nothing here',
    );
    await tester.pumpAndSettle();

    expect(find.text('No projects match'), findsOneWidget);
    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();

    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Brand Voice Guidelines'), findsOneWidget);
  });

  testWidgets('New project sheet collects a name and colour', (tester) async {
    final semantics = tester.ensureSemantics();
    V2ProjectDraft? created;
    await tester.pumpWidget(
      _app(
        ProjectsPage(
          data: _contentData(),
          onCreateProject: (draft) => created = draft,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();

    // The CTA is disabled until the project has a name.
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pump();
    expect(created, isNull);

    await tester.enterText(
      find.byKey(const Key('v2-project-name-field')),
      'Brand site',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('v2-project-color-emerald')));
    await tester.pump();
    expect(
      find.bySemanticsLabel('Emerald colour, selected'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('v2-create-project')));
    await tester.pumpAndSettle();

    expect(created?.name, 'Brand site');
    expect(created?.colorKey, 'emerald');
    semantics.dispose();
  });

  testWidgets('loading state shows a skeleton list', (tester) async {
    await tester.pumpWidget(
      _app(
        const ProjectsPage(
          data: V2ProjectsData(status: V2ProjectsStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
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

  testWidgets('content fits a 320 dp screen at 200 % text', (tester) async {
    _useNarrowScreen(tester);
    await tester.pumpWidget(_narrow(ProjectsPage(data: _contentData())));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The list sits below the fold at this size; it must still be built.
    expect(
      find.text('Mobile App Redesign', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('empty state fits a 320 dp screen at 200 % text', (tester) async {
    _useNarrowScreen(tester);
    await tester.pumpWidget(_narrow(const ProjectsPage(data: V2ProjectsData())));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No projects yet', skipOffstage: false), findsOneWidget);
  });

  testWidgets('New project sheet fits a 320 dp screen at 200 % text', (
    tester,
  ) async {
    _useNarrowScreen(tester);
    await tester.pumpWidget(_narrow(const ProjectsPage(data: V2ProjectsData())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Create project'), findsOneWidget);
  });

  testWidgets('error state fits a 320 dp screen at 200 % text', (tester) async {
    _useNarrowScreen(tester);
    await tester.pumpWidget(
      _narrow(
        const ProjectsPage(
          data: V2ProjectsData(status: V2ProjectsStatus.error),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
