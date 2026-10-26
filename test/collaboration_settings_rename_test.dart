import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/collaboration/production.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

// UNEXECUTED: authored while HEAVY-COMMANDS-PAUSED.md forbids Flutter tests.

const _sessionId = '00000000-0000-4000-8000-000000000001';

class _RenameServer {
  final stateRequests = <http.Request>[];
  final events = <String>[];
  var ownerName = 'Old Name';
  var failState = false;
  var rejectProfile = false;

  Future<http.Response> handle(http.Request request) async {
    http.Response json(Object? body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'cache-control': 'private, no-store'},
    );
    if (request.url.path == '/cloud/v1/account/profile') {
      if (rejectProfile) {
        return json({'error': {'code': 'bad_request', 'message': 'Invalid request'}}, 400);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      ownerName = (body['displayName'] as String).trim();
      events.add('server-confirmed');
      return json({'displayName': ownerName});
    }
    if (request.url.path == '/chat') {
      return json({
        'schemaVersion': 1,
        'sessionToken': 'tok',
        'session': {
          'schemaVersion': 1,
          'sessionId': _sessionId,
          'ownerParticipantId': 'p-owner',
          'lifecycle': 'active',
        },
        'member': {'participantId': 'p-owner', 'role': 'owner', 'status': 'active'},
        'cursor': 'v1:0',
      }, 201);
    }
    if (request.url.path == '/chat/tok/events') {
      return json({
        'schemaVersion': 1,
        'events': [],
        'nextCursor': 'v1:0',
        'hasMore': false,
      });
    }
    if (request.url.path == '/chat/tok') {
      stateRequests.add(request);
      if (failState) {
        return http.Response('private refresh failure', 503,
            headers: {'cache-control': 'private, no-store'});
      }
      final member = {
        'participantId': 'p-owner',
        'role': 'owner',
        'status': 'active',
        'displayName': ownerName,
      };
      return json({
        'schemaVersion': 1,
        'session': {
          'schemaVersion': 1,
          'sessionId': _sessionId,
          'ownerParticipantId': 'p-owner',
          'lifecycle': 'active',
        },
        'member': member,
        'members': [member],
        'initialMembers': [member],
        'replayThroughSequence': 0,
        'cursor': 'v1:0',
        'turn': null,
      });
    }
    return json({'error': {'code': 'not_found', 'message': 'Route not found.'}}, 404);
  }
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var index = 0; index < 400 && !condition(); index++) {
    // Widget tests run in a fake-async zone, so a bare Future.delayed would
    // never advance without a frame pump.
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _RenameServer server;
  late CloudRestClient previousRest;
  late CloudUsageStore usage;
  late V2SettingsActions actions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    root = await Directory.systemTemp.createTemp('collab-settings-rename-');
    server = _RenameServer();
    previousRest = CloudRestClient.I;
    CloudRestClient.installForTest(CloudRestClient(
      restBase: 'https://test.invalid/cloud/v1',
      headers: CloudHeaders.forTest(),
      httpClient: MockClient(server.handle),
    ));
    usage = CloudUsageStore.acquire(AppState.I);
  });

  tearDown(() async {
    actions.dispose();
    usage.dispose();
    CloudRestClient.installForTest(previousRest);
    AppState.resetTestInstance();
    await root.delete(recursive: true);
  });

  CollaborationProduction makeProduction() => CollaborationProduction(
    endpoint: 'https://test.invalid',
    rootDirectory: () async => root,
    accountReady: () => true,
    currentUid: () => 'alice',
    accessToken: () async => 'token',
    httpClientFactory: () => MockClient(server.handle),
  );

  Future<void> bindLiveSession() async {
    final production = makeProduction();
    AppState.I.collaboration = production;
    await production.bind('alice', 7);
    await production.create(sessionId: _sessionId);
  }

  Future<void> rename(
    WidgetTester tester,
    String name, {
    required Future<String?> Function(String) updateDisplayName,
  }) async {
    actions = V2SettingsActions(
      usage,
      updateDisplayName: updateDisplayName,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => actions.renameAccount(context),
            child: const Text('Open rename'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), name);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('confirmed server save forces Collab read even when Firebase fails', (tester) async {
    await tester.runAsync(bindLiveSession);
    final firebaseCalls = <String>[];
    await rename(
      tester,
      'Confirmed Name',
      updateDisplayName: (name) async {
        firebaseCalls.add(name);
        return 'mirror failed';
      },
    );
    await _until(tester, () => AppState.I.collaboration!.state?.nameOf('p-owner') == 'Confirmed Name');

    expect(server.events, ['server-confirmed']);
    expect(firebaseCalls, ['Confirmed Name']);
    expect(server.stateRequests, isNotEmpty);
    expect(find.text('Saved; profile failed.'), findsOneWidget);
    expect(find.text('Rename failed.'), findsNothing);
    await tester.runAsync(() => AppState.I.collaboration!.release());
  });

  testWidgets('server rejection skips forced read and Firebase mirror', (tester) async {
    await tester.runAsync(bindLiveSession);
    server.rejectProfile = true;
    final firebaseCalls = <String>[];
    await rename(
      tester,
      'Rejected Name',
      updateDisplayName: (name) async {
        firebaseCalls.add(name);
        return null;
      },
    );

    expect(firebaseCalls, isEmpty);
    expect(server.stateRequests, isEmpty);
    expect(find.text('Rename failed.'), findsOneWidget);
    await tester.runAsync(() => AppState.I.collaboration!.release());
  });

  testWidgets('no live session makes profile refresh a no-op without blocking Firebase', (tester) async {
    AppState.I.collaboration = makeProduction();
    await tester.runAsync(() => AppState.I.collaboration!.bind('alice', 7));
    final firebaseCalls = <String>[];
    await rename(
      tester,
      'No Room Name',
      updateDisplayName: (name) async {
        firebaseCalls.add(name);
        return null;
      },
    );

    expect(firebaseCalls, ['No Room Name']);
    expect(server.stateRequests, isEmpty);
    expect(find.text('Rename failed.'), findsNothing);
    await tester.runAsync(() => AppState.I.collaboration!.release());
  });

  testWidgets('refresh failure after confirmed save cannot block the Firebase mirror', (tester) async {
    await tester.runAsync(bindLiveSession);
    server.failState = true;
    final firebaseCalls = <String>[];
    await rename(
      tester,
      'Durable Server Name',
      updateDisplayName: (name) async {
        firebaseCalls.add(name);
        return null;
      },
    );
    await _until(tester, () => server.stateRequests.isNotEmpty);
    expect(firebaseCalls, ['Durable Server Name']);
    expect(find.text('Rename failed.'), findsNothing);
    server.failState = false;
    AppState.I.collaboration!.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(tester, () => AppState.I.collaboration!.state?.nameOf('p-owner') == 'Durable Server Name');
    await tester.runAsync(() => AppState.I.collaboration!.release());
  });
}
