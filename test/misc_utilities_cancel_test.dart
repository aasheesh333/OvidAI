import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugins/misc_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

/// Returns a 200 response whose body stream never completes, so the bounded
/// request is still in flight when the cancellation token fires.
class _StallingBodyClient extends http.BaseClient {
  _StallingBodyClient(this.body);

  final Stream<List<int>> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200);
}

Future<String> _networkCall(
  String family,
  http.Client client,
  UtilityCancellation cancellation,
) {
  switch (family) {
    case 'mermaid':
      return MermaidDiagramsCapability(client: client).callTool(
        'render',
        {'text': 'graph TD;A-->B'},
        cancellation: cancellation,
      );
    case 'icon':
      return IconLibraryCapability(client: client).callTool(
        'search',
        {'query': 'home'},
        cancellation: cancellation,
      );
    case 'font':
      return FontPreviewCapability(client: client).callTool(
        'search',
        {'query': 'sans'},
        cancellation: cancellation,
      );
    default:
      throw ArgumentError('Unknown family: $family');
  }
}

Matcher get _cancelled => throwsA(
  isA<FormatException>().having(
    (e) => e.message,
    'reason',
    contains('cancelled'),
  ),
);

void main() {
  for (final family in ['mermaid', 'icon', 'font']) {
    test('$family network wrapper aborts an in-flight call on cancel',
        () async {
      var sourceCancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () {
          sourceCancelled = true;
        },
      );
      addTearDown(body.close);
      final token = UtilityCancellation();
      final pending = _networkCall(
        family,
        _StallingBodyClient(body.stream),
        token,
      );
      final assertion = expectLater(pending, _cancelled);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await assertion;
      expect(sourceCancelled, isTrue);
    });
  }

  test('QR generate aborts its isolated work when cancelled', () async {
    final token = UtilityCancellation();
    final pending = QrGeneratorCapability().callTool(
      'generate',
      {'text': 'x' * 2000, 'size': 2048},
      cancellation: token,
    );
    final assertion = expectLater(pending, _cancelled);
    token.cancel();
    await assertion;
  });

  test('Excalidraw merge aborts on an already-cancelled token', () async {
    final token = UtilityCancellation()..cancel();
    const scene = '{"elements":[{"type":"text","text":"x"}]}';
    await expectLater(
      ExcalidrawBridgeCapability().callTool(
        'merge',
        {'a_json': scene, 'b_json': scene},
        cancellation: token,
      ),
      _cancelled,
    );
  });

  test('null cancellation preserves the normal result', () async {
    final out = await QrGeneratorCapability().callTool('validate', {
      'text': 'hello',
    });
    expect(out, contains('"fits":true'));
  });
}
