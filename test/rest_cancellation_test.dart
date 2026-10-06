import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [RestApiCapability.callTool] accepts a [UtilityCancellation] token; these
/// tests prove it is honoured: a cancelled token fails before sending, an
/// in-flight (or streaming) request is aborted promptly, and a token that
/// flips after the response arrives still fails. A null token preserves the
/// original behaviour.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  const descriptor = RestServiceDescriptor(
    pluginName: 'Cancel API',
    baseUrl: 'https://api.example.com',
    auth: RestAuthKind.none,
    tools: [
      RestToolDef(
        name: 'get_thing',
        description: 'Fetch a thing.',
        method: 'GET',
        path: '/thing',
        inputSchema: {'type': 'object'},
      ),
    ],
  );

  RestApiCapability capWith(http.Client client) =>
      RestApiCapability(descriptor, client: client);

  Matcher throwsCancelled() => throwsA(
    isA<FormatException>().having(
      (e) => e.message,
      'message',
      contains('cancelled'),
    ),
  );

  test('already-cancelled token fails before the request is sent', () async {
    var sent = false;
    final cap = capWith(
      MockClient((_) async {
        sent = true;
        return http.Response('{}', 200);
      }),
    );
    final token = UtilityCancellation()..cancel();
    await expectLater(
      cap.callTool('get_thing', {}, cancellation: token),
      throwsCancelled(),
    );
    expect(sent, isFalse);
  });

  test('cancelling an in-flight request returns promptly', () async {
    final gate = Completer<http.Response>();
    final cap = capWith(MockClient((_) => gate.future));
    final token = UtilityCancellation();
    final clock = Stopwatch()..start();
    final pending = cap.callTool('get_thing', {}, cancellation: token);
    final check = expectLater(pending, throwsCancelled());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();
    await check;
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('cancelling after headers cancels the response subscription', () async {
    final controller = StreamController<List<int>>();
    var cancelled = false;
    controller.onCancel = () {
      cancelled = true;
    };
    final cap = capWith(
      MockClient.streaming(
        (request, bodyStream) async =>
            http.StreamedResponse(controller.stream, 200),
      ),
    );
    final token = UtilityCancellation();
    final pending = cap.callTool('get_thing', {}, cancellation: token);
    final check = expectLater(pending, throwsCancelled());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();
    await check;
    expect(cancelled, isTrue);
  });

  test('a token that flips after the response arrives still fails', () async {
    final token = UtilityCancellation();
    final cap = capWith(
      MockClient.streaming((request, bodyStream) async {
        final controller = StreamController<List<int>>(sync: true);
        scheduleMicrotask(() {
          controller.add(utf8.encode('{}'));
          token.cancel();
          controller.close();
        });
        return http.StreamedResponse(controller.stream, 200);
      }),
    );
    await expectLater(
      cap.callTool('get_thing', {}, cancellation: token),
      throwsCancelled(),
    );
  });

  test('null cancellation leaves normal responses untouched', () async {
    final cap = capWith(
      MockClient((_) async => http.Response('{"ok":true}', 200)),
    );
    expect(await cap.callTool('get_thing', {}), contains('"ok":true'));
  });
}
