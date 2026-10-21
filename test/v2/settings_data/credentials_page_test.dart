import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/credentials_page.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

Future<void> _pump(
  WidgetTester tester, {
  V2CredentialsPageData? data,
  bool dark = false,
  double width = 400,
  double textScale = 1,
  bool disableAnimations = false,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: CredentialsPage(data: data ?? _data()),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

const _google = V2Credential(
  id: 'google',
  kind: V2CredentialKind.google,
  title: 'Google',
  subtitle: 'aarav@gmail.com',
);

const _github = V2Credential(
  id: 'github',
  kind: V2CredentialKind.github,
  title: 'GitHub',
  subtitle: 'aarav-sharma',
);

const _token = V2Credential(
  id: 'token',
  kind: V2CredentialKind.token,
  title: 'Personal access token',
  subtitle: 'pat_live_••••••9x4q',
);

const _browser = V2BrowserCredential(
  id: 'b1',
  site: 'example.com',
  username: 'aarav@example.com',
  password: 'hunter2',
);

V2CredentialsPageData _data({
  VoidCallback? onAddToken,
  VoidCallback? onRevokeAll,
  VoidCallback? onManageCloudKey,
  ValueChanged<String>? onCredentialTap,
  V2Credential? token = _token,
  List<V2BrowserCredential> browser = const [_browser],
  bool? githubOAuthConnected,
  bool githubPatAdded = false,
  ValueChanged<V2BrowserCredential>? onAddBrowserCredential,
  ValueChanged<V2BrowserCredential>? onEditBrowserCredential,
  ValueChanged<V2BrowserCredential>? onDeleteBrowserCredential,
  VoidCallback? onConnectGithubOAuth,
  VoidCallback? onDisconnectGithubOAuth,
  VoidCallback? onAddGithubPat,
  VoidCallback? onRemoveGithubPat,
  bool cloudKeyActive = true,
}) {
  return V2CredentialsPageData(
    google: _google,
    github: _github,
    token: token,
    browserCredentials: browser,
    githubOAuthConnected: githubOAuthConnected,
    githubPatAdded: githubPatAdded,
    cloudKeyActive: cloudKeyActive,
    onAddToken: onAddToken,
    onRevokeAll: onRevokeAll,
    onManageCloudKey: onManageCloudKey,
    onCredentialTap: onCredentialTap,
    onAddBrowserCredential: onAddBrowserCredential,
    onEditBrowserCredential: onEditBrowserCredential,
    onDeleteBrowserCredential: onDeleteBrowserCredential,
    onConnectGithubOAuth: onConnectGithubOAuth,
    onDisconnectGithubOAuth: onDisconnectGithubOAuth,
    onAddGithubPat: onAddGithubPat,
    onRemoveGithubPat: onRemoveGithubPat,
  );
}

void main() {
  testWidgets('renders connected credentials in light mode', (tester) async {
    await tester.pumpWidget(
      _app(CredentialsPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Credentials'), findsOneWidget);
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Personal access token'), findsOneWidget);
    expect(find.text('pat_live_••••••9x4q'), findsOneWidget);
    expect(find.text('Cloud key active'), findsOneWidget);
    expect(find.text('Revoke all credentials'), findsOneWidget);
    expect(find.text('BROWSER LOGINS'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('aarav@example.com · ••••••••'), findsOneWidget);
    expect(
      find.textContaining('never shown to the agent in plain text'),
      findsWidgets,
    );
    expect(find.text('GITHUB ACCESS'), findsOneWidget);
    expect(find.text('OAuth (browser sign-in)'), findsOneWidget);
    expect(find.text('GitHub personal access token'), findsOneWidget);
    expect(find.text('hunter2'), findsNothing);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(CredentialsPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Credentials'), findsOneWidget);
    expect(find.text('3 stored'), findsOneWidget);
  });

  testWidgets('empty state offers to connect Google', (tester) async {
    var connected = false;
    await tester.pumpWidget(
      _app(
        CredentialsPage(
          data: V2CredentialsPageData(onConnectGoogle: () => connected = true),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No credentials yet'), findsOneWidget);
    await tester.tap(find.text('Connect Google'));
    expect(connected, isTrue);
  });

  testWidgets('add token fires the primary callback', (tester) async {
    var added = false;
    await tester.pumpWidget(
      _app(
        CredentialsPage(data: _data(onAddToken: () => added = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add'));
    await tester.tap(find.text('Add'));
    expect(added, isTrue);
  });

  testWidgets('adds a browser login with the entered values', (tester) async {
    V2BrowserCredential? added;
    await _pump(
      tester,
      data: _data(onAddBrowserCredential: (credential) => added = credential),
    );

    await tester.ensureVisible(find.text('Add login').first);
    await tester.tap(find.text('Add login').first);
    await tester.pumpAndSettle();

    expect(find.text('Add browser login'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('browser-site-field')),
      'news.ycombinator.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('browser-username-field')),
      'aarav',
    );
    await tester.enterText(
      find.byKey(const ValueKey('browser-password-field')),
      's3cret',
    );
    await tester.pump();
    await tester.tap(find.text('Save login'));
    await tester.pumpAndSettle();

    expect(added?.site, 'news.ycombinator.com');
    expect(added?.username, 'aarav');
    expect(added?.password, 's3cret');
    expect(added?.id, isNotEmpty);
  });

  testWidgets('edits a browser login and keeps a blank password', (
    tester,
  ) async {
    V2BrowserCredential? edited;
    await _pump(
      tester,
      data: _data(onEditBrowserCredential: (credential) => edited = credential),
    );

    await tester.ensureVisible(find.byTooltip('Edit example.com'));
    await tester.tap(find.byTooltip('Edit example.com'));
    await tester.pumpAndSettle();

    expect(find.text('Edit browser login'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('browser-site-field')),
      'example.org',
    );
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(edited?.id, 'b1');
    expect(edited?.site, 'example.org');
    expect(edited?.username, 'aarav@example.com');
    expect(edited?.password, 'hunter2');
  });

  testWidgets('deletes a browser login after confirmation', (tester) async {
    V2BrowserCredential? deleted;
    await _pump(
      tester,
      data: _data(
        onDeleteBrowserCredential: (credential) => deleted = credential,
      ),
    );

    await tester.ensureVisible(find.byTooltip('Delete example.com'));
    await tester.tap(find.byTooltip('Delete example.com'));
    await tester.pumpAndSettle();

    expect(find.text('Delete login?'), findsOneWidget);
    expect(deleted, isNull);

    await tester.tap(find.text('Delete login'));
    await tester.pumpAndSettle();
    expect(deleted?.id, 'b1');
  });

  testWidgets('cancelling a browser login delete keeps it', (tester) async {
    var deleted = false;
    await _pump(
      tester,
      data: _data(onDeleteBrowserCredential: (_) => deleted = true),
    );

    await tester.ensureVisible(find.byTooltip('Delete example.com'));
    await tester.tap(find.byTooltip('Delete example.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep login'));
    await tester.pumpAndSettle();

    expect(deleted, isFalse);
  });

  testWidgets('shows GitHub OAuth and token state with actions', (
    tester,
  ) async {
    var connected = false;
    var removed = false;
    await _pump(
      tester,
      data: _data(
        githubOAuthConnected: false,
        githubPatAdded: true,
        onConnectGithubOAuth: () => connected = true,
        onRemoveGithubPat: () => removed = true,
      ),
    );

    expect(find.text('OAuth (browser sign-in)'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('GitHub personal access token'), findsOneWidget);
    expect(find.text('Added · used for git clone and push'), findsOneWidget);

    await tester.ensureVisible(find.text('Connect'));
    await tester.tap(find.text('Connect'));
    expect(connected, isTrue);

    await tester.ensureVisible(find.text('Remove'));
    await tester.tap(find.text('Remove'));
    expect(removed, isTrue);
  });

  testWidgets('browser login sheet fits 320 dp at 200% text', (tester) async {
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      data: _data(onAddBrowserCredential: (_) {}),
    );

    await tester.ensureVisible(find.text('Add login').first);
    await tester.tap(find.text('Add login').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Save login'));
    await tester.pumpAndSettle();
    expect(find.text('Save login'), findsOneWidget);
  });

  testWidgets('revoke all asks for confirmation first', (tester) async {
    var revoked = false;
    await tester.pumpWidget(
      _app(
        CredentialsPage(data: _data(onRevokeAll: () => revoked = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Revoke all credentials'));
    await tester.tap(find.text('Revoke all credentials'));
    await tester.pumpAndSettle();

    expect(find.text('Revoke all credentials?'), findsOneWidget);
    expect(revoked, isFalse);

    await tester.tap(find.text('Revoke now'));
    await tester.pumpAndSettle();
    expect(revoked, isTrue);
  });

  testWidgets('raw token values are never rendered', (tester) async {
    await tester.pumpWidget(
      _app(
        CredentialsPage(
          data: _data(
            token: const V2Credential(
              id: 'token',
              kind: V2CredentialKind.token,
              title: 'Personal access token',
              subtitle: 'pat_live_abc123456789',
            ),
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('pat_live_abc123456789'), findsNothing);
    expect(find.text('••••••6789'), findsOneWidget);
  });

  testWidgets('cloud key manage fires its callback', (tester) async {
    var managed = false;
    await tester.pumpWidget(
      _app(
        CredentialsPage(data: _data(onManageCloudKey: () => managed = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Manage'));
    await tester.tap(find.text('Manage'));
    expect(managed, isTrue);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        CredentialsPage(
          data: V2CredentialsPageData(
            errorMessage: 'Credentials could not load.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Credentials could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('loading state shows a skeleton, not the content', (
    tester,
  ) async {
    await _pump(
      tester,
      data: const V2CredentialsPageData(loading: true),
      settle: false,
    );

    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('Cloud key active'), findsNothing);
    expect(find.text('Revoke all credentials'), findsNothing);
  });

  testWidgets('tapping a credential reports its id', (tester) async {
    String? tapped;
    await _pump(tester, data: _data(onCredentialTap: (id) => tapped = id));

    await tester.ensureVisible(find.text('GitHub'));
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(tapped, 'github');
  });

  testWidgets('a missing token still offers Add', (tester) async {
    var added = false;
    await _pump(
      tester,
      data: _data(token: null, onAddToken: () => added = true),
    );

    expect(find.text('Personal access token'), findsOneWidget);
    expect(find.text('Not added yet'), findsOneWidget);

    await tester.ensureVisible(find.text('Add'));
    await tester.tap(find.text('Add'));
    expect(added, isTrue);
  });

  testWidgets('narrow phone at 200% text does not overflow in light', (
    tester,
  ) async {
    await _pump(tester, width: 320, textScale: 2);

    expect(tester.takeException(), isNull);
    expect(find.text('Protected & Encrypted'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Active'), findsNWidgets(3));
    expect(find.text('Revoke all credentials'), findsOneWidget);
  });

  testWidgets('narrow phone at 200% text does not overflow in dark', (
    tester,
  ) async {
    await _pump(tester, width: 320, textScale: 2, dark: true);

    expect(tester.takeException(), isNull);
    expect(find.text('3 stored'), findsOneWidget);
  });

  testWidgets('stacked rows stay tappable at 320 dp and 200% text', (
    tester,
  ) async {
    String? tapped;
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      data: _data(onCredentialTap: (id) => tapped = id),
    );

    await tester.ensureVisible(find.text('GitHub'));
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(tapped, 'github');
  });

  testWidgets('long injected values stay inside the card at 320 dp', (
    tester,
  ) async {
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      data: _data(
        token: const V2Credential(
          id: 'token',
          kind: V2CredentialKind.token,
          title: 'Personal access token for the nightly build runner',
          subtitle: '••••••9x4q',
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing token at 320 dp and 200% text does not overflow', (
    tester,
  ) async {
    await _pump(tester, width: 320, textScale: 2, data: _data(token: null));

    expect(tester.takeException(), isNull);
    expect(find.text('Not added yet'), findsOneWidget);
  });

  testWidgets('revoke confirmation fits a narrow phone at 200% text', (
    tester,
  ) async {
    await _pump(tester, width: 320, textScale: 2);

    await tester.ensureVisible(find.text('Revoke all credentials'));
    await tester.tap(find.text('Revoke all credentials'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Revoke all credentials?'), findsOneWidget);
    expect(find.text('Revoke now'), findsOneWidget);
  });

  testWidgets('empty state fits a narrow phone at 200% text', (tester) async {
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      data: const V2CredentialsPageData(),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No credentials yet'), findsOneWidget);
  });

  testWidgets('error state fits a narrow phone at 200% text', (tester) async {
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      data: const V2CredentialsPageData(
        errorMessage: 'Credentials could not load.',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Credentials could not load.'), findsOneWidget);
  });

  testWidgets('reduced motion still shows every control', (tester) async {
    await _pump(tester, disableAnimations: true);

    expect(find.text('Protected & Encrypted'), findsOneWidget);
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    expect(find.text('Revoke all credentials'), findsOneWidget);
  });

  testWidgets('rows without a tap callback show no tap affordance', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('rows with a tap callback show the chevron', (tester) async {
    await _pump(tester, data: _data(onCredentialTap: (_) {}));

    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(2));
  });

  testWidgets('a Manage button without a callback is announced as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    expect(
      tester.getSemantics(find.text('Manage')),
      isSemantics(hasEnabledState: true, isEnabled: false),
    );

    handle.dispose();
  });
}
