import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/artifact_vault.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';

Map<String, Object?> item(String id, {String source = 'generated', String name = 'report.txt'}) => {
  'id': id, 'sessionId': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
  'sessionTitle': 'Research', 'name': name, 'origin': source,
  'category': 'document', 'sizeBytes': 4, 'contentType': 'text/plain',
  'createdAt': '2026-10-19T10:00:00.000Z', 'availability': 'unverified',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('inventory uses bounded filters and canonical identity without minting list thumbnails', () async {
    final requests = <http.Request>[];
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      requests.add(r);
      return http.Response(jsonEncode({'items': [item('authoritative-id')], 'nextCursor': 'opaque-cursor'}), 200);
    }));
    final vault = ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a');
    final page = await vault.list(source: 'uploaded', category: 'document', search: 'Report_100%', sessionId: 'server-id', cursor: 'old-cursor');
    expect(requests.single.url.path, '/artifacts');
    expect(requests.single.url.queryParameters, {
      'source': 'uploaded', 'type': 'document', 'q': 'Report_100%',
      'sessionId': 'server-id', 'cursor': 'old-cursor', 'limit': '30',
    });
    final artifact = page.items.single.toSessionArtifact('firebase:a');
    expect(artifact.id, 'authoritative-id');
    expect(artifact.cloudArtifactId, 'authoritative-id');
    expect(artifact.cloudAccountId, 'firebase:a');
    expect(artifact.url, isNull);
    expect(page.nextCursor, 'opaque-cursor');
  });
  test('controller exposes loading, preserves paging failure and retries without duplicate rows', () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      calls++;
      if (calls == 1) return pending.future;
      if (calls == 2) return http.Response('{"error":{"code":"internal","message":"failed"}}', 503);
      return http.Response(jsonEncode({'items': [item('one'), item('two')], 'nextCursor': null}), 200);
    }));
    final controller = ArtifactVaultController(client: ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a'));
    addTearDown(controller.dispose);
    final first = controller.reload();
    expect(controller.loading, isTrue);
    expect(controller.items, isEmpty);
    pending.complete(http.Response(jsonEncode({'items': [item('one')], 'nextCursor': 'next'}), 200));
    await first;
    expect(controller.items.map((i) => i.id), ['one']);
    await controller.loadMore();
    expect(controller.items.map((i) => i.id), ['one']);
    expect(controller.pageError, isNotNull);
    expect(controller.nextCursor, 'next');
    await controller.loadMore();
    expect(controller.items.map((i) => i.id), ['one', 'two']);
    expect(controller.pageError, isNull);
    expect(controller.nextCursor, isNull);
  });
  test('changing tab invalidates an in-flight page and removes old results immediately', () async {
    final generated = Completer<http.Response>();
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      if (r.url.queryParameters['source'] == 'generated') return generated.future;
      return http.Response(jsonEncode({'items': [item('upload', source: 'uploaded')], 'nextCursor': null}), 200);
    }));
    final controller = ArtifactVaultController(client: ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a'));
    addTearDown(controller.dispose);
    final old = controller.reload();
    await controller.setFilters(source: 'uploaded');
    expect(controller.items.map((i) => i.id), ['upload']);
    generated.complete(http.Response(jsonEncode({'items': [item('wrong-tab')], 'nextCursor': 'wrong'}), 200));
    await old;
    expect(controller.source, 'uploaded');
    expect(controller.items.map((i) => i.id), ['upload']);
    expect(controller.nextCursor, isNull);
  });
  test('account changes clear private rows and fence old responses; guest sends no request', () async {
    final owner = ValueNotifier<String?>('firebase:a');
    addTearDown(owner.dispose);
    final pending = Completer<http.Response>();
    var calls = 0;
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      calls++;
      if (calls == 1) return pending.future;
      return http.Response(jsonEncode({'items': [item('b-file')], 'nextCursor': null}), 200);
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => owner.value);
    final controller = ArtifactVaultController(client: client, accountChanges: owner);
    addTearDown(controller.dispose);
    final old = controller.reload();
    owner.value = 'firebase:b';
    await Future<void>.delayed(Duration.zero);
    expect(controller.items.map((i) => i.id), ['b-file']);
    pending.complete(http.Response(jsonEncode({'items': [item('a-secret')], 'nextCursor': null}), 200));
    await old;
    expect(controller.items.map((i) => i.id), ['b-file']);
    owner.value = null;
    expect(controller.items, isEmpty);
    await controller.reload();
    expect(calls, 2);
    expect(controller.accountId, isNull);
  });
  test('fresh mint propagates missing objects without stale fallback and rejects old owner before dispatch', () async {
    var owner = 'firebase:a';
    final requests = <http.Request>[];
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      requests.add(r);
      return http.Response('{"error":{"code":"artifact_unavailable","message":"No object"}}', 404);
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => owner);
    final artifact = VaultArtifact.fromJson(item('canonical')).toSessionArtifact(owner);
    await expectLater(client.mintUrl(artifact), throwsA(isA<CloudApiException>().having((e) => e.code, 'code', 'artifact_unavailable')));
    expect(requests.single.url.path, '/artifacts/canonical/url');
    expect(requests.single.url.queryParameters['source'], 'generated');
    owner = 'firebase:b';
    await expectLater(client.mintUrl(artifact), throwsA(isA<CloudApiException>().having((e) => e.code, 'code', 'account_changed')));
    expect(requests.length, 1);
  });
  test('offline state keeps same-owner metadata but sends no request and retries after reconnect', () async {
    final connected = ValueNotifier<bool>(false);
    addTearDown(connected.dispose);
    var calls = 0;
    final rest = CloudRestClient(restBase: 'https://cloud.test', headers: CloudHeaders.forTest(), httpClient: MockClient((r) async {
      calls++;
      return http.Response(jsonEncode({'items': [item('online')], 'nextCursor': null}), 200);
    }));
    final controller = ArtifactVaultController(client: ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a'), online: connected);
    addTearDown(controller.dispose);
    await controller.reload();
    expect(controller.offline, isTrue);
    expect(calls, 0);
    connected.value = true;
    await Future<void>.delayed(Duration.zero);
    expect(controller.items.single.id, 'online');
    expect(calls, 1);
  });
}
