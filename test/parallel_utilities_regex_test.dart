import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';

// The outer isolate protects the test runner while proving that the actual
// capability (including its caller's event loop) survives catastrophic input.
void _catastrophicProbe(List<Object> message) async {
  final port = message[0] as SendPort;
  final tool = message[1] as String;
  var ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
  final capability = RegexBuilderCapability();
  try {
    await capability.callTool(tool, {
      'pattern': r'^(a+)+$',
      'text': '${'a' * 40}!',
      'replacement': 'x',
      'timeout_ms': 150,
    });
    port.send({'error': 'unexpected success', 'ticks': ticks});
  } catch (error) {
    final recovery = await capability.callTool('replace', {
      'pattern': 'a', 'text': 'cat', 'replacement': 'o',
    });
    port.send({'error': error.toString(), 'ticks': ticks, 'recovery': recovery});
  } finally {
    timer.cancel();
  }
}

void main() {
  final regex = RegexBuilderCapability();
  for (final tool in ['test', 'replace']) {
    test('regex $tool cancels catastrophic work without blocking caller', () async {
      final port = ReceivePort();
      final worker = await Isolate.spawn(_catastrophicProbe, [port.sendPort, tool]);
      final watch = Stopwatch()..start();
      try {
        final result = await port.first.timeout(const Duration(seconds: 4)) as Map;
        expect(result['error'], contains('time limit'));
        expect(result['ticks'], greaterThan(0));
        expect(result['recovery'], 'cot');
        expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      } finally {
        worker.kill(priority: Isolate.immediate);
        port.close();
      }
    });
  }

  final oversized = <String, Map<String, dynamic>>{
    'pattern': {'pattern': 'a' * 4097, 'text': ''},
    'text': {'pattern': 'z', 'text': 'a' * 65537},
    'replacement': {'pattern': 'a', 'text': 'a', 'replacement': 'x' * 65537},
    'matches': {'pattern': 'a', 'text': 'a' * 1001},
    'groups': {'pattern': '()' * 101, 'text': ''},
    'output': {'pattern': 'a', 'text': 'a' * 100, 'replacement': 'x' * 65536},
    'timeout zero': {'pattern': 'a', 'text': '', 'timeout_ms': 0},
    'timeout excessive': {'pattern': 'a', 'text': '', 'timeout_ms': 2001},
    'timeout fractional': {'pattern': 'a', 'text': '', 'timeout_ms': 1.5},
  };
  for (final fixture in oversized.entries) {
    test('regex rejects ${fixture.key} limit overflow explicitly', () async {
      await expectLater(
        regex.callTool(fixture.value.containsKey('replacement') ? 'replace' : 'test', fixture.value)
            .then<void>((_) {}),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('regex bounds serialized capture output before returning partial matches', () async {
    await expectLater(
      regex.callTool('test', {'pattern': '${'(' * 20}a+${')' * 20}', 'text': 'a' * 65536})
          .then<void>((_) {}),
      throwsA(isA<FormatException>()),
    );
  });

  test('regex preserves groups, indices, flags and literal replacement semantics', () async {
    final result = jsonDecode(await regex.callTool('test', {
      'pattern': r'^(a)(b)?', 'text': 'A\nab', 'multiline': true, 'case_sensitive': false,
    }));
    expect(result, {
      'matches': [
        {'match': 'A', 'start': 0, 'end': 1, 'groups': ['A', null]},
        {'match': 'ab', 'start': 2, 'end': 4, 'groups': ['a', 'b']},
      ],
      'count': 2,
    });
    expect(await regex.callTool('replace', {
      'pattern': '', 'text': 'ab', 'replacement': r'$1',
    }), r'$1a$1b$1');
  });
}
