import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar_footer.dart';

const _scheduleKey = ValueKey<String>('v2-sidebar-footer-schedule');
const _artifactsKey = ValueKey<String>('v2-sidebar-footer-artifacts');
const _settingsKey = ValueKey<String>('v2-sidebar-footer-settings');

Widget _app({
  ThemeData? theme,
  double textScale = 1,
  String? nextRun,
  VoidCallback? onSchedule,
  VoidCallback? onArtifacts,
  VoidCallback? onSettings,
}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SidebarFooter(
              scheduleNextRun: nextRun,
              onSchedule: onSchedule,
              onArtifacts: onArtifacts,
              onSettings: onSettings,
            ),
          ),
        ),
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

double _topOf(WidgetTester tester, Key key) =>
    tester.getTopLeft(find.byKey(key)).dy;

void main() {
  testWidgets('renders Schedule, Artifacts and Settings in light and dark', (
    tester,
  ) async {
    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(_app(theme: theme, nextRun: 'Next run 9:00 AM'));

      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Artifacts'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Next run 9:00 AM'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('each destination reports its callback', (tester) async {
    var schedule = 0;
    var artifacts = 0;
    var settings = 0;
    await tester.pumpWidget(
      _app(
        onSchedule: () => schedule++,
        onArtifacts: () => artifacts++,
        onSettings: () => settings++,
      ),
    );

    await tester.tap(find.text('Schedule'));
    await tester.tap(find.text('Artifacts'));
    await tester.tap(find.text('Settings'));

    expect(schedule, 1);
    expect(artifacts, 1);
    expect(settings, 1);
  });

  testWidgets('disabled destinations do nothing but announce the state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app());

    for (final label in <String>['Schedule', 'Artifacts', 'Settings']) {
      expect(
        tester.getSemantics(find.text(label)),
        isSemantics(label: label, hasEnabledState: true, isEnabled: false),
      );
    }

    await tester.tap(find.text('Schedule'));
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('schedule next-run subtitle is shown and announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        nextRun: '  Next run 9:00 AM  ',
        onSchedule: () {},
        onArtifacts: () {},
        onSettings: () {},
      ),
    );

    expect(find.text('Next run 9:00 AM'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Schedule')),
      isSemantics(
        label: 'Schedule, Next run 9:00 AM',
        isButton: true,
        isEnabled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('blank next-run subtitle is omitted', (tester) async {
    await tester.pumpWidget(_app(nextRun: '   '));

    expect(find.textContaining('Next run'), findsNothing);
    expect(find.byKey(_scheduleKey), findsOneWidget);
  });

  testWidgets('destinations meet the 48 dp target in the row layout', (
    tester,
  ) async {
    await tester.pumpWidget(_app(nextRun: 'Next run 9:00 AM'));

    for (final key in <Key>[_scheduleKey, _artifactsKey, _settingsKey]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    // All three sit on one line at the default text scale.
    final scheduleTop = _topOf(tester, _scheduleKey);
    expect(_topOf(tester, _artifactsKey), scheduleTop);
    expect(_topOf(tester, _settingsKey), scheduleTop);
  });

  testWidgets('destinations stack above 125 % text', (tester) async {
    await tester.pumpWidget(_app(textScale: 1.25, nextRun: 'Next run 9:00 AM'));

    // 125 % is still the three-up layout.
    expect(_topOf(tester, _artifactsKey), _topOf(tester, _scheduleKey));
    expect(_topOf(tester, _settingsKey), _topOf(tester, _scheduleKey));

    await tester.pumpWidget(_app(textScale: 1.26, nextRun: 'Next run 9:00 AM'));

    final tops = <double>[
      _topOf(tester, _scheduleKey),
      _topOf(tester, _artifactsKey),
      _topOf(tester, _settingsKey),
    ];
    expect(tops[0], lessThan(tops[1]));
    expect(tops[1], lessThan(tops[2]));

    // Stacked rows keep the full 48 dp touch target.
    for (final key in <Key>[_scheduleKey, _artifactsKey, _settingsKey]) {
      expect(tester.getSize(find.byKey(key)).height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    _useNarrowScreen(tester);

    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _app(
          theme: theme,
          textScale: 2,
          nextRun: 'Next run 9:00 AM',
          onSchedule: () {},
          onArtifacts: () {},
          onSettings: () {},
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Artifacts'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Next run 9:00 AM'), findsOneWidget);
    }
  });

  testWidgets('long next-run copy ellipsizes without overflowing', (
    tester,
  ) async {
    _useNarrowScreen(tester);

    await tester.pumpWidget(
      _app(
        textScale: 2,
        nextRun: 'Next run tomorrow at 9:00 AM in your local timezone',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Schedule'), findsOneWidget);
  });

  testWidgets('paints behind the bottom safe-area inset and keeps taps above', (
    tester,
  ) async {
    const inset = EdgeInsets.only(bottom: 34, left: 12, right: 12);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(padding: inset),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SidebarFooter(
                  scheduleNextRun: 'Next run 9:00 AM',
                  onSchedule: () {},
                  onArtifacts: () {},
                  onSettings: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final viewHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(viewHeight, 600);

    // The surface reaches the screen edge, while the rows stop above the inset.
    final footer = tester.getRect(find.byType(SidebarFooter));
    expect(footer.bottom, 600);
    final schedule = tester.getRect(find.byKey(_scheduleKey));
    expect(schedule.bottom, lessThanOrEqualTo(600 - inset.bottom));
    expect(schedule.bottom, greaterThan(600 - inset.bottom - 20));

    // Horizontal insets are honoured too.
    expect(schedule.left, greaterThanOrEqualTo(inset.left + 8));
  });
}
