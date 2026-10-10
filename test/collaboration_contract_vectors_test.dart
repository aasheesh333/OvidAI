import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/collaboration/models.dart';

Map<String, dynamic> _vectors() => jsonDecode(
      File('test/fixtures/collaboration/v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;

CollaborationWireReason _reasonOf(Map<String, dynamic> wire) {
  try {
    CollaborationEvent.fromWire(wire.cast<String, Object?>());
  } on CollaborationWireException catch (error) {
    return error.reason;
  }
  fail('expected CollaborationWireException');
}

void main() {
  test('server event vectors round-trip through the Dart codec', () {
    final vectors = _vectors();
    for (final raw in vectors['events'] as List<dynamic>) {
      final vector = raw as Map<String, dynamic>;
      final wire = (vector['server'] as Map).cast<String, Object?>();
      expect(CollaborationEvent.fromWire(wire).toWire(), wire, reason: vector['name'] as String);
    }
  });

  test('session vectors round-trip through the Dart codec', () {
    final vectors = _vectors();
    for (final raw in vectors['sessions'] as List<dynamic>) {
      final vector = raw as Map<String, dynamic>;
      final wire = (vector['wire'] as Map).cast<String, Object?>();
      expect(CollaborationSession.fromWire(wire).toWire(), wire, reason: vector['name'] as String);
    }
  });

  test('server errors use the same frozen reason codes', () {
    final vectors = _vectors();
    for (final raw in vectors['errors'] as List<dynamic>) {
      final vector = raw as Map<String, dynamic>;
      final wire = (vector['server'] as Map).cast<String, Object?>();
      expect(_reasonOf(wire).name, vector['reason'], reason: vector['name'] as String);
    }
  });
}
