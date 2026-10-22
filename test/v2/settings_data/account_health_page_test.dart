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
  ValueChanged<String>? onDeviceTap,
  ValueChanged<String>? onRevokeDevice,
  VoidCallback? onEnableTwoFactor,
  VoidCallback? onVerifyEmail,
  VoidCallback? onContactSupport,
  VoidCallback? onRunCheck,
  VoidCallback? onCancelDeletion,
  V2AccountStatus? accountStatus = V2AccountStatus.active,
  bool? twoFactorEnabled = false,
  bool emailVerified = true,
  bool? healthy = true,
  String lastCheckLabel = '2 hours ago',
  String lastCheckDetail = 'Automated audit passed.',
  List<V2SignInDevice> devices = const [
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
}) {
  return V2AccountHealthPageData(
    statusTitle: 'All systems normal',
    statusMessage: 'No suspicious activity detected.',
    healthy: healthy,
    score: 92,
    lastCheckLabel: lastCheckLabel,
    lastCheckDetail: lastCheckDetail,
    twoFactorEnabled: twoFactorEnabled,
    emailVerified: emailVerified,
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
    ],
    deletionRequestedLabel: '21 Oct 2026',
    deletionScheduledLabel: '20 Nov 2026',
    services: const [
      V2ServiceStatus(name: 'Chat and sync', statusLabel: 'Operational'),
    ],
    devices: devices,
    recentSignIns: const [
      V2SignInEvent(
        id: 'sign-1',
        device: 'Pixel 9 Pro',
        location: 'Mumbai, India',
        timeLabel: 'Today at 9:12 AM',
        current: true,
      ),
    ],
    onDeviceTap: onDeviceTap,
    onRevokeDevice: onRevokeDevice ?? (_) {},
    onEnableTwoFactor: onEnableTwoFactor,
    onVerifyEmail: onVerifyEmail,
    onContactSupport: onContactSupport,
    onRunCheck: onRunCheck,
    onCancelDeletion: onCancelDeletion,
  );
}

