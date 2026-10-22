import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/account_page.dart';

const _profile = V2AccountProfile(
  name: 'Aarav Sharma',
  email: 'aarav@gmail.com',
  role: 'Senior Platform Architect',
  planName: 'Ovid Plus',
  initials: 'AS',
);

const _fields = <V2AccountField>[
  V2AccountField(
    id: 'display_name',
    label: 'Display name',
    value: 'Aarav Sharma',
    editable: true,
  ),
  V2AccountField(
    id: 'email',
    label: 'Email address',
    value: 'aarav@gmail.com',
    verified: true,
  ),
  V2AccountField(id: 'phone', label: 'Phone number', value: '+91 98765 43210'),
  V2AccountField(
    id: 'language',
    label: 'Interface language',
    value: 'English (US)',
  ),
  V2AccountField(id: 'region', label: 'Primary region', value: 'India'),
];

const _accounts = <V2ConnectedAccount>[
  V2ConnectedAccount(id: 'google', name: 'Google', detail: 'aarav@gmail.com'),
  V2ConnectedAccount(
    id: 'apple',
    name: 'Apple',
    detail: 'a***@privaterelay.appleid.com',
  ),
];

V2AccountData _accountData({
  V2AccountStatus status = V2AccountStatus.ready,
  V2AccountProfile? profile = _profile,
  List<V2AccountField> fields = _fields,
  List<V2ConnectedAccount> accounts = _accounts,
  VoidCallback? onChangePhoto,
  VoidCallback? onEditProfile,
  ValueChanged<V2AccountField>? onFieldTap,
  ValueChanged<V2ConnectedAccount>? onAccountTap,
  VoidCallback? onLinkAccount,
  VoidCallback? onOpenCredentials,
  VoidCallback? onTeamSupport,
  VoidCallback? onSignOut,
  VoidCallback? onDeleteAccount,
  VoidCallback? onManageSubscription,
  VoidCallback? onRestoreAccount,
  VoidCallback? onSignIn,
  VoidCallback? onRetry,
  Future<AccountDeletion> Function(String requestId)? requestDeletion,
  Future<AccountDeletion?> Function()? restoreDeletion,
  bool signOutLoading = false,
  bool deletionPending = false,
  DateTime? deletionDeadline,
  bool deletionLoading = false,
}) {
  return V2AccountData(
    status: status,
    profile: profile,
    fields: fields,
    connectedAccounts: accounts,
    onChangePhoto: onChangePhoto,
    onEditProfile: onEditProfile,
    onFieldTap: onFieldTap,
    onAccountTap: onAccountTap,
    onLinkAccount: onLinkAccount,
    onOpenCredentials: onOpenCredentials,
    onTeamSupport: onTeamSupport,
    onSignOut: onSignOut,
    onDeleteAccount: onDeleteAccount,
    onManageSubscription: onManageSubscription,
    onRestoreAccount: onRestoreAccount,
    onSignIn: onSignIn,
    onRetry: onRetry,
    requestDeletion: requestDeletion,
    restoreDeletion: restoreDeletion,
    signOutLoading: signOutLoading,
    deletionPending: deletionPending,
    deletionDeadline: deletionDeadline,
    deletionLoading: deletionLoading,
  );
}

Widget _app(ThemeData theme, V2AccountData data, {double textScale = 1}) {
  return MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: AccountPage(data: data),
      ),
    ),
  );
}

void _phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Narrowest supported phone: 320 dp with the text doubled.
void _narrowSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Tablet / desktop width, tall enough for the whole page.
void _wideSize(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Types the account email into the typed-confirmation sheet.
Future<void> _typeEmail(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('confirm-typed-field')),
    'aarav@gmail.com',
  );
  await tester.pump();
}

