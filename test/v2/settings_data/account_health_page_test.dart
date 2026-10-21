import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/account_health_page.dart';

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

void _setNarrowView(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

V2AccountHealthPageData _data({
  VoidCallback? onReviewDevices,
  ValueChanged<String>? onDeviceTap,
  ValueChanged<String>? onRevokeDevice,
  VoidCallback? onEnableTwoFactor,
  VoidCallback? onContactSupport,
  VoidCallback? onRunCheck,
  VoidCallback? onCancelDeletion,
  V2AccountStatus accountStatus = V2AccountStatus.active,
}) {
  final pending = accountStatus == V2AccountStatus.deletionPending;
  return V2AccountHealthPageData(
    statusTitle: 'All systems normal',
    statusMessage: 'No suspicious activity detected.',
    healthy: true,
    score: 92,
    lastCheckLabel: '2 hours ago',
    lastCheckDetail: 'Automated audit passed.',
    twoFactorEnabled: false,
    emailVerified: true,
    emailLabel: 'aarav@gmail.com',
    regionLabel: 'Mumbai, India',
    accountStatus: accountStatus,
    usage: const [
      V2AccountUsageMetric(
        id: 'storage',
        title: 'Storage left',
        value: '2.1 GB',
        detail: 'of 3 GB',
      ),
      V2AccountUsageMetric(
        id: 'daily_usage',
        title: 'Daily usage left',
        value: '38M tokens',
        detail: 'Resets in 6h 12m',
      ),
      V2AccountUsageMetric(
        id: 'monthly_usage',
        title: 'Monthly usage left',
        value: '1.1B tokens',
        detail: 'Resets on 1 Nov',
      ),
    ],
    deletionRequestedLabel: pending ? '21 Oct 2026' : '',
    deletionScheduledLabel: pending ? '20 Nov 2026' : '',
    services: const [
      V2ServiceStatus(name: 'Chat and sync', statusLabel: 'Operational'),
      V2ServiceStatus(name: 'Artifacts', statusLabel: 'Operational'),
      V2ServiceStatus(name: 'Sign-in', statusLabel: 'Operational'),
    ],
    devices: const [
      V2SignInDevice(
        id: 'pixel',
        name: 'Pixel 9 Pro',
        detail: 'Signed in now',
        current: true,
      ),
      V2SignInDevice(
        id: 'mac',
        name: 'MacBook Air',
        detail: 'Last active yesterday',
      ),
    ],
    recentSignIns: const [
      V2SignInEvent(
        id: 'sign-1',
        device: 'Pixel 9 Pro',
        location: 'Mumbai, India',
        timeLabel: 'Today at 9:12 AM',
        current: true,
      ),
    ],
    onReviewDevices: onReviewDevices ?? () {},
    onDeviceTap: onDeviceTap,
    onRevokeDevice: onRevokeDevice ?? (_) {},
    onEnableTwoFactor: onEnableTwoFactor ?? () {},
    onContactSupport: onContactSupport ?? () {},
    onRunCheck: onRunCheck,
    onCancelDeletion: onCancelDeletion,
  );
}

Widget _dataPage({VoidCallback? onContactSupport}) =>
    AccountHealthPage(data: _data(onContactSupport: onContactSupport));

void main() {
  testWidgets('renders account health in light mode', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    expect(find.text('All systems normal'), findsWidgets);
    expect(find.text('Last security check'), findsOneWidget);
    expect(find.text('Pixel 9 Pro'), findsWidgets);
    expect(find.text('92/100'), findsOneWidget);
    expect(find.text('Two-step sign-in'), findsOneWidget);
    expect(find.text('Chat and sync'), findsOneWidget);
    expect(find.text('Mumbai, India'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    expect(find.text('No suspicious activity detected.'), findsWidgets);
    expect(find.text('MacBook Air'), findsOneWidget);
  });

  testWidgets('summary shows storage and daily/monthly usage left', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('ACCOUNT SUMMARY'), findsOneWidget);
    expect(find.text('Account status'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Your account is in good standing.'), findsOneWidget);
    expect(find.text('Storage left'), findsOneWidget);
    expect(find.text('2.1 GB · of 3 GB'), findsOneWidget);
    expect(find.text('Daily usage left'), findsOneWidget);
    expect(find.text('38M tokens · Resets in 6h 12m'), findsOneWidget);
    expect(find.text('Monthly usage left'), findsOneWidget);
    expect(find.text('1.1B tokens · Resets on 1 Nov'), findsOneWidget);
  });

  testWidgets('unmeasured usage is labelled instead of guessed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const AccountHealthPage(data: V2AccountHealthPageData()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage left'), findsOneWidget);
    expect(find.text('Daily usage left'), findsOneWidget);
    expect(find.text('Monthly usage left'), findsOneWidget);
    expect(find.text('Not measured yet'), findsNWidgets(3));
  });

  testWidgets('deletion pending shows its state and can be cancelled', (
    tester,
  ) async {
    var cancelled = 0;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.deletionPending,
            onCancelDeletion: () => cancelled++,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Deletion pending'), findsOneWidget);
    expect(find.text('DELETION REQUEST'), findsOneWidget);
    expect(find.text('Deletion requested'), findsOneWidget);
    expect(
      find.text('Requested 21 Oct 2026 · Deletes on 20 Nov 2026'),
      findsOneWidget,
    );
    expect(
      find.textContaining('will be deleted on 20 Nov 2026'),
      findsOneWidget,
    );

    final cancel = find.byKey(
      const ValueKey<String>('account-health-cancel-deletion'),
    );
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(find.text('Cancel account deletion?'), findsOneWidget);
    expect(cancelled, 0);

    await tester.tap(find.text('Keep deletion'));
    await tester.pumpAndSettle();
    expect(cancelled, 0);
    expect(find.text('Cancel account deletion?'), findsNothing);

    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('account-health-confirm-cancel-deletion'),
      ),
    );
    await tester.pumpAndSettle();

    expect(cancelled, 1);
  });

  testWidgets('deletion card is absent for an active account', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('account-health-deletion-card')),
      findsNothing,
    );
    expect(find.text('DELETION REQUEST'), findsNothing);
  });

  testWidgets('suspended accounts are named and can reach support', (
    tester,
  ) async {
    var contacted = 0;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.suspendedForAbuse,
            onContactSupport: () => contacted++,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Suspended'), findsOneWidget);
    expect(
      find.text('Suspended for abuse. Contact support to appeal.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('account-health-suspended-notice')),
      findsOneWidget,
    );
    expect(find.text('Suspended for abuse'), findsOneWidget);

    final support = find.byKey(
      const ValueKey<String>('account-health-suspended-support'),
    );
    await tester.ensureVisible(support);
    await tester.tap(support);
    expect(contacted, 1);
  });

  testWidgets('empty state offers to run a check', (tester) async {
    var checked = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: V2AccountHealthPageData(
            hasData: false,
            onRunCheck: () => checked = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No health data yet'), findsOneWidget);
    await tester.tap(find.text('Run a check'));
    expect(checked, isTrue);
  });

  testWidgets('active sign-ins are listed without a redundant Review button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onReviewDevices: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ACTIVE SIGN-INS'), findsOneWidget);
    expect(find.text('Pixel 9 Pro'), findsWidgets);
    expect(find.text('Review'), findsNothing);
  });

  testWidgets('tapping a device reports its id', (tester) async {
    String? tapped;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onDeviceTap: (id) => tapped = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final device = find.text('Pixel 9 Pro').first;
    await tester.ensureVisible(device);
    await tester.tap(device);
    expect(tapped, 'pixel');
  });

  testWidgets('two-step sign-in can be turned on', (tester) async {
    var enabled = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onEnableTwoFactor: () => enabled = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Turn on'));
    await tester.tap(find.text('Turn on'));
    expect(enabled, isTrue);
  });

  testWidgets('revoking a device asks for confirmation first', (tester) async {
    String? revoked;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onRevokeDevice: (id) => revoked = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Revoke'));
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    expect(find.text('Revoke this device?'), findsOneWidget);
    expect(revoked, isNull);

    await tester.tap(find.text('Revoke device'));
    await tester.pumpAndSettle();
    expect(revoked, 'mac');
  });

  testWidgets('contact support fires its callback', (tester) async {
    var contacted = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(onContactSupport: () => contacted = true),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Contact support'));
    await tester.tap(find.text('Contact support'));
    expect(contacted, isTrue);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: V2AccountHealthPageData(
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

  testWidgets('loading state renders the skeleton list', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: const V2AccountHealthPageData(loading: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Security score'), findsNothing);
  });

  testWidgets('a failing check is reported instead of a healthy claim', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: V2AccountHealthPageData(
            healthy: false,
            statusTitle: 'One thing needs your attention',
            statusMessage: 'A new sign-in could not be verified.',
            lastCheckLabel: '2 hours ago',
            lastCheckDetail: 'A new sign-in could not be verified.',
            services: const [
              V2ServiceStatus(
                name: 'Sign-in',
                statusLabel: 'Degraded',
                healthy: false,
              ),
            ],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.text('One thing needs your attention'), findsOneWidget);
    expect(find.text('Degraded'), findsOneWidget);
  });

  testWidgets('defaults carry no sample account data', (tester) async {
    const data = V2AccountHealthPageData();
    expect(data.score, isNull);
    expect(data.emailLabel, isEmpty);
    expect(data.regionLabel, isEmpty);
    expect(data.lastCheckLabel, isEmpty);
    expect(data.services, isEmpty);
    expect(data.devices, isEmpty);
    expect(data.recentSignIns, isEmpty);

    await tester.pumpWidget(
      _app(const AccountHealthPage(data: data), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('92/100'), findsNothing);
    expect(find.text('Active'), findsNothing);
    expect(find.text('Not checked'), findsOneWidget);
    expect(find.text('No account status has been reported yet.'), findsOneWidget);
    expect(find.text('aarav@gmail.com'), findsNothing);
    expect(find.text('Mumbai, India'), findsNothing);
    expect(find.text('Region'), findsNothing);
    expect(find.text('No check has run yet.'), findsOneWidget);
    expect(find.text('No other devices are signed in.'), findsOneWidget);
    expect(find.text('No recent sign-ins to review.'), findsOneWidget);
    expect(find.text('Status is not available right now.'), findsOneWidget);
  });

  testWidgets('no check result never claims a healthy account', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: V2AccountHealthPageData(
            // A stale caller flag must not turn into a green tick: no check
            // has run, so there is no result to report.
            healthy: true,
            statusTitle: 'Your account is protected',
            statusMessage: 'Email verified.',
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Healthy'), findsNothing);
    expect(find.text('Not checked yet'), findsOneWidget);
    expect(find.text('Health check not run yet'), findsOneWidget);
    expect(find.text('No check has run yet.'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
    expect(find.text('Continuous scan'), findsNothing);
  });

  testWidgets('an unknown second factor is not rendered as On', (tester) async {
    await tester.pumpWidget(
      _app(
        const AccountHealthPage(
          data: V2AccountHealthPageData(lastCheckLabel: '2 hours ago'),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Two-step sign-in'), findsNothing);
    expect(find.text('On'), findsNothing);
  });

  testWidgets('run check calls the real check handler', (tester) async {
    var checks = 0;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: V2AccountHealthPageData(
            lastCheckLabel: '2 hours ago',
            onRunCheck: () => checks++,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final run = find.byKey(
      const ValueKey<String>('account-health-run-check'),
    );
    expect(run, findsOneWidget);
    await tester.ensureVisible(run);
    await tester.tap(run);
    expect(checks, 1);
  });

  testWidgets('a passed check shows the healthy state', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: V2AccountHealthPageData(
            healthy: true,
            lastCheckLabel: '2 hours ago',
            lastCheckDetail: 'Automated audit passed.',
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Healthy'), findsOneWidget);
    expect(find.text('2 hours ago · Automated audit passed.'), findsOneWidget);
  });

  testWidgets('a check without a verdict is not turned into Healthy', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const AccountHealthPage(
          data: V2AccountHealthPageData(lastCheckLabel: '2 hours ago'),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
  });

  testWidgets('controls without a handler are not rendered', (tester) async {
    await tester.pumpWidget(
      _app(
        const AccountHealthPage(data: V2AccountHealthPageData()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // No dead buttons: an action is only drawn when it can reach a handler.
    expect(find.text('Review'), findsNothing);
    expect(find.text('Contact support'), findsNothing);
    expect(find.text('Revoke'), findsNothing);
    expect(find.text('Turn on'), findsNothing);
    expect(find.text('Run a check'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    _setNarrowView(tester);
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      var contacted = false;
      await tester.pumpWidget(
        _narrow(
          _dataPage(onContactSupport: () => contacted = true),
          theme: theme,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull);
      _expectNoOverflow(tester);
      expect(find.text('All systems normal'), findsOneWidget);
      expect(find.text('92/100'), findsOneWidget);
      expect(find.text('Revoke'), findsOneWidget);

      await tester.ensureVisible(find.text('Contact support'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contact support'));
      expect(contacted, isTrue);
      _expectNoOverflow(tester);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('reduced motion keeps every section visible', (tester) async {
    await tester.pumpWidget(
      _narrow(_dataPage(), theme: OTheme.light(), reduceMotion: true),
    );
    await tester.pump();
    expect(find.text('All systems normal'), findsOneWidget);
    expect(find.text('Security score'), findsOneWidget);
    expect(find.text('ACTIVE SIGN-INS'), findsOneWidget);
    expect(find.text('SERVICE STATUS'), findsOneWidget);
    expect(find.text('Contact support'), findsOneWidget);
    _expectNoOverflow(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits 320 dp at normal text in both themes', (tester) async {
    _setNarrowView(tester);
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(_app(_dataPage(), theme: theme));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull);
      _expectNoOverflow(tester);
      // Normal text keeps the row inline: the pill sits beside the device name.
      expect(find.text('This device'), findsNWidgets(2));
    }
  });

  testWidgets('empty and error states fit 320 dp at 200 % text', (
    tester,
  ) async {
    _setNarrowView(tester);
    await tester.pumpWidget(
      _narrow(
        AccountHealthPage(
          data: V2AccountHealthPageData(hasData: false, onRunCheck: () {}),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No health data yet'), findsOneWidget);
    _expectNoOverflow(tester);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      _narrow(
        AccountHealthPage(
          data: V2AccountHealthPageData(
            errorMessage: 'Account health could not load.',
            onRetry: () {},
          ),
        ),
        theme: OTheme.dark(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Account health could not load.'), findsOneWidget);
    _expectNoOverflow(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('revoke confirmation fits 320 dp at 200 % text', (tester) async {
    _setNarrowView(tester);
    String? revoked;
    await tester.pumpWidget(
      _narrow(
        AccountHealthPage(data: _data(onRevokeDevice: (id) => revoked = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await _centerOn(tester, find.text('Revoke'));
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    expect(find.text('Revoke this device?'), findsOneWidget);
    _expectNoOverflow(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Revoke device'));
    await tester.pumpAndSettle();
    expect(revoked, 'mac');
  });

  testWidgets('deletion state fits 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    _setNarrowView(tester);
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      var cancelled = 0;
      await tester.pumpWidget(
        _narrow(
          AccountHealthPage(
            data: _data(
              accountStatus: V2AccountStatus.deletionPending,
              onCancelDeletion: () => cancelled++,
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull);
      _expectNoOverflow(tester);
      expect(find.text('Deletion requested'), findsOneWidget);
      expect(find.text('Storage left'), findsOneWidget);

      final cancel = find.byKey(
        const ValueKey<String>('account-health-cancel-deletion'),
      );
      await _centerOn(tester, cancel);
      await tester.tap(cancel);
      await tester.pumpAndSettle();

      expect(find.text('Cancel account deletion?'), findsOneWidget);
      _expectNoOverflow(tester);
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(
          const ValueKey<String>('account-health-confirm-cancel-deletion'),
        ),
      );
      await tester.pumpAndSettle();
      expect(cancelled, 1);
    }
  });

  testWidgets('suspended state fits 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    _setNarrowView(tester);
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrow(
          AccountHealthPage(
            data: _data(
              accountStatus: V2AccountStatus.suspendedForAbuse,
              onContactSupport: () {},
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull);
      _expectNoOverflow(tester);
      expect(find.text('Suspended for abuse'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('account-health-suspended-notice')),
        findsOneWidget,
      );
    }
  });
}