void main() {
  testWidgets('renders one status line and a short list in light mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    expect(find.text('Healthy'), findsOneWidget);
    expect(
      find.text('2 hours ago · Automated audit passed.'),
      findsOneWidget,
    );
    expect(find.text('Account status'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Two-step sign-in'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Pixel 9 Pro'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('MacBook Air'), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    expect(find.text('Healthy'), findsOneWidget);
  });

  testWidgets('deleted summary sections are gone', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Security score'), findsNothing);
    expect(find.text('92/100'), findsNothing);
    expect(find.text('ACCOUNT SUMMARY'), findsNothing);
    expect(find.text('Storage left'), findsNothing);
    expect(find.text('Daily usage left'), findsNothing);
    expect(find.text('SERVICE STATUS'), findsNothing);
    expect(find.text('Chat and sync'), findsNothing);
    expect(find.text('ACTIVE SIGN-INS'), findsNothing);
    expect(find.text('Mumbai, India'), findsNothing);
    expect(find.text('DELETION REQUEST'), findsNothing);
    expect(find.text('Deletion requested'), findsNothing);
    expect(find.text('Review'), findsNothing);
  });

  testWidgets('no check result never claims a healthy account', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(healthy: null, lastCheckLabel: '', lastCheckDetail: ''),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not checked yet'), findsOneWidget);
    expect(find.text('No check has run yet.'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
  });

  testWidgets('a failing check is reported instead of a healthy claim', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(healthy: false)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
  });

  testWidgets('a check without a verdict is not turned into Healthy', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(healthy: null)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
  });

  testWidgets('a missing account status is not rendered as Active', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(accountStatus: null)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account status'), findsOneWidget);
    expect(find.text('Not checked'), findsOneWidget);
    expect(find.text('Active'), findsNothing);
  });

  testWidgets('deletion pending shows its state and can be cancelled', (
    tester,
  ) async {
    var cancelled = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.deletionPending,
            onCancelDeletion: () => cancelled = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Deletion pending'), findsOneWidget);
    expect(find.text('Cancel deletion'), findsOneWidget);

    await _centerOn(tester, find.text('Cancel deletion'));
    await tester.tap(find.text('Cancel deletion'));
    await tester.pumpAndSettle();

    expect(find.text('Cancel account deletion?'), findsOneWidget);
    await tester.tap(find.text('Keep deletion'));
    await tester.pumpAndSettle();
    expect(cancelled, isFalse);

    await _centerOn(tester, find.text('Cancel deletion'));
    await tester.tap(find.text('Cancel deletion'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('account-health-confirm-cancel-deletion'),
      ),
    );
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
  });

  testWidgets('suspended accounts are named and can reach support', (
    tester,
  ) async {
    var contacted = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(
            accountStatus: V2AccountStatus.suspendedForAbuse,
            onContactSupport: () => contacted = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Suspended'), findsOneWidget);
    // One contact action, in the list, not a second full-width button.
    expect(find.text('Contact support'), findsOneWidget);

    await _centerOn(tester, find.text('Contact support'));
    await tester.tap(find.text('Contact support'));
    expect(contacted, isTrue);
  });

  testWidgets('two-step sign-in turns on from its row', (tester) async {
    var enabled = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(onEnableTwoFactor: () => enabled = true),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await _centerOn(tester, find.text('Turn on'));
    await tester.tap(find.text('Turn on'));
    expect(enabled, isTrue);
  });

  testWidgets('an unknown two-step state is not rendered', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(twoFactorEnabled: null)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Two-step sign-in'), findsNothing);
    expect(find.text('On'), findsNothing);
  });

  testWidgets('an unverified email offers Verify when wired', (tester) async {
    var verified = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(emailVerified: false, onVerifyEmail: () => verified = true),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await _centerOn(tester, find.text('Verify'));
    await tester.tap(find.text('Verify'));
    expect(verified, isTrue);
  });

  testWidgets('an unverified email without a handler says so', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(emailVerified: false)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('Verify'), findsNothing);
  });

  testWidgets('active sign-ins are listed without a redundant Review button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onDeviceTap: (_) {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pixel 9 Pro'), findsOneWidget);
    expect(find.text('MacBook Air'), findsOneWidget);
    expect(find.text('Review'), findsNothing);
  });

  testWidgets('revoking a device asks for confirmation first', (tester) async {
    String? revoked;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(onRevokeDevice: (id) => revoked = id),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await _centerOn(tester, find.text('Revoke'));
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    expect(find.text('Revoke this device?'), findsOneWidget);
    expect(revoked, isNull);

    await tester.tap(find.text('Revoke device'));
    await tester.pumpAndSettle();
    expect(revoked, 'mac');
  });

  testWidgets('run check is a single header action', (tester) async {
    var ran = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onRunCheck: () => ran = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Run again'));
    expect(ran, isTrue);
  });

  testWidgets('empty state offers to run a check', (tester) async {
    var ran = false;
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: V2AccountHealthPageData(
            hasData: false,
            onRunCheck: () => ran = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No health data yet'), findsOneWidget);
    await tester.tap(find.text('Run a check'));
    expect(ran, isTrue);
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

  testWidgets('loading state renders skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: const V2AccountHealthPageData(loading: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Account status'), findsNothing);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200 % text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      _setNarrowView(tester);
      await tester.pumpWidget(
        _narrow(
          AccountHealthPage(
            data: _data(onRunCheck: () {}, onContactSupport: () {}),
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
        _setNarrowView(tester);
        await tester.pumpWidget(
          _narrow(
            AccountHealthPage(
              data: _data(
                accountStatus: V2AccountStatus.deletionPending,
                onCancelDeletion: () {},
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

    testWidgets(
      'suspended state fits 320 dp at 200 % text (${dark ? 'dark' : 'light'})',
      (tester) async {
        _setNarrowView(tester);
        await tester.pumpWidget(
          _narrow(
            AccountHealthPage(
              data: _data(
                accountStatus: V2AccountStatus.suspendedForAbuse,
                onContactSupport: () {},
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

  testWidgets('reduced motion keeps every section visible', (tester) async {
    _setNarrowView(tester);
    await tester.pumpWidget(
      _narrow(
        AccountHealthPage(data: _data(onContactSupport: () {})),
        theme: OTheme.light(),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account status'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Contact support'), findsOneWidget);
  });
}