/// Scrolls the typed-confirmation sheet to its destructive button and taps it.
Future<void> _tapTypedConfirm(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('confirm-typed-button'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the header, profile and at most five rows', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          onChangePhoto: () {},
          onEditProfile: () {},
          onOpenCredentials: () {},
          onTeamSupport: () {},
          onSignOut: () {},
          onDeleteAccount: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Ovid Plus'), findsOneWidget);
    // The header is avatar + name + plan. Profile details, email included,
    // live behind the one "Edit profile" action.
    expect(find.text('aarav@gmail.com'), findsNothing);

    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(find.text('Google, Apple'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
    expect(find.text('Team & support'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);

    // The profile-detail grid is gone.
    expect(find.text('PROFILE DETAILS'), findsNothing);
    expect(find.text('Display name'), findsNothing);
    expect(find.text('Email address'), findsNothing);
    expect(find.text('Verified'), findsNothing);
    expect(find.text('Senior Platform Architect'), findsNothing);
    expect(find.text('All synced'), findsNothing);
  });

  testWidgets('renders correctly in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _accountData()));
    await tester.pumpAndSettle();

    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(find.text('Google, Apple'), findsOneWidget);
  });

  testWidgets('photo control is hidden when no picker is wired', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _accountData()));
    await tester.pumpAndSettle();

    // A visible button with a null handler is a dead control.
    expect(find.text('Change photo'), findsNothing);
    expect(find.byTooltip('Change photo'), findsNothing);
  });

  testWidgets('edit profile calls the injected callback', (tester) async {
    _phoneSize(tester);
    var edits = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _accountData(onEditProfile: () => edits++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit profile'));
    await tester.pump();

    expect(edits, 1);
  });

  testWidgets('edit profile falls back to the first editable field', (
    tester,
  ) async {
    _phoneSize(tester);
    V2AccountField? tapped;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(onFieldTap: (field) => tapped = field),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit profile'));
    await tester.pump();

    expect(tapped?.id, 'display_name');
  });

  testWidgets('sign-in methods opens a sheet with the linked accounts', (
    tester,
  ) async {
    _phoneSize(tester);
    var opened = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(onAccountTap: (_) => opened++),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign-in methods'));
    await tester.pumpAndSettle();

    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Apple'), findsOneWidget);
    expect(find.text('Connected'), findsNWidgets(2));

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('empty linked accounts shows None linked and can link', (
    tester,
  ) async {
    _phoneSize(tester);
    var linked = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(accounts: const [], onLinkAccount: () => linked++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('None linked'), findsOneWidget);

    await tester.tap(find.text('Sign-in methods'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Link account'));
    await tester.pumpAndSettle();

    expect(linked, 1);
  });

  testWidgets('sign out calls the injected callback', (tester) async {
    var signedOut = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _accountData(onSignOut: () => signedOut++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pump();

    expect(signedOut, 1);
  });

  testWidgets('credentials row opens the credentials screen', (tester) async {
    _phoneSize(tester);
    var opened = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _accountData(onOpenCredentials: () => opened++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Credentials'));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('team and support row calls its callback', (tester) async {
    _phoneSize(tester);
    var opened = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _accountData(onTeamSupport: () => opened++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Team & support'));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('delete asks for a typed confirmation and can be cancelled', (
    tester,
  ) async {
    _phoneSize(tester);
    var deleted = 0;
    var managed = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          onDeleteAccount: () => deleted++,
          onManageSubscription: () => managed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    expect(find.text('Delete your account?'), findsOneWidget);
    expect(find.text('Cannot be undone'), findsOneWidget);
    expect(find.text('This permanently removes:'), findsOneWidget);
    expect(find.text('Manage Play subscription'), findsOneWidget);
    expect(deleted, 0);

    await tester.ensureVisible(find.text('Manage Play subscription'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage Play subscription'));
    await tester.pump();
    expect(managed, 1);

    await tester.ensureVisible(find.text('Keep account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep account'));
    await tester.pumpAndSettle();
    expect(deleted, 0);

    // Typing is required: the destructive button stays locked until the
    // account email matches.
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    final confirm = tester.widget<OButton>(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    expect(confirm.onPressed, isNull);
    await _typeEmail(tester);
    await _tapTypedConfirm(tester);

    expect(deleted, 1);
  });

  testWidgets('delete submits the real deletion service and shows the receipt', (
    tester,
  ) async {
    _phoneSize(tester);
    String? submitted;
    final deadline = DateTime.now().toUtc().add(const Duration(hours: 24));
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          requestDeletion: (requestId) async {
            submitted = requestId;
            return AccountDeletion('pending', deadline, requestId);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await _typeEmail(tester);
    await _tapTypedConfirm(tester);

    expect(submitted, isNotNull);
    expect(submitted, hasLength(48));
    // Truthful: scheduled, with a deadline, never "deleted immediately".
    expect(find.text('Deletion scheduled'), findsOneWidget);
    expect(find.textContaining('will be deleted on'), findsOneWidget);
    expect(find.textContaining('immediately'), findsNothing);
    expect(find.text('Delete account'), findsNothing);
    // No restore handler was injected, so no dead Restore button appears.
    expect(find.widgetWithText(OButton, 'Restore account'), findsNothing);
  });

  testWidgets('a failed deletion request is reported, not swallowed', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          requestDeletion: (_) async =>
              throw const AccountException('Verify the current account first.'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await _typeEmail(tester);
    await _tapTypedConfirm(tester);

    expect(find.text('Verify the current account first.'), findsOneWidget);
    // Nothing claims the account was deleted.
    expect(find.text('Deletion scheduled'), findsNothing);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('a placeholder contact falls back to the DELETE target', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          profile: const V2AccountProfile(
            name: 'Aarav',
            email: 'Signed in with phone',
          ),
          onDeleteAccount: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    expect(find.text('DELETE'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('confirm-typed-field')),
      'DELETE',
    );
    await tester.pump();
    final confirm = tester.widget<OButton>(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    expect(confirm.onPressed, isNotNull);
  });

  testWidgets('restore uses the real restore service', (tester) async {
    _phoneSize(tester);
    var restored = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          deletionPending: true,
          deletionDeadline: DateTime.now().add(const Duration(hours: 12)),
          restoreDeletion: () async {
            restored++;
            return AccountDeletion('cancelled', null, 'r1');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.widgetWithText(OButton, 'Restore account'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OButton, 'Restore account'));
    await tester.pumpAndSettle();

    expect(restored, 1);
    expect(find.text('Deletion scheduled'), findsNothing);
  });

  testWidgets('pending deletion shows the deadline and restores the account', (
    tester,
  ) async {
    _phoneSize(tester);
    final deadline = DateTime.now().add(const Duration(hours: 12));
    var restored = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          deletionPending: true,
          deletionDeadline: deadline,
          onRestoreAccount: () => restored++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Deletion scheduled'), findsOneWidget);
    expect(find.textContaining('will be deleted on'), findsOneWidget);
    expect(
      find.textContaining('Signing in lets you choose Restore account'),
      findsOneWidget,
    );
    // Deleting again would only extend the request, so the action is hidden.
    expect(find.text('Delete account'), findsNothing);

    await tester.ensureVisible(find.widgetWithText(OButton, 'Restore account'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OButton, 'Restore account'));
    await tester.pump();

    expect(restored, 1);
  });

  testWidgets('pending banner hides restore when nothing can restore', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          deletionPending: true,
          deletionDeadline: DateTime.now().add(const Duration(hours: 12)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Deletion scheduled'), findsOneWidget);
    // A disabled "Restore account" button would be a dead control.
    expect(find.widgetWithText(OButton, 'Restore account'), findsNothing);
  });

  testWidgets('delete sheet fits a narrow phone at 200% text', (tester) async {
    _narrowSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(onDeleteAccount: () {}, onManageSubscription: () {}),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-typed-button')), findsOneWidget);
  });

  testWidgets('full empty state signs in', (tester) async {
    var signedIn = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          status: V2AccountStatus.empty,
          profile: null,
          fields: const [],
          accounts: const [],
          onSignIn: () => signedIn++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No account found'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(signedIn, 1);
  });

  testWidgets('error state retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          status: V2AccountStatus.error,
          profile: null,
          fields: const [],
          accounts: const [],
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('fits 320 dp at 200% text without overflow', (tester) async {
    _narrowSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(onSignOut: () {}, onDeleteAccount: () {}),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Sign-in methods'), findsOneWidget);

    // The body scrolls, so the destructive action stays reachable.
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200% text in dark', (tester) async {
    _narrowSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.dark(),
        _accountData(
          deletionPending: true,
          deletionDeadline: DateTime.now().add(const Duration(hours: 20)),
          onRestoreAccount: () {},
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(find.text('Deletion scheduled'), findsOneWidget);
  });

  testWidgets('loading shows skeleton rows', (tester) async {
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          status: V2AccountStatus.loading,
          profile: null,
          fields: const [],
          accounts: const [],
        ),
      ),
    );
    // The shimmer never settles, so pump a frame instead of settling.
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('unwired actions are not shown at all', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _accountData()));
    await tester.pumpAndSettle();

    // No dead buttons: without a handler the control is removed.
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Delete account'), findsNothing);
    expect(find.text('Edit profile'), findsNothing);
    expect(find.text('Credentials'), findsNothing);
    expect(find.text('Team & support'), findsNothing);
  });

  for (final width in <double>[600, 900]) {
    testWidgets('content is centred and capped at $width dp', (tester) async {
      _wideSize(tester, width);
      await tester.pumpWidget(
        _app(
          OTheme.light(),
          _accountData(onEditProfile: () {}, onSignOut: () {}),
        ),
      );
      await tester.pumpAndSettle();

      final card = tester.getRect(find.byType(OCard).first);
      final limit = width >= 900 ? 720.0 : 640.0;

      expect(card.width, lessThanOrEqualTo(limit));
      expect(card.width, lessThan(width), reason: 'rows must not stretch');
      expect(
        card.center.dx,
        moreOrLessEquals(width / 2, epsilon: 1),
        reason: 'content must be centred, not left aligned',
      );
    });
  }

  testWidgets('icon controls meet the 48 dp target and carry labels', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(onChangePhoto: () {}, onSignOut: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Change photo'), findsWidgets);
    expect(
      tester.getSize(find.byTooltip('Change photo')).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester
          .getSize(
            find.ancestor(
              of: find.text('Sign out'),
              matching: find.byType(OutlinedButton),
            ),
          )
          .height,
      greaterThanOrEqualTo(48),
    );
  });
}
