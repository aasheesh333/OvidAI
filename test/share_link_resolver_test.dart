import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:ovid_ai/core/share_link_resolver.dart';
import 'package:ovid_ai/main.dart' show openShareWithNavigator;
import 'package:ovid_ai/ui/shared_conversation_screen.dart';

void main() {
  final token = 'A' * 43;

  test('parses only the canonical HTTPS share URL and token', () {
    expect(
      ShareLinkResolver.parse(Uri.parse('https://ovidsi.com/s/$token')),
      ShareLink(token),
    );
  });

  test('rejects malformed, credential-bearing, and foreign share URLs', () {
    for (final uri in [
      Uri.parse('http://ovidsi.com/s/$token'),
      Uri.parse('https://ovidsi.com/s/short'),
      Uri.parse('https://evil.example/s/$token'),
      Uri.parse('https://ovidsi.com/s/$token?token=$token'),
      Uri.parse('https://user:pass@ovidsi.com/s/$token'),
      Uri.parse('https://ovidsi.com/s/$token/short'),
      Uri.parse('https://ovidsi.com/s/$token/$token/$token'),
      Uri.parse('https://ovidsi.com/s/$token#$token'),
    ]) {
      expect(ShareLinkResolver.parse(uri), isNull);
    }
  });

  test('routes installed links to the viewer without exposing the token', () {
    final route = ShareLinkResolver.route(Uri.parse('https://ovidsi.com/s/$token'));
    expect(route, isA<ShareViewerRoute>());
    expect((route! as ShareViewerRoute).token, token);
    expect(route.toString(), isNot(contains(token)));
  });

  test('parses Collab links into a join route', () {
    final invite = 'b' * 43;
    final uri = Uri.parse('https://ovidsi.com/s/$token/$invite');
    expect(ShareLinkResolver.parse(uri), ShareLink(token, invite: invite));
    final route = ShareLinkResolver.route(uri);
    expect(route, isA<CollabJoinRoute>());
    expect((route! as CollabJoinRoute).invite, invite);
    expect(route.toString(), isNot(contains(invite)));
    expect(ShareLinkResolver.uriFor(ShareLink(token, invite: invite)), uri);
  });

  test('Collab install referrer survives install and restores the join link', () async {
    final invite = 'c' * 43;
    final play = ShareLinkResolver.playStoreUri(ShareLink(token, invite: invite));
    expect(play.queryParameters['referrer'], 'share_token=$token&invite=$invite');
    final resolver = ShareLinkResolver(store: MemoryDeferredShareStore());
    await resolver.saveInstallReferrer(play.queryParameters['referrer']);
    expect(await resolver.restoreDeferred(), ShareLink(token, invite: invite));
    await resolver.saveInstallReferrer('share_token=$token&invite=bad');
    expect(await resolver.restoreDeferred(), isNull);
  });

  test('restores a deferred token once and clears it from storage', () async {
    final store = MemoryDeferredShareStore();
    final resolver = ShareLinkResolver(store: store);
    await resolver.saveDeferred(ShareLink(token));

    expect(await resolver.restoreDeferred(), ShareLink(token));
    expect(await resolver.restoreDeferred(), isNull);
    expect(store.lastStoredValue, isNull);
  });

  test('creates a Play Store install-referrer URL from a valid token', () {
    final uri = ShareLinkResolver.playStoreUri(ShareLink(token));
    expect(uri.host, 'play.google.com');
    expect(uri.queryParameters['id'], 'com.dhanuk.ovidai');
    expect(uri.queryParameters['referrer'], 'share_token=$token');
  });

  test('extracts and validates a one-shot Play Install Referrer payload', () async {
    final store = MemoryDeferredShareStore();
    final resolver = ShareLinkResolver(store: store);
    await resolver.saveInstallReferrer('utm_source=play&share_token=$token');

    expect(await resolver.restoreDeferred(), ShareLink(token));
    expect(await resolver.restoreDeferred(), isNull);
  });

  testWidgets('share navigation uses the application navigator', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Text('home')),
    ));

    openShareWithNavigator(navigatorKey, Uri.parse('https://ovidsi.com/s/$token'));
    await tester.pumpAndSettle();

    expect(find.byType(SharedConversationScreen), findsOneWidget);
  });
}
