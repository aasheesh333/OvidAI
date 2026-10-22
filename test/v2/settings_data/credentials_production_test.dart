import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/credentials_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Production gates for the Credentials screen:
///  * secrets are masked, never revealed, copied or logged;
///  * a key is written to the secure store only, never SharedPreferences;
///  * removal and revoke-all confirm, name the target and reach real state;
///  * loading / empty / error / content / saving / removing all render;
///  * 320 → 1280 dp at 100 % and 200 % text, light and dark, 640 dp cap,
///    rows at least 56 dp;
///  * each row announces its name and mask, and destructive actions say so.

class _MemoryStore implements V2CredentialKeyStore {
  _MemoryStore([Map<String, String>? seed])
    : values = <String, String>{...?seed};

  final Map<String, String> values;
  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];
  bool failWrite = false;
  bool failDelete = false;

  @override
  Future<String?> read(String id) async => values[id];

  @override
  Future<void> write(String id, String value) async {
    if (failWrite) throw StateError('secure storage unavailable');
    writes.add(id);
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    if (failDelete) throw StateError('secure storage unavailable');
    deletes.add(id);
    values.remove(id);
  }
}

/// A write that stays in flight until the test releases it.
class _SlowWriteStore extends _MemoryStore {
  final Completer<void> _gate = Completer<void>();

  void completeWrite() => _gate.complete();

  @override
  Future<void> write(String id, String value) async {
    await _gate.future;
    await super.write(id, value);
  }
}

/// A delete that stays in flight until the test releases it.
class _SlowDeleteStore extends _MemoryStore {
  _SlowDeleteStore(super.seed);

  final Completer<void> _gate = Completer<void>();

  void completeDelete() => _gate.complete();

  @override
  Future<void> delete(String id) async {
    await _gate.future;
    await super.delete(id);
  }
}

/// Fails the first two reads (one page load), then recovers so Retry works.
class _FlakyReadStore extends _MemoryStore {
  int reads = 0;

  @override
  Future<String?> read(String id) async {
    reads++;
    if (reads <= 2) throw StateError('keystore unavailable');
    return super.read(id);
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
  subtitle: '@aarav',
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
  V2Credential? token = _token,
  List<V2BrowserCredential> browser = const <V2BrowserCredential>[],
  bool githubPatAdded = false,
  VoidCallback? onRevokeAll,
  ValueChanged<V2BrowserCredential>? onAddBrowserCredential,
  ValueChanged<V2BrowserCredential>? onEditBrowserCredential,
  ValueChanged<V2BrowserCredential>? onDeleteBrowserCredential,
  ValueChanged<String>? onCredentialTap,
  VoidCallback? onManageCloudKey,
}) {
  return V2CredentialsPageData(
    google: _google,
    github: _github,
    token: token,
    browserCredentials: browser,
    githubPatAdded: githubPatAdded,
    onRevokeAll: onRevokeAll,
    onAddBrowserCredential: onAddBrowserCredential,
    onEditBrowserCredential: onEditBrowserCredential,
    onDeleteBrowserCredential: onDeleteBrowserCredential,
    onCredentialTap: onCredentialTap,
    onManageCloudKey: onManageCloudKey,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  V2CredentialsPageData? data,
  V2CredentialKeyStore? store,
  bool dark = false,
  double width = 400,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: CredentialsPage(data: data ?? _data(), keyStore: store ?? _MemoryStore()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAddKey(WidgetTester tester) async {
  final add = find.byKey(const ValueKey<String>('provider-key-add'));
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pumpAndSettle();
}

Future<void> _enterKey(WidgetTester tester, String secret) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('provider-key-field')),
    secret,
  );
  await tester.pump();
}

