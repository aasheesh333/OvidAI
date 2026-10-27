import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/static_rich_content.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/message_blocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() => calls = <MethodCall>[]);
  tearDown(() {
    messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, null);
  });

  test('render carries request identity and explicit cancellation', () async {
    final response = Completer<Uint8List>();
    messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, (
      call,
    ) {
      calls.add(call);
      if (call.method == 'cancelRenderPng') return Future.value(true);
      return response.future;
    });

    final pending = StaticRichContentRenderer.renderMermaidPng(
      'flowchart LR\nA --> B',
      requestId: 'request-1',
    );
    final expectation = expectLater(
      pending,
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    await StaticRichContentRenderer.cancelRender('request-1');
    response.completeError(
      PlatformException(code: 'cancelled', message: 'cancelled'),
    );

    await expectation;
    expect(calls.map((call) => call.method), [
      'renderMermaidPng',
      'cancelRenderPng',
    ]);
    expect(calls.last.arguments, <String, Object?>{'requestId': 'request-1'});
  });

  test(
    'cancel rejects image bytes and requires a boolean channel outcome',
    () async {
      messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'cancelRenderPng') {
          return Uint8List.fromList(const <int>[137, 80, 78, 71]);
        }
        return true;
      });

      expect(
        () => StaticRichContentRenderer.cancelRender('request-bytes'),
        throwsA(isA<StateError>()),
      );
      expect(calls.single.method, 'cancelRenderPng');
      expect(calls.single.arguments, <String, Object?>{
        'requestId': 'request-bytes',
      });
    },
  );

  testWidgets('disposing a pending diagram cancels its render and timer', (
    tester,
  ) async {
    final pending = Completer<Uint8List>();
    messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'cancelRenderPng') return true;
      return pending.future;
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const V2MessageBlocks(
          markdown: '```mermaid\nflowchart LR\nA --> B\n```',
        ),
      ),
    );
    await tester.pump();
    expect(calls.single.method, 'renderMermaidPng');
    final requestId = (calls.single.arguments as Map)['requestId'];

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.binding.transientCallbackCount, 0);
    expect(calls.map((call) => call.method), contains('cancelRenderPng'));
    final cancel = calls.lastWhere((call) => call.method == 'cancelRenderPng');
    expect(cancel.arguments, <String, Object?>{'requestId': requestId});
  });

  test(
    'cancel handles an unregistered renderer without leaking the exception',
    () async {
      expect(
        await StaticRichContentRenderer.cancelRender('unregistered-renderer'),
        isFalse,
      );
    },
  );

  testWidgets(
    'late disposal with an unregistered renderer has no async error',
    (tester) async {
      // No channel handler: both render and cancellation are unavailable.
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const V2MessageBlocks(
            markdown: '```mermaid\nflowchart LR\nA --> B\n```',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'late disposal with malformed cancel outcome has no async error',
    (tester) async {
      final pending = Completer<Uint8List>();
      messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'cancelRenderPng') {
          return Uint8List.fromList(const <int>[137, 80, 78, 71]);
        }
        return pending.future;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const V2MessageBlocks(
            markdown: '```mermaid\nflowchart LR\nA --> B\n```',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  test('a bounded render timeout cancels the same native request', () async {
    messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'cancelRenderPng') return Future.value(true);
      return Completer<Uint8List>().future;
    });

    final pending = StaticRichContentRenderer.renderMermaidPng(
      'flowchart LR\nA --> B',
      requestId: 'request-timeout',
      timeout: const Duration(milliseconds: 5),
    );
    await expectLater(pending, throwsA(isA<TimeoutException>()));

    expect(calls.map((call) => call.method), [
      'renderMermaidPng',
      'cancelRenderPng',
    ]);
    expect(calls.last.arguments, <String, Object?>{
      'requestId': 'request-timeout',
    });
    final start = calls.first.arguments as Map;
    expect(start['requestId'], 'request-timeout');
    expect(start['timeoutMs'], 5);
  });
}
