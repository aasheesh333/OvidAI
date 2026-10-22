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
  VoidCallback? onContactSupport,
  VoidCallback? onCancelDeletion,
  VoidCallback? onRetry,
  V2AccountStatus? accountStatus = V2AccountStatus.active,
  bool emailVerified = true,
  String emailLabel = 'aarav@gmail.com',
  String deletionScheduledLabel = '',
  bool hasData = true,
}) {
  return V2AccountHealthPageData(
    emailVerified: emailVerified,
    emailLabel: emailLabel,
    accountStatus: accountStatus,
    deletionScheduledLabel: deletionScheduledLabel,
    hasData: hasData,
    onContactSupport: onContactSupport,
    onCancelDeletion: onCancelDeletion,
    onRetry: onRetry,
  );
}

void main() {
  testWidgets('renders status, sign-in method and support in light mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(onContactSupport: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    // The pill leads the page and the status row repeats the same fact.
    expect(find.text('Active'), findsNWidgets(2));
    expect(
      find.text('Your account is in good standing.'),
      findsOneWidget,
    );
    expect(find.text('Account status'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('aarav@gmail.com'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Contact support'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account health'), findsOneWidget);
    expect(find.text('Active'), findsNWidgets(2));
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
    expect(find.text('Not checked'), findsNWidgets(2));
    expect(find.text('Active'), findsNothing);
    expect(
      find.text('No account status has been reported yet.'),
      findsOneWidget,
    );
  });

  testWidgets('deletion pending shows its date and can be cancelled', (
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

    expect(find.text('Deletion pending'), findsNWidgets(2));
    expect(
      find.text('Your account is scheduled for deletion.'),
      findsOneWidget,
    );
    expect(find.text('Deletion'), findsOneWidget);
    expect(find.text('Deletes on 20 Nov 2026'), findsOneWidget);
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

  testWidgets('a pending deletion without a handler offers no button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(
          data: _data(accountStatus: V2AccountStatus.deletionPending),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Deletion pending'), findsNWidgets(2));
    expect(find.text('Cancel deletion'), findsNothing);
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

    expect(find.text('Suspended'), findsNWidgets(2));
    // One contact action, in the list, not a second full-width button.
    expect(find.text('Contact support'), findsOneWidget);

    await _centerOn(tester, find.text('Contact support'));
    await tester.tap(find.text('Contact support'));
    expect(contacted, isTrue);
  });

  testWidgets('an unverified email is named without a dead Verify action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AccountHealthPage(data: _data(emailVerified: false)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('Verified'), findsNothing);
    // There is no verification sender behind this page.
    expect(find.text('Verify'), findsNothing);
  });

  testWidgets('empty state offers no dead action', (tester) async {
    await tester.pumpWidget(
      _app(AccountHealthPage(data: _data(hasData: false)), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('No account data'), findsOneWidget);
    expect(find.text('Sign in to see your account status.'), findsOneWidget);
    expect(find.byType(OButton), findsNothing);
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
      _app(AccountHealthPage(data: const V2AccountHealthPageData(loading: true)), theme: OTheme.light()),
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
            data: _data(onContactSupport: () {}),
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

  testWidgets('reduced motion keeps every row visible', (tester) async {
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
