// Shared test double for the gateway's session-event mirror.
//
// The trajectory screen calls
//   GET /sessions/:id/events?tail=1&limit=N   (newest page, ascending)
//   GET /sessions/:id/events?before=<seq>&limit=N (older page)
// This fake implements both against an in-memory ascending list so tests pin
// the screen's wire contract (including the explicit `tail=1`) without a
// gateway.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';

class FakeCloudEventsRest extends CloudRestClient {
  FakeCloudEventsRest({List<Map<String, dynamic>>? events, this.error})
    : events = events ?? <Map<String, dynamic>>[],
      super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  /// Ascending events, as the server returns them.
  List<Map<String, dynamic>> events;

  /// When non-null, every request throws this instead of answering.
  Object? error;

  /// When non-null, requests wait for this before answering (used to observe
  /// the reload's in-flight state).
  Completer<void>? hold;

  /// Every request's path + query, in call order.
  final List<Map<String, String>> requests = <Map<String, String>>[];

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add(<String, String>{'path': path, ...?query});
    final waiting = hold;
    if (waiting != null) await waiting.future;
    final failure = error;
    if (failure != null) throw failure;

    final q = query ?? const <String, String>{};
    final limit = int.tryParse(q['limit'] ?? '') ?? events.length;

    if (q['tail'] == '1') {
      final start = events.length > limit ? events.length - limit : 0;
      return <String, dynamic>{'events': events.sublist(start)};
    }
    final before = q['before'];
    if (before != null) {
      final index = events.indexWhere((e) => '${e['seq']}' == before);
      final end = index < 0 ? 0 : index;
      final start = end > limit ? end - limit : 0;
      return <String, dynamic>{'events': events.sublist(start, end)};
    }
    return <String, dynamic>{'events': events.take(limit).toList()};
  }
}

/// Installs the fake REST client and a store whose persisted id map resolves
/// [idMap] (local id → server UUID). Call in setUp; both singletons are
/// process-wide, so tests that need isolation should re-install per test.
void installFakeCloudEvents(
  FakeCloudEventsRest rest, {
  Map<String, String> idMap = const <String, String>{},
}) {
  CloudRestClient.installForTest(rest);
  CloudSessionStore.installForTest(CloudSessionStore.forTest(idMap: idMap));
}

/// One wire-shaped event. `seq` is a string on the wire.
Map<String, dynamic> cloudEvent(
  String seq,
  String type, [
  Map<String, dynamic> payload = const <String, dynamic>{},
]) => <String, dynamic>{
  'sessionId': 'server-session',
  'seq': seq,
  'type': type,
  'payload': payload,
  'ts': '2026-10-17T10:00:0${int.tryParse(seq) ?? 0}Z',
};

/// Wait until the trajectory screen leaves its loading state.
///
/// Must be called inside [WidgetTester.runAsync]: the store's `ready` future
/// and the REST continuation are created outside the widget test's fake-async
/// zone, so `pumpAndSettle` alone never drains them (the same reason the old
/// ledger tests used `runAsync` for real file IO).
Future<void> settleTrajectory(WidgetTester tester) async {
  // Let the tap/setState that started the request build its frame before the
  // busy check (otherwise an immediate answer can be mistaken for idle).
  await tester.pump();
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  bool busy() =>
      find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
      find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
  while (busy() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}
