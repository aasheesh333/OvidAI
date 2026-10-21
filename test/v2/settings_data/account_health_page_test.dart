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
}) {
  return V2AccountHealthPageData(
    statusTitle: 'All systems normal',
    statusMessage: 'No suspicious activity detected.',
    score: 92,
    lastCheckLabel: '2 hours ago',
    lastCheckDetail: 'Automated audit passed.',
    twoFactorEnabled: false,
    emailVerified: true,
    emailLabel: 'aarav@gmail.com',
    regionLabel: 'Mumbai, India',
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
    onReviewDevices: onReviewDevices,
    onDeviceTap: onDeviceTap,
    onRevokeDevice: onRevokeDevice,
    onEnableTwoFactor: onEnableTwoFactor,
    onContactSupport: onContactSupport,
    onRunCheck: onRunCheck,
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
    expect(find.text('Review'), findsOneWidget);
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

  testWidgets('review devices fires the primary callback', (tester) async {
    var reviewed = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onReviewDevices: () => reviewed = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Review'));
    await tester.tap(find.text('Review'));
    expect(reviewed, isTrue);
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
    expect(find.text('aarav@gmail.com'), findsNothing);
    expect(find.text('Mumbai, India'), findsNothing);
    expect(find.text('Region'), findsNothing);
    expect(find.text('No check has run yet.'), findsOneWidget);
    expect(find.text('No other devices are signed in.'), findsOneWidget);
    expect(find.text('No recent sign-ins to review.'), findsOneWidget);
    expect(find.text('Status is not available right now.'), findsOneWidget);
  });

  testWidgets('disabled actions are announced to accessibility', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const AccountHealthPage(data: V2AccountHealthPageData()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('Review')),
      isSemantics(
        label: 'Review',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    expect(
      tester.getSemantics(find.text('Contact support')).label,
      contains('Contact support, Get help with your account or sign-in'),
    );
    handle.dispose();
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
}
