import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:ovid_ai/core/native_plugins/web_and_db_utilities.dart';

class _StalledBodyClient extends http.BaseClient {
  _StalledBodyClient(this.body);
  final Stream<List<int>> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200);
}

void main() {
  for (final clip in [false, true]) {
    final label = clip ? 'Web Clipper' : 'API Tester';
    test('$label aborts a stalled HTTP call promptly on cancel', () async {
      var bodyCancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => bodyCancelled = true,
      );
      addTearDown(body.close);
      final client = _StalledBodyClient(body.stream);
      final capability = clip
          ? WebClipperCapability(client: client)
          : ApiTesterCapability(client: client);
      final token = UtilityCancellation();
      final pending = capability.callTool(clip ? 'clip' : 'request', {
        'url': 'https://example.test',
        'timeout_seconds': 10,
      }, cancellation: token);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('cancel'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final clock = Stopwatch()..start();
      token.cancel();
      await assertion;
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(bodyCancelled, isTrue);
    });
  }
}
