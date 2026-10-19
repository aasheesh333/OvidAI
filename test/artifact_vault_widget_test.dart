import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/artifact_vault.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/artifacts_screen.dart';
import 'artifact_vault_test.dart' show item;

void main() {
  testWidgets('signed-in inventory has loading, failed retry, empty and correct tab states, never a local corpus fallback', (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final requests = <http.Request>[];
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      requests.add(r);
      calls++;
      if (calls == 1) return pending.future;
      if (calls == 2) return http.Response('{"items":[],"nextCursor":null}', 200);
      return http.Response(jsonEncode({'items': [item('upload', name: 'brief.pdf', source: 'uploaded')], 'nextCursor': null}), 200);
    }));
    final controller = ArtifactVaultController(client: ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: ArtifactsScreen(controller: controller)));
    expect(find.byKey(const ValueKey('vault-loading')), findsOneWidget);
    expect(find.text('No artifacts yet'), findsNothing);
    pending.complete(http.Response('{"error":{"code":"internal","message":"down"}}', 503));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vault-error')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vault-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vault-empty')), findsOneWidget);
    await tester.tap(find.text('Uploaded by User'));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['source'], 'uploaded');
    expect(find.text('brief.pdf'), findsOneWidget);
    expect(requests.where((r) => r.url.path.endsWith('/url')), isEmpty);
  });
  testWidgets('narrow large-text Vault keeps tabs, search, type and load-more usable without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 750);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <http.Request>[];
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      requests.add(r);
      final more = r.url.queryParameters.containsKey('cursor');
      return http.Response(jsonEncode({'items': [item(more ? 'two' : 'one', name: more ? 'older.txt' : 'an_extremely_long_generated_document_name.pdf')], 'nextCursor': more ? null : 'next'}), 200);
    }));
    final controller = ArtifactVaultController(client: ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)), child: child!), home: ArtifactsScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('vault-load-more')));
    await tester.tap(find.byKey(const ValueKey('vault-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('older.txt'), findsOneWidget);
    expect(requests.last.url.queryParameters['cursor'], 'next');
    expect(tester.takeException(), isNull);
  });
}
