import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/sidebar/project_detail_page.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar_footer.dart';

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
  memoryFileCount: 3,
);

V2SidebarData _contentData() => const V2SidebarData(
  name: 'Alex Rivera',
  initials: 'Alex Rivera',
  pinned: <V2SidebarSession>[_pinned],
  projects: <V2SidebarProject>[_project],
  today: <V2SidebarSession>[_today],
  yesterday: <V2SidebarSession>[_yesterday],
  scheduleNextRun: 'Next run 9:00 AM',
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

/// The drawer's own scrollable (the search field has one too).
final Finder _sidebarScrollable = find.descendant(
  of: find.byKey(const Key('v2-sidebar-list')),
  matching: find.byType(Scrollable),
);

void _useNarrowScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _useScreen(WidgetTester tester, double width, {double height = 900}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('sidebar uses the shared footer with the next-run subtitle', (
    tester,
  ) async {
    var schedule = 0;
    await tester.pumpWidget(
      _app(Sidebar(data: _contentData(), onSchedule: () => schedule++)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SidebarFooter), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('v2-sidebar-footer-schedule')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('v2-sidebar-footer-artifacts')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('v2-sidebar-footer-settings')),
      findsOneWidget,
    );
    expect(find.text('Next run 9:00 AM'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('v2-sidebar-footer-schedule')),
    );
    expect(schedule, 1);
  });

  testWidgets('sidebar renders profile, sections and footer in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(Sidebar(data: _contentData())));
    await tester.pumpAndSettle();

    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('PINNED'), findsNothing);
    expect(find.text('TODAY'), findsNothing);
    expect(find.text('YESTERDAY'), findsNothing);
    expect(find.text('Next.js Portfolio Setup'), findsOneWidget);
    expect(find.text('Landing page copy review'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('3 chats'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Next run 9:00 AM'), findsOneWidget);
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

  testWidgets('sidebar empty state is one line and keeps one New chat', (
    tester,
  ) async {
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
    expect(find.text('New chat'), findsOneWidget);
    await tester.tap(find.text('New chat'));
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
      await tester.scrollUntilVisible(
        find.text('Synthesize research PDF'),
        100,
        scrollable: _sidebarScrollable,
      );
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

    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('SESSIONS'), findsOneWidget);

    // The drawer list is lazy, so later rows mount as they scroll in.
    await tester.scrollUntilVisible(
      find.text('Next.js Portfolio Setup'),
      100,
      scrollable: _sidebarScrollable,
    );
    expect(find.text('Next.js Portfolio Setup'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Synthesize research PDF'),
      100,
      scrollable: _sidebarScrollable,
    );
    expect(find.text('Synthesize research PDF'), findsOneWidget);
  });

  testWidgets('project memory chip opens the project detail sheet', (
    tester,
  ) async {
    const project = V2SidebarProject(
      id: 'pr2',
      name: 'Brand Voice',
      chatCount: 2,
      memoryFileCount: 2,
      detail: V2ProjectDetailData(
        projectName: 'Brand Voice',
        chatCount: 2,
        chats: <V2ProjectChat>[
          V2ProjectChat(id: 'c1', title: 'Tone of voice chat'),
        ],
        memoryFiles: <V2ProjectMemoryFile>[
          V2ProjectMemoryFile(
            id: 'm1',
            name: 'tone.md',
            sizeLabel: '8 KB',
            updatedLabel: 'Updated 1h ago',
          ),
        ],
        storageLabel: '24 MB of 3 GB',
        storageFraction: 0.2,
      ),
    );
    await tester.pumpWidget(
      _app(
        const Sidebar(
          data: V2SidebarData(
            name: 'Alex Rivera',
            projects: <V2SidebarProject>[project],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 chats'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.memory_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Tone of voice chat'), findsOneWidget);
    expect(find.text('tone.md'), findsOneWidget);
    expect(find.text('24 MB of 3 GB'), findsOneWidget);
  });

  testWidgets('project memory chip reports the project when wired', (
    tester,
  ) async {
    V2SidebarProject? memory;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: _contentData(),
          onProjectMemory: (project) => memory = project,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.memory_rounded));
    expect(memory?.id, 'pr1');
  });

  testWidgets('project memory control keeps a 48 dp hit area', (tester) async {
    await tester.pumpWidget(
      _app(
        Sidebar(data: _contentData(), onProjectMemory: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    final target = find.byKey(const ValueKey<String>('v2-sidebar-memory-pr1'));
    expect(target, findsOneWidget);
    final size = tester.getSize(target);
    expect(size.width, greaterThanOrEqualTo(OSpace.touch));
    expect(size.height, greaterThanOrEqualTo(OSpace.touch));
  });

  testWidgets('projects without memory show only the chat count', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Sidebar(
          data: V2SidebarData(
            name: 'Alex Rivera',
            projects: <V2SidebarProject>[
              V2SidebarProject(id: 'pr3', name: 'Fresh project', chatCount: 0),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No chats'), findsOneWidget);
    expect(find.byIcon(Icons.memory_rounded), findsNothing);
  });

  testWidgets('pinned chats lead Sessions with no glyph on the row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Sidebar(
          data: V2SidebarData(
            name: 'Alex Rivera',
            pinned: <V2SidebarSession>[_pinned],
            today: <V2SidebarSession>[
              V2SidebarSession(
                id: 't2',
                title: 'Brand colours',
                modelLabel: 'Auto',
                projectName: 'Brand Voice',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One section, pinned first; the pin is ordering, not a glyph.
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('PINNED'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('v2-session-pin-p1')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.text('Next.js Portfolio Setup')).dy,
      lessThan(tester.getTopLeft(find.text('Brand colours')).dy),
    );

    // The project stays off the row; search still matches on it.
    expect(find.text('Brand Voice'), findsNothing);
  });

  testWidgets('delete lives in the actions sheet, never on the row', (
    tester,
  ) async {
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

    // Even with every row callback wired, the row is title, time and the
    // three-dot menu — no inline delete next to the title.
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    expect(actioned?.id, 't1');
  });

  testWidgets('schedule subtitle is announced with the footer item', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const Sidebar(
          data: V2SidebarData(
            name: 'Alex Rivera',
            scheduleNextRun: 'Next run 9:00 AM',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Next run 9:00 AM'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Schedule')).label,
      contains('Next run 9:00 AM'),
    );
    handle.dispose();
  });

  testWidgets('no schedule subtitle when none is supplied', (tester) async {
    await tester.pumpWidget(
      _app(const Sidebar(data: V2SidebarData(name: 'Alex Rivera'))),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Next run'), findsNothing);
  });

  testWidgets('project detail sheet fits 320 dp at 200 % text', (tester) async {
    _useNarrowScreen(tester);

    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrow(
          const Sidebar(
            data: V2SidebarData(
              name: 'Alex Rivera',
              projects: <V2SidebarProject>[
                V2SidebarProject(
                  id: 'pr4',
                  name: 'Brand Voice',
                  chatCount: 2,
                  memoryFileCount: 2,
                  detail: V2ProjectDetailData(
                    projectName: 'Brand Voice',
                    chatCount: 2,
                    chats: <V2ProjectChat>[
                      V2ProjectChat(id: 'c1', title: 'Tone of voice chat'),
                    ],
                    memoryFiles: <V2ProjectMemoryFile>[
                      V2ProjectMemoryFile(
                        id: 'm1',
                        name: 'tone.md',
                        sizeLabel: '8 KB',
                        updatedLabel: 'Updated 1h ago',
                      ),
                    ],
                    storageLabel: '24 MB of 3 GB',
                    storageFraction: 0.2,
                  ),
                ),
              ],
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.memory_rounded));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('tone.md', skipOffstage: false), findsOneWidget);

      // Dismiss the sheet so the next theme starts from the drawer.
      await tester.tapAt(const Offset(160, 20));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('drawer keeps the profile → new chat → search → projects → '
      'sessions → footer order', (tester) async {
    await tester.pumpWidget(_app(Sidebar(data: _contentData())));
    await tester.pumpAndSettle();

    final order = <(String, Finder)>[
      ('profile', find.text('Alex Rivera')),
      ('new chat', find.text('New chat')),
      ('search', find.byKey(const Key('v2-sidebar-search'))),
      ('projects', find.text('PROJECTS')),
      ('sessions', find.text('SESSIONS')),
      (
        'footer',
        find.byKey(const ValueKey<String>('v2-sidebar-footer-settings')),
      ),
    ];
    double? previous;
    for (final (label, finder) in order) {
      expect(finder, findsOneWidget, reason: label);
      final top = tester.getTopLeft(finder).dy;
      if (previous != null) {
        expect(top, greaterThan(previous), reason: label);
      }
      previous = top;
    }
  });

  testWidgets('profile header reports the tap', (tester) async {
    var profiles = 0;
    await tester.pumpWidget(
      _app(Sidebar(data: _contentData(), onProfile: () => profiles++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alex Rivera'));
    expect(profiles, 1);
  });

  testWidgets('rail layout is a fixed 280 dp column at 600 and 300 dp at 900', (
    tester,
  ) async {
    _useScreen(tester, 600);
    for (final (width, expected) in <(double, double)>[
      (600, Sidebar.railWidthTablet),
      (900, Sidebar.railWidthWide),
    ]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        _app(Sidebar(data: _contentData(), layout: SidebarLayout.rail)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '$width dp');
      expect(
        tester.getSize(find.byKey(const Key('v2-sidebar-surface'))).width,
        expected,
        reason: '$width dp',
      );
      // A rail is a column, not a page: no app bar, same content order.
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('PROJECTS'), findsOneWidget);
      expect(find.text('Schedule'), findsOneWidget);
    }
  });

  testWidgets('rail layout fits 600 dp at 200 % text', (tester) async {
    _useScreen(tester, 600);
    await tester.pumpWidget(
      _narrow(Sidebar(data: _contentData(), layout: SidebarLayout.rail)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
  });

  testWidgets('default layout stays a drawer at tablet width', (tester) async {
    _useScreen(tester, 900);
    await tester.pumpWidget(_app(Sidebar(data: _contentData())));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('v2-sidebar-surface'))).width,
      Sidebar.drawerWidth,
    );
  });

  testWidgets('a chat row is title and time, never a stack of meta', (
    tester,
  ) async {
    const withTime = V2SidebarSession(
      id: 's1',
      title: 'Brand colours',
      modelLabel: 'Auto',
      timeLabel: '2h ago',
      projectName: 'Brand Voice',
    );
    const projectOnly = V2SidebarSession(
      id: 's2',
      title: 'Tone notes',
      modelLabel: 'Auto',
      projectName: 'Brand Voice',
    );
    await tester.pumpWidget(
      _app(
        const Sidebar(
          data: V2SidebarData(
            name: 'Alex Rivera',
            today: <V2SidebarSession>[withTime, projectOnly],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Time is the only meta line; the project and the model stay off the row.
    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('Brand Voice'), findsNothing);
    expect(find.text('Auto'), findsNothing);
  });

  testWidgets('the active chat carries a 2 dp accent edge, not a fill', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const Sidebar(
          data: V2SidebarData(
            name: 'Alex Rivera',
            today: <V2SidebarSession>[_today, _yesterday],
            activeSessionId: 't1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final edge = find.byKey(const ValueKey<String>('v2-session-active-t1'));
    expect(edge, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('v2-session-active-y1')),
      findsNothing,
    );
    final bar = tester.widget<Container>(edge);
    expect(bar.constraints?.maxWidth ?? tester.getSize(edge).width,
        OSpace.xxs);
    expect(bar.color, OColors.light.accent);

    // Selection is announced; the row itself stays on the bare surface.
    expect(
      tester
          .getSemantics(find.text('Landing page copy review'))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(
      tester
          .getSemantics(find.text('Synthesize research PDF'))
          .flagsCollection
          .isSelected,
      Tristate.isFalse,
    );
    handle.dispose();
  });

  testWidgets('inline search filters chats and projects, then clears', (
    tester,
  ) async {
    const projectChat = V2SidebarSession(
      id: 't9',
      title: 'Tone notes',
      modelLabel: 'Auto',
      projectName: 'Brand Voice',
    );
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: const V2SidebarData(
            name: 'Alex Rivera',
            today: <V2SidebarSession>[_today, projectChat],
            yesterday: <V2SidebarSession>[_yesterday],
            projects: <V2SidebarProject>[_project],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A chat title.
    await tester.enterText(
      find.byKey(const Key('v2-sidebar-search')),
      'landing',
    );
    await tester.pumpAndSettle();
    expect(find.text('Landing page copy review'), findsOneWidget);
    expect(find.text('Synthesize research PDF'), findsNothing);
    expect(find.text('Mobile App Redesign'), findsNothing);
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('PROJECTS'), findsNothing);

    // A project name, which also matches the chat filed under it.
    await tester.enterText(find.byKey(const Key('v2-sidebar-search')), 'brand');
    await tester.pumpAndSettle();
    expect(find.text('Tone notes'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsNothing);
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('PROJECTS'), findsNothing);

    // A project name on its own.
    await tester.enterText(
      find.byKey(const Key('v2-sidebar-search')),
      'mobile',
    );
    await tester.pumpAndSettle();
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Tone notes'), findsNothing);
    expect(find.text('Landing page copy review'), findsNothing);

    // Nothing matches: an empty state with a way back.
    await tester.enterText(
      find.byKey(const Key('v2-sidebar-search')),
      'no such thing',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsNothing);

    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Landing page copy review'), findsOneWidget);
    expect(find.text('Synthesize research PDF'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('No matches'), findsNothing);

    // The clear control inside the field restores the drawer too.
    await tester.enterText(
      find.byKey(const Key('v2-sidebar-search')),
      'landing',
    );
    await tester.pumpAndSettle();
    expect(find.text('Synthesize research PDF'), findsNothing);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Synthesize research PDF'), findsOneWidget);
  });

  testWidgets('search results open the chat and project rows', (tester) async {
    V2SidebarSession? session;
    V2SidebarProject? project;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: _contentData(),
          onSessionTap: (row) => session = row,
          onProjectTap: (row) => project = row,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('v2-sidebar-search')),
      'landing',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Landing page copy review'));

    await tester.enterText(
      find.byKey(const Key('v2-sidebar-search')),
      'mobile',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile App Redesign'));

    expect(session?.id, 't1');
    expect(project?.id, 'pr1');
  });

  testWidgets('search is hidden while the drawer has no index to filter', (
    tester,
  ) async {
    for (final status in <V2SidebarStatus>[
      V2SidebarStatus.loading,
      V2SidebarStatus.error,
    ]) {
      await tester.pumpWidget(
        _app(
          Sidebar(
            data: V2SidebarData(name: 'Alex Rivera', status: status),
          ),
        ),
      );
      // The loading skeleton shimmers forever, so settle only for the error.
      await tester.pump();
      if (status == V2SidebarStatus.error) {
        await tester.pumpAndSettle();
      }

      expect(
        find.byKey(const Key('v2-sidebar-search')),
        findsNothing,
        reason: status.name,
      );
      expect(find.text('New chat'), findsOneWidget);
    }
  });

  testWidgets('long chat titles ellipsize and still open', (tester) async {
    _useNarrowScreen(tester);
    const longTitle =
        'Rewrite the entire onboarding flow, the pricing page, the billing '
        'emails and every empty state for the new release, with screenshots';
    const longSession = V2SidebarSession(
      id: 'long1',
      title: longTitle,
      modelLabel: 'Auto',
      timeLabel: '3h ago',
    );

    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      V2SidebarSession? tapped;
      await tester.pumpWidget(
        _narrow(
          Sidebar(
            data: const V2SidebarData(
              name: 'Alex Rivera',
              today: <V2SidebarSession>[longSession],
            ),
            onSessionTap: (row) => tapped = row,
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(find.text(longTitle));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);

      await tester.tap(find.text(longTitle));
      expect(tapped?.id, 'long1');
    }
  });

  testWidgets('a project without a memory handler shows no memory control', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    V2SidebarProject? opened;
    await tester.pumpWidget(
      _app(
        Sidebar(
          data: const V2SidebarData(
            name: 'Alex Rivera',
            projects: <V2SidebarProject>[_project],
          ),
          onProjectTap: (row) => opened = row,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No handler and no detail payload: no memory affordance at all.
    expect(
      find.byKey(const ValueKey<String>('v2-sidebar-memory-pr1')),
      findsNothing,
    );
    expect(find.byIcon(Icons.memory_rounded), findsNothing);

    // The tap falls through to the project row.
    await tester.tap(find.text('3 chats'));
    expect(opened?.id, 'pr1');
    handle.dispose();
  });

  testWidgets('search results fit 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    _useNarrowScreen(tester);

    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrow(Sidebar(data: _contentData()), theme: theme),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('v2-sidebar-search')),
        'next',
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Next.js Portfolio Setup'), findsOneWidget);
    }
  });
}