Future<void> _saveKey(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('provider-key-save')));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('secrets are masked and one-way', () {
    testWidgets('a stored key renders as last-4 only', (tester) async {
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
      });
      await _pump(tester, data: _data(token: null), store: store);

      expect(find.text('••••••6789'), findsOneWidget);
      expect(find.textContaining('sk-live'), findsNothing);
      expect(find.textContaining('123456789'), findsNothing);
    });

    testWidgets('there is no reveal control on the screen or in the sheet', (
      tester,
    ) async {
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
      });
      await _pump(tester, data: _data(token: null), store: store);

      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
      expect(find.bySemanticsLabel('Show key'), findsNothing);
      expect(find.bySemanticsLabel('Show provider key'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('provider-key-replace')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('provider-key-field')),
      );
      expect(field.obscureText, isTrue);
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('a browser password renders no characters at all', (
      tester,
    ) async {
      await _pump(
        tester,
        data: _data(
          browser: const <V2BrowserCredential>[_browser],
          onEditBrowserCredential: (_) {},
        ),
      );

      expect(find.text('aarav@example.com · ••••••••'), findsOneWidget);
      expect(find.textContaining('hunter2'), findsNothing);

      await tester.tap(find.text('example.com'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('browser-password-field')),
      );
      expect(field.obscureText, isTrue);
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('there is no copy affordance anywhere', (tester) async {
      await _pump(
        tester,
        data: _data(browser: const <V2BrowserCredential>[_browser]),
      );

      expect(find.byType(SelectableText), findsNothing);
      expect(find.byIcon(Icons.copy_rounded), findsNothing);
      expect(find.byIcon(Icons.copy), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Copy')), findsNothing);
    });

    test('the source never logs, prints, reveals or copies a secret', () {
      final source = File(
        'lib/ui/v2/settings/credentials_page.dart',
      ).readAsStringSync();

      expect(source, isNot(contains('Clipboard')));
      expect(source, isNot(contains('debugPrint')));
      expect(source, isNot(contains('print(')));
      expect(source, isNot(contains('obscureText: false')));
      expect(source, isNot(contains('visibility_outlined')));
      expect(source, isNot(contains('visibility_off_outlined')));
    });
  });

  group('adding and removing one credential', () {
    testWidgets('a key goes to the secure store, never prefs, and the field '
        'is cleared', (tester) async {
      const secret = 'sk-live-987654321';
      final store = _MemoryStore();
      await _pump(tester, data: _data(token: null), store: store);

      await _openAddKey(tester);
      await _enterKey(tester, secret);
      await _saveKey(tester);
      await tester.pumpAndSettle();

      expect(store.values['personal'], secret);
      expect(store.writes, <String>['personal']);

      final prefs = await SharedPreferences.getInstance();
      final blob = <String, Object?>{
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };
      expect(blob, isEmpty, reason: 'a credential must never reach prefs');
      expect(blob.toString(), isNot(contains(secret)));

      // No plaintext survives the save in the page or in a fresh sheet.
      expect(find.textContaining(secret), findsNothing);
      expect(find.text('••••••4321'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('provider-key-replace')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('provider-key-field')),
            )
            .controller!
            .text,
        isEmpty,
      );
    });

    testWidgets('removing names the key, deletes it and reports success', (
      tester,
    ) async {
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
      });
      await _pump(tester, data: _data(token: null), store: store);

      await tester.tap(
        find.byKey(const ValueKey<String>('provider-key-remove')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Remove provider key?'), findsOneWidget);
      expect(
        find.text('••••••6789 is deleted from this device.'),
        findsOneWidget,
      );
      expect(store.deletes, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey<String>('credential-confirm-remove')),
      );
      await tester.pumpAndSettle();

      expect(store.deletes, <String>['personal']);
      expect(store.values.containsKey('personal'), isFalse);
      expect(find.text('Not added yet'), findsOneWidget);
      expect(find.text('Provider key removed.'), findsOneWidget);
    });

    testWidgets('a refused delete keeps the key and reports failure', (
      tester,
    ) async {
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
      })..failDelete = true;
      await _pump(tester, data: _data(token: null), store: store);

      await tester.tap(
        find.byKey(const ValueKey<String>('provider-key-remove')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('credential-confirm-remove')),
      );
      await tester.pumpAndSettle();

      expect(store.values['personal'], 'sk-live-123456789');
      expect(find.text('••••••6789'), findsOneWidget);
      expect(find.text('Could not remove the key. Try again.'), findsOneWidget);
    });
  });

  group('revoke all', () {
    testWidgets('confirms, then clears both secrets and every browser login', (
      tester,
    ) async {
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
        'github': 'ghp_1234567890',
      });
      final deleted = <String>[];
      var revoked = false;
      await _pump(
        tester,
        data: _data(
          token: null,
          browser: const <V2BrowserCredential>[_browser],
          onDeleteBrowserCredential: (credential) => deleted.add(credential.id),
          onRevokeAll: () => revoked = true,
        ),
        store: store,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('credential-revoke-all')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Revoke all credentials?'), findsOneWidget);
      expect(revoked, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('credential-confirm-revoke')),
      );
      await tester.pumpAndSettle();

      expect(store.values, isEmpty);
      expect(store.deletes, containsAll(<String>['personal', 'github']));
      expect(deleted, <String>['b1']);
      expect(revoked, isTrue);
      expect(find.text('All credentials revoked.'), findsOneWidget);
      expect(find.text('Not added yet'), findsOneWidget);
      expect(find.text('Not added'), findsOneWidget);
    });

    testWidgets('cancelling keeps every credential', (tester) async {
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
      });
      await _pump(tester, data: _data(token: null), store: store);

      await tester.tap(
        find.byKey(const ValueKey<String>('credential-revoke-all')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep active'));
      await tester.pumpAndSettle();

      expect(store.values['personal'], 'sk-live-123456789');
      expect(find.text('••••••6789'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: CredentialsPage(
            data: const V2CredentialsPageData(loading: true),
            keyStore: _MemoryStore(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(OSkeletonList), findsOneWidget);
      expect(find.text('Revoke all credentials'), findsNothing);
    });

    testWidgets('empty is one line plus one add action', (tester) async {
      await _pump(tester, data: const V2CredentialsPageData());

      expect(find.text('No credentials yet'), findsOneWidget);
      expect(find.text('Connect an account or add a key.'), findsOneWidget);
      final add = find.byKey(const ValueKey<String>('credential-empty-add'));
      expect(add, findsOneWidget);

      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('Add provider key'), findsOneWidget);
    });

    testWidgets('a host error offers Retry', (tester) async {
      var retried = false;
      await _pump(
        tester,
        data: V2CredentialsPageData(
          errorMessage: 'Credentials could not load.',
          onRetry: () => retried = true,
        ),
      );

      expect(find.text('Credentials could not load.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retried, isTrue);
    });

    testWidgets('an unreadable keystore is a retryable error', (tester) async {
      final store = _FlakyReadStore();
      await _pump(tester, data: const V2CredentialsPageData(), store: store);

      expect(find.text('Could not read saved keys.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('No credentials yet'), findsOneWidget);
    });

    testWidgets('saving shows the form and row busy, then the mask', (
      tester,
    ) async {
      const secret = 'sk-live-55556666';
      final store = _SlowWriteStore();
      await _pump(tester, data: _data(token: null), store: store);

      await _openAddKey(tester);
      await _enterKey(tester, secret);
      await _saveKey(tester);
      await tester.pump();

      expect(
        tester
            .widget<OButton>(
              find.byKey(const ValueKey<String>('provider-key-save')),
            )
            .loading,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey<String>('credential-busy-personal')),
        findsOneWidget,
      );

      store.completeWrite();
      await tester.pumpAndSettle();

      expect(store.values['personal'], secret);
      expect(find.text('••••••6666'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('provider-key-field')),
        findsNothing,
      );
    });

    testWidgets('removing shows the row busy, then the empty value', (
      tester,
    ) async {
      final store = _SlowDeleteStore(<String, String>{
        'personal': 'sk-live-123456789',
      });
      await _pump(tester, data: _data(token: null), store: store);

      await tester.tap(
        find.byKey(const ValueKey<String>('provider-key-remove')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('credential-confirm-remove')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey<String>('credential-busy-personal')),
        findsOneWidget,
      );

      store.completeDelete();
      await tester.pumpAndSettle();

      expect(store.values.containsKey('personal'), isFalse);
      expect(find.text('Not added yet'), findsOneWidget);
      expect(find.text('Provider key removed.'), findsOneWidget);
    });
  });

  group('responsive and themed', () {
    const rowKeys = <String>[
      'credential-row-google',
      'credential-row-github',
      'credential-row-github-token',
      'credential-row-provider-key',
      'credential-row-cloud-key',
      'credential-row-browser-b1',
    ];

    for (final width in <double>[320, 360, 412, 600, 800, 1024, 1280]) {
      for (final scale in <double>[1, 2]) {
        for (final dark in <bool>[false, true]) {
          testWidgets(
            'fits ${width.toInt()} dp at ${(scale * 100).toInt()}% text '
            '(${dark ? 'dark' : 'light'})',
            (tester) async {
              await _pump(
                tester,
                width: width,
                textScale: scale,
                dark: dark,
                data: _data(
                  browser: const <V2BrowserCredential>[_browser],
                  onEditBrowserCredential: (_) {},
                  onDeleteBrowserCredential: (_) {},
                  onManageCloudKey: () {},
                ),
              );

              expect(tester.takeException(), isNull);
              final scroll = tester.getRect(
                find.byKey(const ValueKey<String>('credentials-scroll')),
              );
              expect(scroll.width, lessThanOrEqualTo(640));
              if (width > 640) {
                expect(scroll.center.dx, closeTo(width / 2, 0.5));
              }
              for (final key in rowKeys) {
                final row = tester.getSize(find.byKey(ValueKey<String>(key)));
                expect(
                  row.height,
                  greaterThanOrEqualTo(56),
                  reason: '$key is shorter than the 56 dp row floor',
                );
              }
            },
          );
        }
      }
    }
  });

  group('semantics', () {
    testWidgets('rows announce name plus mask, never the secret', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
        'github': 'ghp_1234567890',
      });
      await _pump(
        tester,
        data: _data(
          githubPatAdded: true,
          browser: const <V2BrowserCredential>[_browser],
          onDeleteBrowserCredential: (_) {},
        ),
        store: store,
      );

      expect(
        find.bySemanticsLabel('Provider key, ••••••6789'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('GitHub token, ••••••7890'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('example.com, aarav@example.com · ••••••••'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('sk-live-123456789')),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel(RegExp('ghp_1234567890')),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('every destructive control announces destructive', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final store = _MemoryStore(<String, String>{
        'personal': 'sk-live-123456789',
      });
      await _pump(tester, data: _data(token: null), store: store);

      expect(
        find.bySemanticsLabel('Remove provider key, destructive'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Revoke all credentials, destructive'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('provider-key-remove')),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Remove key, destructive'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
