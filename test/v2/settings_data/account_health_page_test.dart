import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/account_health_page.dart';
import 'package:ovid_ai/ui/v2/settings/settings_rows.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

Widget _narrow(
  Widget home, {
  required ThemeData theme,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    theme: theme,
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(320, 640),
        textScaler: const TextScaler.linear(2),
        disableAnimations: reduceMotion,
      ),
      child: home,
    ),
  );
}

/// Walks every horizontal flex, including rows that are scrolled out of view
/// (an offscreen overflow is never painted, so `takeException` misses it).
void _expectNoOverflow(WidgetTester tester) {
  for (final flex in tester.allRenderObjects.whereType<RenderFlex>()) {
    if (flex.direction != Axis.horizontal) continue;
    var right = 0.0;
    RenderBox? child = flex.firstChild;
    while (child != null) {
      final data = child.parentData! as FlexParentData;
      final edge = data.offset.dx + child.size.width;
      if (edge > right) right = edge;
      child = flex.childAfter(child);
    }
    expect(
      right,
      lessThanOrEqualTo(flex.size.width + 0.5),
      reason: 'a row paints past its box',
    );
  }
}

/// Centres a control in the viewport so a 200 %-text tap cannot land under
/// the app bar (plain `ensureVisible` aligns to the leading edge).
Future<void> _centerOn(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

V2AccountHealthPageData _data({
  String planLabel = 'Plus',
  V2AccountStatus? accountStatus = V2AccountStatus.active,
  String todayUsageLabel = '8.2K tokens',
  double? todayUsageFraction = 0.16,
  String storageUsedLabel = '1.2 GB of 15 GB',
  double? storageFraction = 0.08,
  String deletionScheduledLabel = '',
  bool deletionKnown = false,
  bool loading = false,
  V2AccountHealthStatus status = V2AccountHealthStatus.ready,
  String? errorMessage,
  VoidCallback? onOpenPlans,
  VoidCallback? onOpenStorage,
  VoidCallback? onCancelDeletion,
  VoidCallback? onRetry,
}) {
  return V2AccountHealthPageData(
    planLabel: planLabel,
    accountStatus: accountStatus,
    todayUsageLabel: todayUsageLabel,
    todayUsageFraction: todayUsageFraction,
    storageUsedLabel: storageUsedLabel,
    storageFraction: storageFraction,
    deletionScheduledLabel: deletionScheduledLabel,
    deletionKnown: deletionKnown,
    loading: loading,
    status: status,
    errorMessage: errorMessage,
    onOpenPlans: onOpenPlans,
    onOpenStorage: onOpenStorage,
    onCancelDeletion: onCancelDeletion,
    onRetry: onRetry,
  );
}

void main() {
  testWidgets('renders plan, today, storage and deletion as one-line rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    // The status line is derived, and it is the only place the standing is
    // stated: there is no second "Active" pill or status row.
    expect(find.text('Healthy'), findsOneWidget);
    expect(find.text('Active'), findsNothing);

    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Plus'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('8.2K tokens'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('1.2 GB of 15 GB'), findsOneWidget);
    expect(find.text('Deletion'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);

    // Every row is one line: no paragraph or explanatory sentence.
    expect(find.textContaining('good standing'), findsNothing);
    expect(find.textContaining('scheduled for deletion'), findsNothing);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    expect(find.text('Healthy'), findsOneWidget);
    expect(find.text('Plus'), findsOneWidget);
  });

  testWidgets('device and two-step sections are gone', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // No device management: there is no device endpoint, so the page does not
    // imply one with rows or a Review action.
    expect(find.text('Two-step sign-in'), findsNothing);
    expect(find.text('Turn on'), findsNothing);
    expect(find.text('Pixel 9 Pro'), findsNothing);
    expect(find.text('MacBook Air'), findsNothing);
    expect(find.text('This device'), findsNothing);
    expect(find.text('Revoke'), findsNothing);
    expect(find.text('Review'), findsNothing);
    // No health-check score or service list either.
    expect(find.text('Security score'), findsNothing);
    expect(find.text('92/100'), findsNothing);
    expect(find.text('Storage left'), findsNothing);
    expect(find.text('Chat and sync'), findsNothing);
    expect(find.text('Run check'), findsNothing);
    expect(find.byTooltip('Run check'), findsNothing);
    expect(find.byTooltip('Run again'), findsNothing);
    // The sign-in address is not one of the four facts this page reads.
    expect(find.text('aarav@gmail.com'), findsNothing);
    expect(find.text('Verified'), findsNothing);
  });

  testWidgets('unknown facts render a dash, never a zero', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            planLabel: '',
            accountStatus: null,
            todayUsageLabel: '',
            todayUsageFraction: null,
            storageUsedLabel: '',
            storageFraction: null,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // A missing status is attention, never a green "Healthy".
    expect(find.text('Attention needed · Status unknown'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.text('—'), findsNWidgets(4));
  });

  testWidgets('deletion pending is the specific attention reason', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.deletionPending,
            deletionScheduledLabel: '20 Nov 2026',
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Attention needed · Deletion scheduled'), findsOneWidget);
    expect(find.text('Scheduled · 20 Nov 2026'), findsOneWidget);
    expect(find.text('None'), findsNothing);
  });

  testWidgets('storage near the quota raises attention', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(storageFraction: 0.95)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Attention needed · Storage almost full'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
  });

  testWidgets('a used-up daily allowance raises attention', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(todayUsageFraction: 1)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Attention needed · Daily limit reached'), findsOneWidget);
  });

  testWidgets('the plan row opens the plan list for real', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onOpenPlans: () => opened = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('health-plan')));
    expect(opened, isTrue);
  });

  testWidgets('the storage row opens the storage screen for real', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onOpenStorage: () => opened = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('health-storage')));
    expect(opened, isTrue);
  });

  testWidgets('rows without a handler are static', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // No chevron and no tap target: the row is a fact, not a control.
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    for (final key in <String>['health-plan', 'health-storage']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
    }
  });

  testWidgets('deletion row cancels only after the confirmation', (
    tester,
  ) async {
    var cancelled = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.deletionPending,
            deletionScheduledLabel: '20 Nov 2026',
            onCancelDeletion: () => cancelled = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await _centerOn(tester, find.text('Deletion'));
    await tester.tap(find.byKey(const ValueKey<String>('health-deletion')));
    await tester.pumpAndSettle();

    expect(find.text('Cancel account deletion?'), findsOneWidget);
    await tester.tap(find.text('Keep deletion'));
    await tester.pumpAndSettle();
    expect(cancelled, isFalse);

    await _centerOn(tester, find.text('Deletion'));
    await tester.tap(find.byKey(const ValueKey<String>('health-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('account-health-confirm-cancel-deletion'),
      ),
    );
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
  });

  testWidgets('a pending deletion without a handler is a static row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.deletionPending,
            deletionScheduledLabel: '20 Nov 2026',
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scheduled · 20 Nov 2026'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(find.text('Cancel deletion'), findsNothing);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            errorMessage: 'Account health could not load.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('loading state renders skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(loading: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Plan'), findsNothing);
  });

  testWidgets('an explicit loading status renders skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(status: V2AccountHealthStatus.loading)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Plan'), findsNothing);
  });

  testWidgets('an explicit empty status renders the honest empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(status: V2AccountHealthStatus.empty)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OEmptyState), findsOneWidget);
    expect(find.text(V2AccountHealthPageData.emptyTitle), findsOneWidget);
    expect(find.text(V2AccountHealthPageData.emptyMessage), findsOneWidget);
    // No row may render a dash as if it were a real fact.
    expect(find.text('Plan'), findsNothing);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('an explicit error status renders the error state', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            status: V2AccountHealthStatus.error,
            errorMessage: 'Account health could not load.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('an explicit error without a message still says something', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(status: V2AccountHealthStatus.error)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(V2AccountHealthPageData.loadFailed), findsOneWidget);
  });

  testWidgets('a banned account is never reported as healthy', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(accountStatus: V2AccountStatus.banned)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Banned'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
  });

  testWidgets('semantics announce the status once and read label plus value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // One status node, with no second copy of the word "Healthy" anywhere.
    expect(find.bySemanticsLabel('Status: Healthy'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Healthy')), findsOneWidget);

    // Each row is one node that reads its label and value together.
    expect(find.bySemanticsLabel('Plan, Plus'), findsOneWidget);
    expect(find.bySemanticsLabel('Today, 8.2K tokens'), findsOneWidget);
    expect(find.bySemanticsLabel('Storage, 1.2 GB of 15 GB'), findsOneWidget);
    expect(find.bySemanticsLabel('Deletion, None'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('an unknown value is spoken as unknown, not a dash', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(planLabel: '', todayUsageLabel: '', storageUsedLabel: ''),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Plan, unknown'), findsOneWidget);
    expect(find.bySemanticsLabel('Today, unknown'), findsOneWidget);
    expect(find.bySemanticsLabel('Storage, unknown'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('actionable rows are announced as buttons', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.deletionPending,
            deletionScheduledLabel: '20 Nov 2026',
            onOpenPlans: () {},
            onOpenStorage: () {},
            onCancelDeletion: () {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Plan, Plus'), findsOneWidget);
    expect(find.bySemanticsLabel('Storage, 1.2 GB of 15 GB'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Deletion, Scheduled · 20 Nov 2026'),
      findsOneWidget,
    );
    final plan = tester.getSemantics(find.bySemanticsLabel('Plan, Plus'));
    expect(plan.getSemanticsData().flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  testWidgets('reading order follows the visual order', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    double top(String key) =>
        tester.getTopLeft(find.byKey(ValueKey<String>(key))).dy;
    expect(top('health-plan'), lessThan(top('health-usage')));
    expect(top('health-usage'), lessThan(top('health-storage')));
    expect(top('health-storage'), lessThan(top('health-deletion')));
  });

  testWidgets('long values stay on one line without overflowing', (
    tester,
  ) async {
    _setView(tester, const Size(320, 640));
    await tester.pumpWidget(
      _narrow(
        AccountHealthPage(
          data: _data(
            planLabel: 'Pro annual workspace plan with priority support',
            todayUsageLabel: '12,345,678 input and 8,765,432 output tokens',
            storageUsedLabel: '74.8 GB of 75 GB used across every artifact',
            storageFraction: 0.99,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    _expectNoOverflow(tester);
    expect(find.text('Attention needed · Storage almost full'), findsOneWidget);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200 % text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      _setView(tester, const Size(320, 640));
      await tester.pumpWidget(
        _narrow(
          AccountHealthPage(
            data: _data(
              onOpenPlans: () {},
              onOpenStorage: () {},
              onCancelDeletion: () {},
            ),
          ),
          theme: dark ? OTheme.dark() : OTheme.light(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      _expectNoOverflow(tester);
    });

    testWidgets(
      'deletion state fits 320 dp at 200 % text (${dark ? 'dark' : 'light'})',
      (tester) async {
        _setView(tester, const Size(320, 640));
        await tester.pumpWidget(
          _narrow(
            AccountHealthPage(
              data: _data(
                accountStatus: V2AccountStatus.deletionPending,
                deletionScheduledLabel: '20 Nov 2026',
                onCancelDeletion: () {},
              ),
            ),
            theme: dark ? OTheme.dark() : OTheme.light(),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        _expectNoOverflow(tester);
        // The specific reason is rendered in full, never clipped away.
        expect(
          find.text('Attention needed · Deletion scheduled'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'attention state fits 320 dp at 200 % text (${dark ? 'dark' : 'light'})',
      (tester) async {
        _setView(tester, const Size(320, 640));
        await tester.pumpWidget(
          _narrow(
            AccountHealthPage(
              data: _data(
                accountStatus: null,
                storageUsedLabel: '',
                todayUsageLabel: '',
              ),
            ),
            theme: dark ? OTheme.dark() : OTheme.light(),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        _expectNoOverflow(tester);
      },
    );
  }

  for (final width in <double>[320, 640, 1280]) {
    for (final dark in <bool>[false, true]) {
      testWidgets('no overflow at ${width.toInt()} dp and 200 % text '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        _setView(tester, Size(width, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: const TextScaler.linear(2),
              ),
              child: AccountHealthPage(
                data: _data(
                  accountStatus: V2AccountStatus.deletionPending,
                  deletionScheduledLabel: '20 Nov 2026',
                  onOpenPlans: () {},
                  onOpenStorage: () {},
                  onCancelDeletion: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        _expectNoOverflow(tester);
      });
    }
  }

  for (final width in <double>[800, 1280]) {
    testWidgets('content follows the band cap at ${width.toInt()} dp', (
      tester,
    ) async {
      _setView(tester, Size(width, 900));
      await tester.pumpWidget(
        _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
      );
      await tester.pumpAndSettle();

      final widthOfRows = tester.getSize(find.byType(V2SettingsRowList)).width;
      final cap = width < 900 ? 640.0 : 720.0;
      expect(widthOfRows, lessThanOrEqualTo(cap));
      // Centred: the gap on the left matches the gap on the right.
      final left = tester.getTopLeft(find.byType(V2SettingsRowList)).dx;
      expect(left, closeTo(width - left - widthOfRows, 0.5));
    });
  }

  testWidgets('reduced motion keeps every row visible', (tester) async {
    _setView(tester, const Size(320, 640));
    await tester.pumpWidget(
      _narrow(
        AccountHealthPage(
          data: _data(onOpenPlans: () {}, onOpenStorage: () {}),
        ),
        theme: OTheme.light(),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Deletion'), findsOneWidget);
  });
}
