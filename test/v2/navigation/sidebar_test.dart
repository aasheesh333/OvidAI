import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';

const _pinned = V2SidebarSession(
  id: 'p1',
  title: 'Next.js Portfolio Setup',
  modelLabel: 'Auto',
  pinned: true,
);

const _today = V2SidebarSession(
  id: 't1',
  title: 'Landing page copy review',
  modelLabel: 'Auto',
  timeLabel: '2h ago',
);

const _yesterday = V2SidebarSession(
  id: 'y1',
  title: 'Synthesize research PDF',
  modelLabel: 'Auto',
  timeLabel: 'Yesterday',
);

const _project = V2SidebarProject(
  id: 'pr1',
  name: 'Mobile App Redesign',
  chatCount: 3,
);

V2SidebarData _contentData() => const V2SidebarData(
  name: 'Alex Rivera',
  initials: 'Alex Rivera',
  pinned: <V2SidebarSession>[_pinned],
  projects: <V2SidebarProject>[_project],
  today: <V2SidebarSession>[_today],
  yesterday: <V2SidebarSession>[_yesterday],
);

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? OTheme.light(),
  home: Scaffold(body: child),
);

/// Phone-width surface at 200 % text, the accessibility stress case.
Widget _narrow(
  Widget child, {
  ThemeData? theme,
  double textScale = 2,
  bool reducedMotion = false,
}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: Scaffold(body: child),
      ),
    ),
  );
}

void _useNarrowScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('sidebar renders profile, sections and footer in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(Sidebar(data: _contentData())));
    await tester.pumpAndSettle();

    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('Next.js Portfolio Setup'), findsOneWidget);
    expect(find.text('Landing page copy review'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('sidebar renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(Sidebar(data: _contentData()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Landing page copy review'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
  });

  testWidgets('sidebar empty state offers New chat', (tester) async {
    var newChats = 0;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: const V2SidebarData(name: 'Alex Rivera'),
          onNewChat: () => newChats++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No chats yet'), findsOneWidget);
    await tester.tap(find.text('New chat').last);
    expect(newChats, 1);
  });

  testWidgets('sidebar loading state shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        const Sidebar(
          data: V2SidebarData(
            name: 'Alex Rivera',
            status: V2SidebarStatus.loading,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Alex Rivera'), findsOneWidget);
  });

  testWidgets('sidebar error state explains and retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: const V2SidebarData(
            name: 'Alex Rivera',
            status: V2SidebarStatus.error,
            errorMessage: 'You are offline.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chats did not load'), findsOneWidget);
    expect(find.text('You are offline.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('tapping a chat reports it to the caller', (tester) async {
    V2SidebarSession? tapped;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: _contentData(),
          onSessionTap: (session) => tapped = session,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Landing page copy review'));
    expect(tapped?.id, 't1');
  });

  testWidgets('three-dot control opens chat actions', (tester) async {
    V2SidebarSession? actioned;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: const V2SidebarData(
            name: 'Alex Rivera',
            today: <V2SidebarSession>[_today],
          ),
          onSessionActions: (session) => actioned = session,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    expect(actioned?.id, 't1');
  });

  testWidgets('long press opens chat actions', (tester) async {
    V2SidebarSession? actioned;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: _contentData(),
          onSessionActions: (session) => actioned = session,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Landing page copy review'));
    expect(actioned?.id, 't1');
  });

  testWidgets('project and footer rows report their callbacks', (tester) async {
    V2SidebarProject? project;
    var schedule = 0;
    var artifacts = 0;
    var settings = 0;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: _contentData(),
          onProjectTap: (row) => project = row,
          onSchedule: () => schedule++,
          onArtifacts: () => artifacts++,
          onSettings: () => settings++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mobile App Redesign'));
    await tester.tap(find.text('Schedule'));
    await tester.tap(find.text('Artifacts'));
    await tester.tap(find.text('Settings'));

    expect(project?.id, 'pr1');
    expect(schedule, 1);
    expect(artifacts, 1);
    expect(settings, 1);
  });

  testWidgets('controls expose labels and announce the disabled state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(Sidebar(data: _contentData())));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('New chat')),
      isSemantics(
        label: 'New chat',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(
          RegExp('Chat options for Next.js Portfolio Setup'),
        ),
      ),
      isSemantics(
        label: 'Chat options for Next.js Portfolio Setup',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('sidebar fits 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    _useNarrowScreen(tester);

    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      V2SidebarSession? tapped;
      await tester.pumpWidget(
        _narrow(
          Sidebar(data: _contentData(), onSessionTap: (row) => tapped = row),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alex Rivera'), findsOneWidget);
      expect(find.text('Free plan'), findsOneWidget);
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Artifacts'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      // The body scrolls, so the last row stays reachable at 200 %.
      await tester.ensureVisible(find.text('Synthesize research PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Synthesize research PDF'));
      expect(tapped?.id, 'y1');
    }
  });

  testWidgets('empty, loading and error states fit 320 dp at 200 % text', (
    tester,
  ) async {
    _useNarrowScreen(tester);

    for (final status in <V2SidebarStatus>[
      V2SidebarStatus.loading,
      V2SidebarStatus.error,
    ]) {
      await tester.pumpWidget(
        _narrow(
          Sidebar(
            data: V2SidebarData(name: 'Alex Rivera', status: status),
            onRetry: () {},
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(
      _narrow(const Sidebar(data: V2SidebarData(name: 'Alex Rivera'))),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('No chats yet'), findsOneWidget);
  });

  testWidgets('reduced motion still renders every section', (tester) async {
    await tester.pumpWidget(
      _narrow(Sidebar(data: _contentData()), reducedMotion: true),
    );
    await tester.pump();

    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('Next.js Portfolio Setup'), findsOneWidget);
  });
}
