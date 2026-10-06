import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugins/rest_descriptors_aimedia.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The AI/media batch wraps `RestApiCapability` for the Stripe tools. The
/// wrapper accepted a `UtilityCancellation? cancellation` token but dropped it
/// on the floor, so a Stop could never reach the engine's inner call. These
/// tests prove the token is now forwarded (and that every wrapper keeps the
/// token in its public signature).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourcePath = 'lib/core/native_plugins/rest_descriptors_aimedia.dart';

  group('cancellation forwarding', () {
    test('every RestApiCapability delegation forwards the token', () {
      final src = File(sourcePath).readAsStringSync();

      // Each delegated inner call in this file is shaped as
      //   final cap = RestApiCapability(...);
      //   return await cap.callTool(toolName, args, cancellation: cancellation);
      final delegations = RegExp(
        r'final cap = RestApiCapability\([^;]*\);\s*'
        r'return await cap\.callTool\((.*?)\);',
        dotAll: true,
      ).allMatches(src).toList();

      expect(
        delegations,
        isNotEmpty,
        reason: 'expected the Stripe wrapper to delegate to RestApiCapability',
      );
      for (final match in delegations) {
        expect(
          match.group(1)!,
          contains('cancellation: cancellation'),
          reason: 'the inner call must receive the wrapper token:\n$match',
        );
      }
    });

    test('the Stripe wrapper forwards the token it was handed', () {
      final src = File(sourcePath).readAsStringSync();
      final stripe = RegExp(
        r'final cap = RestApiCapability\(descriptor, client: client\);\s*'
        r'return await cap\.callTool\((.*?)\);',
        dotAll: true,
      ).firstMatch(src);

      expect(stripe, isNotNull,
          reason: 'Stripe delegation shape changed unexpectedly');
      expect(
        stripe!.group(1),
        contains('cancellation: cancellation'),
        reason: 'the token must reach RestApiCapability.callTool',
      );
    });

    test('each wrapper callTool accepts a cancellation token', () {
      final src = File(sourcePath).readAsStringSync();
      // Six REST wrappers (DALL·E, ElevenLabs, Notion, Drive, Stripe,
      // YouTube) declare the token in their public signature.
      final wrappers = RegExp(
        r'Future<String> callTool\(\s*String toolName,\s*'
        r'Map<String, dynamic> args, \{\s*UtilityCancellation\? cancellation,',
        dotAll: true,
      ).allMatches(src);
      expect(
        wrappers.length,
        greaterThanOrEqualTo(6),
        reason: 'every concrete REST wrapper must accept the token',
      );
    });
  });

  group('behavioral', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('StripeCapability.callTool runs when a cancellation token is supplied',
        () async {
      final client = MockClient((_) async => http.Response('{"data":[]}', 200));
      final cap = StripeCapability(client: client);
      await cap.configure({'secret_key': 'sk_test_token'});

      final token = UtilityCancellation();
      final out = await cap.callTool('list_customers', {}, cancellation: token);

      expect(out, contains('data'));
      expect(token.isCancelled, isFalse);
    });
  });
}
