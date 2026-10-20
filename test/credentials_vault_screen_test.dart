import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/cloud/credentials.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/credentials_vault_screen.dart';

/// Wave 6 W4 — the vault UI never holds or shows a secret beyond the editor's
/// one-way input, and every mutation goes through the API seam.
class _FakeCredentialsApi implements CredentialsApi {
  _FakeCredentialsApi([List<BrowserCredential>? seed])
      : items = List<BrowserCredential>.from(seed ?? const []);

  final List<BrowserCredential> items;
  final List<Map<String, Object?>> creates = <Map<String, Object?>>[];
  final List<Map<String, Object?>> updates = <Map<String, Object?>>[];
  final List<String> removals = <String>[];

  @override
  Future<List<BrowserCredential>> list() async =>
      List<BrowserCredential>.unmodifiable(items);

  @override
  Future<BrowserCredential> create({
    required String label,
    required String site,
    required String username,
    required String secret,
    required String secretKind,
    String? notes,
  }) async {
    creates.add(<String, Object?>{
      'label': label,
      'site': site,
      'username': username,
      'secret': secret,
      'secretKind': secretKind,
      'notes': notes,
    });
    final entry = BrowserCredential(
      id: 'c${items.length + 1}',
      label: label,
      site: site,
      username: username,
      secretKind: secretKind,
      hasNotes: notes != null && notes.isNotEmpty,
    );
    items.add(entry);
    return entry;
  }

  @override
  Future<BrowserCredential> update(
    String id, {
    String? label,
    String? site,
    String? username,
    String? secret,
    String? secretKind,
    String? notes,
    bool clearNotes = false,
  }) async {
    updates.add(<String, Object?>{
      'id': id,
      'label': label,
      'site': site,
      'username': username,
      'secret': secret,
      'secretKind': secretKind,
      'notes': notes,
      'clearNotes': clearNotes,
    });
    return items.firstWhere((e) => e.id == id);
  }

  @override
  Future<void> remove(String id) async {
    removals.add(id);
    items.removeWhere((e) => e.id == id);
  }
}

const BrowserCredential _github = BrowserCredential(
  id: 'c-github',
  label: 'GitHub',
  site: 'github.com',
  username: 'octocat',
  secretKind: 'token',
  hasNotes: true,
);

Future<void> _pump(WidgetTester tester, CredentialsApi api) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      home: CredentialsVaultScreen(api: api),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('empty vault: honest empty state + add affordance', (tester) async {
    await _pump(tester, _FakeCredentialsApi());
    expect(find.byKey(const ValueKey('credentials-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('credentials-add')), findsOneWidget);
  });

  testWidgets('list shows metadata only, never a secret', (tester) async {
    await _pump(tester, _FakeCredentialsApi([_github]));
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.textContaining('github.com'), findsOneWidget);
    expect(find.textContaining('octocat'), findsOneWidget);
    // There is no secret field/value in the list surface.
    expect(find.byKey(const ValueKey('credential-secret')), findsNothing);
  });

  testWidgets('add sends the secret to the API and refreshes the list', (tester) async {
    final api = _FakeCredentialsApi();
    await _pump(tester, api);

    await tester.tap(find.byKey(const ValueKey('credentials-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('credential-label')), 'Example');
    await tester.enterText(find.byKey(const ValueKey('credential-site')), 'example.com');
    await tester.enterText(find.byKey(const ValueKey('credential-username')), 'me');
    await tester.enterText(find.byKey(const ValueKey('credential-secret')), 's3cret');
    await tester.tap(find.byKey(const ValueKey('credential-save')));
    await tester.pumpAndSettle();

    expect(api.creates, hasLength(1));
    expect(api.creates.single['secret'], 's3cret');
    expect(api.creates.single['secretKind'], 'password');
    expect(find.text('Example'), findsOneWidget);
  });

  testWidgets('editing with a blank secret keeps the stored one (null on the wire)',
      (tester) async {
    final api = _FakeCredentialsApi([_github]);
    await _pump(tester, api);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('credential-label')), 'GitHub work');
    await tester.tap(find.byKey(const ValueKey('credential-save')));
    await tester.pumpAndSettle();

    expect(api.updates, hasLength(1));
    expect(api.updates.single['secret'], isNull,
        reason: 'an untouched secret field must never overwrite the vault entry');
    expect(api.updates.single['label'], 'GitHub work');
  });

  testWidgets('delete is confirmed and owner-scoped by id', (tester) async {
    final api = _FakeCredentialsApi([_github]);
    await _pump(tester, api);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('credentials-delete-confirm')));
    await tester.pumpAndSettle();

    expect(api.removals, <String>['c-github']);
    expect(find.byKey(const ValueKey('credentials-empty')), findsOneWidget);
  });
}
