import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/canonical.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';

// Read the same literal fixture as Python, without generating a third file or
// invoking another language's implementation to compute expected results.
Map<String, Object?> loadVectors() {
  final source = File('server/sync/tests/test_service_vectors.py').readAsStringSync();
  final match = RegExp(r"SERVICE_VECTORS_JSON = r'''([\s\S]*?)'''").firstMatch(source);
  if (match == null) {
    throw StateError('Shared service vector fixture is missing');
  }
  return decodeStrictJson(match.group(1)!) as Map<String, Object?>;
}

Map<String, Object?> cloneWire(Object? value) =>
    mutableJson(decodeStrictJson(jsonEncode(value))) as Map<String, Object?>;

Object? mutableJson(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key as String: mutableJson(entry.value),
    };
  }
  if (value is List) return value.map(mutableJson).toList();
  return value;
}

void main() {
  final vectors = loadVectors();
  final results = vectors['results'] as List<Object?>;
  final replay = vectors['replay'] as Map<String, Object?>;

  group('shared service result vectors', () {
    for (final raw in results) {
      final vector = raw as Map<String, Object?>;
      test('${vector['name']} has exact cross-language canonical bytes', () {
        final body = vector['body'] as Map<String, Object?>;
        final expected = vector['canonical'] as String;
        expect(canonicalSyncBytes(body), utf8.encode(expected));
        expect(decodeStrictJson(expected), body);
      });
      test('${vector['name']} response is private and uncacheable', () {
        expect((vector['headers'] as Map)['cache-control'], 'no-store');
      });
    }

    test('result/control envelopes cannot be consumed as executable records', () {
      for (final raw in results) {
        final vector = raw as Map<String, Object?>;
        expect(
          () => SyncReplayRecord.fromWire(vector['body']),
          throwsA(isA<SyncDtoException>().having(
              (error) => error.code, 'code', 'invalid_record')),
          reason: vector['name'] as String,
        );
      }
    });

    test('Dart service error codec rejects malformed and secret-bearing errors', () {},
        skip: 'Dart service/error result codec is absent; Python covers the real error codec.');
  });

  group('replay inertness', () {
    test('command-shaped private text stays data with no network access', () {
      HttpOverrides.runZoned(() {
        final wire = cloneWire(replay);
        final record = SyncReplayRecord.fromWire(wire);
        expect(record.toWire(), replay);
        final expectedText = (replay['payload'] as Map)['text'];
        expect((record.payload as TranscriptPayload).text, expectedText);
        (wire['payload'] as Map)['text'] = 'changed after parsing';
        expect((record.payload as TranscriptPayload).text, expectedText);
        final again = SyncReplayRecord.fromWire(
            decodeStrictJsonUtf8(canonicalSyncBytes(record.toWire())));
        expect(again.toWire(), replay);
      }, createHttpClient: (_) => throw StateError('Replay attempted network access'));
    });

    test('runtime and credential fields are rejected at envelope and payload boundaries', () {
      for (final field in [
        'callback', 'command', 'runtimeQueue', 'processHandle', 'apiKey', 'authorization',
      ]) {
        for (final level in ['envelope', 'payload']) {
          final wire = cloneWire(replay);
          final target = level == 'envelope' ? wire : wire['payload'] as Map;
          target[field] = 'SENTINEL';
          try {
            SyncReplayRecord.fromWire(wire);
            fail('Accepted $level.$field');
          } on SyncDtoException catch (error) {
            expect(error.code, 'invalid_record', reason: '$level.$field');
            expect(error.toString(), isNot(contains('SENTINEL')));
            expect(error.source, isNull);
          }
        }
      }
    });
  });
}
