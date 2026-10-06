import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugins/rest_descriptors_dev.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The dev-platforms batch routes GitLab/Jira/Bitbucket/Trello through inner
/// [RestApiCapability] calls (plus Trello's super call). Each wrapper accepted
/// a `UtilityCancellation? cancellation` token but dropped it, so a Stop could
/// never reach the engine's inner call. These tests prove the token is now
/// forwarded at every delegation and that every wrapper keeps the token in its
/// public signature.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourcePath = 'lib/core/native_plugins/rest_descriptors_dev.dart';

  group('cancellation forwarding', () {
    test('every inner callTool delegation forwards the token', () {
      final src = File(sourcePath).readAsStringSync();

      // Four delegated engine calls: GitLab/Jira's two `RestApiCapability(…)
      // .callTool(…)` branches, Bitbucket's `delegate.callTool(…)`, and
      // Trello's `super.callTool(…)`. Each must carry the wrapper token.
      final calls = RegExp(
        r'\.callTool\(([^;]*?)\);',
        dotAll: true,
      ).allMatches(src).toList();

      expect(
        calls,
        hasLength(4),
        reason: 'expected four inner callTool delegations in the dev batch',
      );
      for (final match in calls) {
        expect(
          match.group(1)!,
          contains('cancellation: cancellation'),
          reason: 'the inner call must receive the wrapper token:\n$match',
        );
      }
    });

    test('the host-routed branches forward the token they were handed', () {
      final src = File(sourcePath).readAsStringSync();
      final routed = RegExp(
        r'return RestApiCapability\(\s*descriptor,\s*client: _client,\s*'
        r'\)\.callTool\((.*?)\);',
        dotAll: true,
      ).firstMatch(src);
      final rerouted = RegExp(
        r'return RestApiCapability\(\s*_withBase\(descriptor,[^)]*\),\s*'
        r'client: _client,\s*\)\.callTool\((.*?)\);',
        dotAll: true,
      ).firstMatch(src);

      expect(routed, isNotNull,
          reason: 'GitLab no-host delegation shape changed unexpectedly');
      expect(rerouted, isNotNull,
          reason: 'host-rerouted delegation shape changed unexpectedly');
      expect(
        routed!.group(1),
        contains('cancellation: cancellation'),
        reason: 'the token must reach the default RestApiCapability.callTool',
      );
      expect(
        rerouted!.group(1),
        contains('cancellation: cancellation'),
        reason: 'the token must reach the rerouted RestApiCapability.callTool',
      );
    });

    test('each wrapper callTool accepts a cancellation token', () {
      final src = File(sourcePath).readAsStringSync();
      // _HostRoutedCapability (GitLab/Jira), BitbucketCapability, and
      // TrelloCapability declare the token in their public signature.
      final wrappers = RegExp(
        r'Future<String> callTool\(\s*String toolName,\s*'
        r'Map<String, dynamic> args, \{\s*UtilityCancellation\? cancellation,',
        dotAll: true,
      ).allMatches(src);
      expect(
        wrappers.length,
        greaterThanOrEqualTo(3),
        reason: 'every concrete dev REST wrapper must accept the token',
      );
    });
  });

  group('behavioral', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('GitLabCapability runs with a cancellation token supplied', () async {
      final client = MockClient((_) async => http.Response('[]', 200));
      final cap = GitLabCapability(client: client);
      await cap.configure({'token': 'gl-secret'});

      final token = UtilityCancellation();
      final out = await cap.callTool('list_projects', {}, cancellation: token);

      expect(out, contains('[]'));
      expect(token.isCancelled, isFalse);
    });

    test('JiraCapability runs with a cancellation token supplied', () async {
      final client = MockClient((_) async => http.Response('{}', 200));
      final cap = JiraCapability(client: client);
      await cap.configure({
        'host': 'acme.atlassian.net',
        'email': 'alice@example.com',
        'api_token': 'jira-secret',
      });

      final token = UtilityCancellation();
      final out =
          await cap.callTool('get_issue', {'key': 'PROJ-1'}, cancellation: token);

      expect(out, contains('{}'));
      expect(token.isCancelled, isFalse);
    });

    test('BitbucketCapability runs with a cancellation token supplied',
        () async {
      final client = MockClient((_) async => http.Response('{"values":[]}', 200));
      final cap = BitbucketCapability(client: client);
      await cap.configure({'token': 'bb-token'});

      final token = UtilityCancellation();
      final out = await cap.callTool(
        'list_repos',
        {'workspace': 'acme'},
        cancellation: token,
      );

      expect(out, contains('values'));
      expect(token.isCancelled, isFalse);
    });

    test('TrelloCapability runs with a cancellation token supplied', () async {
      final client = MockClient((_) async => http.Response('[]', 200));
      final cap = TrelloCapability(client: client);
      await cap.configure({'api_key': 'trello-key', 'api_token': 'trello-secret'});

      final token = UtilityCancellation();
      final out = await cap.callTool('list_boards', {}, cancellation: token);

      expect(out, contains('[]'));
      expect(token.isCancelled, isFalse);
    });
  });
}
