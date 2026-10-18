// P8 Task 8 — AgentSurface conformance.
//
// The seam exists so chat_screen binds to `AgentSurface` while the
// implementation is swapped behind `Distribution.cloudExecution`. Task 19
// retired the local service, so `CloudAgentFacade` is now the only
// implementation and its conformance is the whole contract.
//
// The `final AgentSurface surface = …` assignment below is the real
// compile-time check; the expects are the runtime belt-and-suspenders the
// brief asks for.

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/agent_surface.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/distribution.dart';

void main() {
  test('CloudAgentFacade implements AgentSurface', () {
    final facade = CloudAgentFacade(
      rest: CloudRestClient(
        headers: CloudHeaders.forTest(),
        restBase: 'http://test',
      ),
      ws: WsMultiplexer(
        mintTicket: () async => 'ticket',
        socketFactory: (Uri url) async =>
            throw UnimplementedError('no socket in the conformance test'),
        heartbeatInterval: const Duration(hours: 1),
      ),
      store: null,
    );
    final AgentSurface surface = facade;
    expect(surface, isA<CloudAgentFacade>());

    // Round 1 (I-1): the alias-only members chat_screen calls are on the
    // surface too, and the facade's inert-by-design sections answer them.
    expect(facade.queuedMessages, isEmpty);
    expect(facade.queuedMessagesFor('s1'), isEmpty);
    expect(facade.queuedMessageIdsFor('s1'), isEmpty);
    expect(facade.sessionSystemTokens, 0);
    expect(facade.sessionToolTokens, 0);
    expect(facade.sessionMessageTokens, 0);
    expect(facade.sessionCacheReadTokens, 0);
    expect(facade.subagentsOf('s1'), isEmpty);
    expect(facade.browserBusy, isFalse);
    expect(facade.browserReady, isFalse);
    expect(facade.jobsFor('s1'), isEmpty);
    expect(facade.pendingApproval, isNull);
    expect(facade.pendingApprovalsElsewhere, isEmpty);
    facade.killJobFor('s1', 1); // P2 inert no-op

    facade.dispose();
  });

  group('Distribution thin-client flags', () {
    tearDown(() => Distribution.thinOverrideForTest = null);

    test('the test override wins over the compile-time define and play', () {
      Distribution.thinOverrideForTest = true;
      expect(Distribution.thinClient, isTrue);
      expect(Distribution.cloudExecution, isTrue);
      expect(Distribution.cloudStudio, isTrue);
      expect(Distribution.cloudSchedules, isTrue);
      expect(Distribution.cloudBrowser, isTrue);
      expect(Distribution.cloudPlugins, isFalse, reason: 'dark until P5');
      expect(Distribution.cloudByok, isTrue,
          reason: 'the P9 escrow endpoints are built');

      Distribution.thinOverrideForTest = false;
      expect(Distribution.thinClient, isFalse);
      expect(Distribution.cloudExecution, isFalse);
    });

    test('unset override falls back to the compile-time define', () {
      // This test binary is not built with --dart-define=OVID_THIN_CLIENT.
      Distribution.thinOverrideForTest = null;
      expect(Distribution.thinClient, isFalse);
    });
  });
}
