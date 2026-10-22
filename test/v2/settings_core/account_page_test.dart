import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
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
  VoidCallback? onDataControl,
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
    onDataControl: onDataControl,
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

/// Every destination wired, the shape the settings route builds.
V2AccountData _fullData({
  Future<AccountDeletion> Function(String requestId)? requestDeletion,
  Future<AccountDeletion?> Function()? restoreDeletion,
}) {
  return _accountData(
    onEditProfile: () {},
    onLinkAccount: () {},
    onDataControl: () {},
    onSignOut: () {},
    requestDeletion: requestDeletion ?? (_) async => throw StateError('no'),
    restoreDeletion: restoreDeletion,
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
  tester.view.physicalSize = const Size(320, 800);
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

/// Opens the typed confirmation from the destructive row.
Future<void> _openDeleteSheet(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Delete account'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete account'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the identity and the five wired rows', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          onChangePhoto: () {},
          onEditProfile: () {},
          onLinkAccount: () {},
          onDataControl: () {},
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
    expect(find.text('Ovid user'), findsNothing);
    expect(find.text('Senior Platform Architect'), findsNothing);

    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(find.text('Google, Apple'), findsOneWidget);
    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);

    // Rows that only navigated to nothing are gone.
    expect(find.text('Credentials'), findsNothing);
    expect(find.text('Team & support'), findsNothing);
    expect(find.text('PROFILE DETAILS'), findsNothing);
    expect(find.text('Display name'), findsNothing);
  });

  testWidgets('renders identity and rows in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _fullData()));
    await tester.pumpAndSettle();

    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(find.text('Google, Apple'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('a placeholder name falls back to the real identifier', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          profile: const V2AccountProfile(
            name: 'Ovid user',
            email: 'aarav@gmail.com',
            initials: 'OU',
            planName: 'Plus',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ovid user'), findsNothing);
    expect(find.text('aarav'), findsOneWidget);
    expect(find.text('Plus'), findsOneWidget);
  });

  testWidgets('the plan pill comes from the actual tier', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          profile: const V2AccountProfile(
            name: 'Aarav Sharma',
            email: 'aarav@gmail.com',
            planName: '7x',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Plus'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          profile: const V2AccountProfile(
            name: 'Aarav Sharma',
            email: 'aarav@gmail.com',
            planName: 'free',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Free plan'), findsOneWidget);
  });

  testWidgets('the identity is announced once', (tester) async {
    _phoneSize(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(OTheme.light(), _fullData()));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Aarav Sharma, Ovid Plus'), findsOneWidget);
    // Neither the name nor the plan pill is a second node.
    expect(find.bySemanticsLabel('Aarav Sharma'), findsNothing);
    expect(find.bySemanticsLabel('Ovid Plus'), findsNothing);
    handle.dispose();
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
        _accountData(
          onLinkAccount: () {},
          onAccountTap: (_) => opened++,
        ),
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

  testWidgets('sign out is real and does not look like deletion', (
    tester,
  ) async {
    _phoneSize(tester);
    var signedOut = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(onSignOut: () => signedOut++, onDeleteAccount: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign out'), findsOneWidget);
    final context = tester.element(find.text('Sign out'));
    final c = OColors.of(context);
    // The destructive row carries the danger colour; sign-out stays neutral.
    expect(tester.widget<Text>(find.text('Delete account')).style?.color, c.danger);
    expect(tester.widget<Text>(find.text('Sign out')).style?.color, c.text);

    await tester.tap(find.text('Sign out'));
    await tester.pump();

    expect(signedOut, 1);
  });

  testWidgets('sign out shows progress and is disabled while signing out', (
    tester,
  ) async {
    _phoneSize(tester);
    final handle = tester.ensureSemantics();
    var signedOut = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(signOutLoading: true, onSignOut: () => signedOut++),
      ),
    );
    // The progress glyph never settles, so pump a frame.
    await tester.pump();

    expect(find.bySemanticsLabel('Signing out'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(signedOut, 0);
    handle.dispose();
  });

  testWidgets('data control row calls the injected callback', (tester) async {
    _phoneSize(tester);
    var opened = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _accountData(onDataControl: () => opened++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Data control'));
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

    await _openDeleteSheet(tester);

    expect(find.text('Delete your account?'), findsOneWidget);
    expect(find.text('Cannot be undone'), findsOneWidget);
    expect(find.text('This permanently removes:'), findsOneWidget);
    expect(find.text('Delete after 24 hours'), findsOneWidget);
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
    await _openDeleteSheet(tester);
    final confirm = tester.widget<OButton>(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    expect(confirm.onPressed, isNull);
    await _typeEmail(tester);
    await _tapTypedConfirm(tester);

    expect(deleted, 1);
  });

  testWidgets('delete submits the real service and reports the deadline', (
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

    await _openDeleteSheet(tester);
    await _typeEmail(tester);
    await _tapTypedConfirm(tester);

    expect(submitted, isNotNull);
    expect(submitted, hasLength(48));
    // The row itself reports the pending deletion with the deadline.
    expect(find.text('Deletion pending'), findsOneWidget);
    expect(find.textContaining('Deletes '), findsOneWidget);
    expect(find.text('Delete account'), findsNothing);
    // Truthful: never "deleted immediately", and the grace is one line.
    expect(find.textContaining('immediately'), findsNothing);
    expect(find.text('Deletion happens after 24 hours.'), findsOneWidget);
    expect(find.text('Deletion scheduled.'), findsOneWidget);
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

    await _openDeleteSheet(tester);
    await _typeEmail(tester);
    await _tapTypedConfirm(tester);

    expect(find.text('Verify the current account first.'), findsOneWidget);
    // Nothing claims the account was deleted.
    expect(find.text('Deletion pending'), findsNothing);
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

    await _openDeleteSheet(tester);

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

  testWidgets('pending deletion offers cancel during the grace period', (
    tester,
  ) async {
    _phoneSize(tester);
    final deadline = DateTime.now().add(const Duration(hours: 12));
    var cancelled = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          deletionPending: true,
          deletionDeadline: deadline,
          requestDeletion: (id) async => AccountDeletion('pending', deadline, id),
          restoreDeletion: () async {
            cancelled++;
            return AccountDeletion('cancelled', null, 'r1');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Deletion pending'), findsOneWidget);
    expect(find.textContaining('Deletes '), findsOneWidget);
    expect(find.text('24-hour grace · cancel anytime'), findsOneWidget);
    // Deleting again would only extend the request, so the idle row is gone.
    expect(find.text('Delete account'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('account-cancel-deletion')));
    await tester.pumpAndSettle();

    expect(cancelled, 1);
    expect(find.text('Deletion pending'), findsNothing);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.text('Deletion cancelled.'), findsOneWidget);
  });

  testWidgets('pending deletion hides cancel when nothing can cancel', (
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

    expect(find.text('Deletion pending'), findsOneWidget);
    // A disabled "Cancel deletion" button would be a dead control.
    expect(find.byKey(const ValueKey('account-cancel-deletion')), findsNothing);
    expect(find.text('Deletion happens after 24 hours.'), findsOneWidget);
  });

  testWidgets('the deleting state shows progress and cannot be resubmitted', (
    tester,
  ) async {
    _phoneSize(tester);
    final completer = Completer<AccountDeletion>();
    var requests = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(
          requestDeletion: (_) {
            requests++;
            return completer.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openDeleteSheet(tester);
    await _typeEmail(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('confirm-typed-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-typed-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Requesting deletion'), findsOneWidget);
    // The row is disabled while the request is in flight.
    await tester.tap(find.text('Delete account'));
    await tester.pump();
    expect(find.text('Delete your account?'), findsNothing);

    completer.complete(
      AccountDeletion(
        'pending',
        DateTime.now().add(const Duration(hours: 24)),
        'r1',
      ),
    );
    await tester.pumpAndSettle();

    expect(requests, 1);
    expect(find.text('Deletion pending'), findsOneWidget);
    expect(find.text('Requesting deletion'), findsNothing);
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

    // No dead controls: without a handler the row is removed.
    expect(find.text('Edit profile'), findsNothing);
    expect(find.text('Sign-in methods'), findsNothing);
    expect(find.text('Data control'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Delete account'), findsNothing);
  });

  testWidgets('fits 320 dp at 200% text without overflow', (tester) async {
    _narrowSize(tester);
    await tester.pumpWidget(
      _app(OTheme.light(), _fullData(), textScale: 2),
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

  testWidgets('fits 320 dp at 200% text in dark while deletion is pending', (
    tester,
  ) async {
    _narrowSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.dark(),
        _accountData(
          deletionPending: true,
          deletionDeadline: DateTime.now().add(const Duration(hours: 20)),
          restoreDeletion: () async =>
              AccountDeletion('cancelled', null, 'r1'),
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Deletion pending'), findsOneWidget);
    expect(find.text('24-hour grace · cancel anytime'), findsOneWidget);
  });

  for (final width in <double>[320, 412, 600, 800, 1280]) {
    for (final scale in <double>[1, 2]) {
      for (final dark in <bool>[false, true]) {
        testWidgets(
          'lays out at ${width.toInt()} dp, ${scale}x, ${dark ? 'dark' : 'light'}',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

            await tester.pumpWidget(
              _app(
                dark ? OTheme.dark() : OTheme.light(),
                _fullData(),
                textScale: scale,
              ),
            );
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            final row = tester.getSize(
              find.byKey(const ValueKey<String>('account-delete-row')),
            );
            expect(row.height, greaterThanOrEqualTo(56));
            final limit = width >= 900
                ? 720.0
                : width >= 600
                ? 640.0
                : width;
            expect(row.width, lessThanOrEqualTo(limit));
            if (width >= 600) {
              expect(
                tester
                    .getRect(
                      find.byKey(
                        const ValueKey<String>('account-delete-row'),
                      ),
                    )
                    .center
                    .dx,
                moreOrLessEquals(width / 2, epsilon: 1),
              );
            }
          },
        );
      }
    }
  }

  testWidgets('content is centred and capped at 600, 900 and 1280 dp', (
    tester,
  ) async {
    for (final width in <double>[600, 900, 1280]) {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _app(
          OTheme.light(),
          _accountData(onEditProfile: () {}, onDataControl: () {}),
        ),
      );
      await tester.pumpAndSettle();

      final row = tester.getRect(
        find.byKey(const ValueKey<String>('account-data-control-row')),
      );
      final limit = width >= 900 ? 720.0 : 640.0;

      expect(row.width, lessThanOrEqualTo(limit));
      expect(row.width, lessThan(width), reason: 'rows must not stretch');
      expect(
        row.center.dx,
        moreOrLessEquals(width / 2, epsilon: 1),
        reason: 'content must be centred, not left aligned',
      );
    }
  });

  testWidgets('destructive row announces its consequence', (tester) async {
    _phoneSize(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(OTheme.light(), _accountData(onDeleteAccount: () {})),
    );
    await tester.pumpAndSettle();

    final node = tester.getSemantics(
      find.bySemanticsLabel('Delete account'),
    );
    final data = node.getSemanticsData();
    expect(data.hint, contains('Destructive'));
    expect(data.hint, contains('24 hours'));
    expect(data.flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  testWidgets('icon controls meet the 48 dp target and carry labels', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _accountData(onChangePhoto: () {}, onDeleteAccount: () {}),
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
          .getSize(find.byKey(const ValueKey<String>('account-delete-row')))
          .height,
      greaterThanOrEqualTo(48),
    );
  });
}
