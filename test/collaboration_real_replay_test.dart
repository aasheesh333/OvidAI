import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/client.dart';
import 'package:ovid_ai/core/collaboration/coordinator.dart';
import 'package:ovid_ai/core/collaboration/store.dart';
import 'collaboration_coordinator_test.dart' show FakeScheduler;

void main() {
  test('cold API to reducer replay preserves churn history and rejoined local member', () async {
    // CI and local development use different Python locations.  Keep this
    // fixture generation independent of the controller's private virtualenv.
    final python = Platform.environment['OVID_PYTHON'] ??
        Platform.environment['PYTHON'] ?? 'python3';
    final result = await Process.run(python,
      ['-m', 'server.collaboration.tests.export_churn']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final fixture = jsonDecode(result.stdout as String) as Map;
    final client = CollaborationClient(baseUri: Uri.parse('https://test.invalid'),
      accessToken: () async => 'token', appCheckToken: () async => 'check',
      httpClient: MockClient((r) async => http.Response(jsonEncode(
        fixture[r.url.path.endsWith('/events') ? 'page' : 'state']), 200,
        headers: {'cache-control': 'no-store'})));
    final store = CollaborationStore(MemoryCollaborationStoreBackend(), ownerFence: 'account');
    final coordinator = CollaborationCoordinator(client: client, store: store,
      accountId: 'account', sessionToken: 'token', scheduler: FakeScheduler());
    addTearDown(coordinator.dispose);
    coordinator.start();
    for (var i = 0; i < 100 && store.cursor < 45; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.state!.messages.map((e) => e.text), List.generate(12, (i) => 'history-$i'));
    expect(store.state!.capacityViolations, 0);
    expect(store.state!.activeMembers.length, 10);
    expect(store.cursor, 45);
  });
}
