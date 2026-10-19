import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/artifact_vault.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/ui/artifact_preview.dart';
import 'artifact_vault_test.dart' show item;

void main() {
  testWidgets('canonical cloud preview never uses stale URL and shows missing-object error with retry', (tester) async {
    var calls = 0;
    final client = ArtifactVaultClient(accountId: () => 'firebase:a', rest: CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      calls++;
      return http.Response('{"error":{"code":"artifact_unavailable","message":"Object absent"}}', 404);
    })));
    final a = VaultArtifact.fromJson(item('canonical')).toSessionArtifact('firebase:a');
    await tester.pumpWidget(MaterialApp(home: ArtifactPreviewScreen(artifact: a, vaultClient: client)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('artifact-cloud-error')), findsOneWidget);
    expect(find.text("This file isn't on this device anymore."), findsNothing);
    expect(find.byKey(const ValueKey('artifact-cloud-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('artifact-cloud-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets('canonical thumbnails are metadata glyphs and never mint on list mount', (tester) async {
    final a = VaultArtifact.fromJson({...item('image'), 'category': 'image', 'name': 'shot.png'}).toSessionArtifact('firebase:a');
    final requests = <http.Request>[];
    CloudRestClient.installForTest(CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      requests.add(r);
      return http.Response('{}', 500);
    })));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ArtifactThumb(artifact: a))));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.byType(Image), findsNothing);
  });
  testWidgets('account change clears a canonical preview immediately and prevents sharing old capability', (tester) async {
    final owner = ValueNotifier<String?>('firebase:a');
    addTearDown(owner.dispose);
    final client = ArtifactVaultClient(accountId: () => owner.value, rest: CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async => http.Response(jsonEncode({'url': 'https://r2.test/fresh', 'expiresAt': '2026-10-19T12:00:00Z'}), 200))));
    final a = VaultArtifact.fromJson(item('canonical')).toSessionArtifact('firebase:a');
    await tester.pumpWidget(MaterialApp(home: ArtifactPreviewScreen(artifact: a, vaultClient: client, accountChanges: owner)));
    await tester.pumpAndSettle();
    owner.value = 'firebase:b';
    await tester.pumpAndSettle();
    expect(find.text('report.txt'), findsNothing);
    expect(find.byTooltip('Share'), findsNothing);
    expect(find.byKey(const ValueKey('artifact-cloud-error')), findsOneWidget);
  });
  testWidgets('canonical share mints again on action rather than reusing preview URL', (tester) async {
    var mints = 0;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ovid/native'), (call) async { calls.add(call); return true; });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ovid/native'), null));
    final client = ArtifactVaultClient(accountId: () => 'firebase:a', rest: CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async => http.Response(jsonEncode({'url': 'https://r2.test/fresh-${++mints}', 'expiresAt': '2026-10-19T12:00:00Z'}), 200))));
    final a = VaultArtifact.fromJson(item('canonical')).toSessionArtifact('firebase:a');
    await tester.pumpWidget(MaterialApp(home: ArtifactPreviewScreen(artifact: a, vaultClient: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    expect(mints, 2);
    expect((calls.single.arguments as Map)['text'], 'https://r2.test/fresh-2');
  });
}
