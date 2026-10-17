// P8 Task 8 — AgentSurface conformance.
//
// The seam exists so Task 10 can bind chat_screen to `AgentSurface` and swap
// AgentService ↔ CloudAgentFacade behind `Distribution.cloudExecution`. That
// only works if BOTH implementations satisfy the interface, and if the
// interface's signatures are the ones AgentService actually has (the plan's
// Step 4 ruling: the surface conforms to AgentService, never vice versa).
//
// The `final AgentSurface surface = …` assignments below are the real
// compile-time check; the expects are the runtime belt-and-suspenders the
// brief asks for.

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/cloud/agent_surface.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/distribution.dart';

void main() {
  test('AgentService implements AgentSurface', () {
    final AgentSurface surface = AgentService.I;
    expect(surface, same(AgentService.I));
  });

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
      expect(Distribution.cloudByok, isFalse,
          reason: 'dark until the P9 escrow endpoints');

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
