import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/canonical.dart';

const fixturePath = 'test/fixtures/private_sync/canonical_vectors.json';

void main() {
  final file = File(fixturePath);
  if (!file.existsSync()) {
    test('shared canonical vectors', () {},
        skip: 'Shared fixture $fixturePath is absent; it is produced by the '
            'Python contract lane. Inline RFC 8785 examples live in '
            'test/private_sync_canonical_test.dart.');
    return;
  }

  // The fixture itself is parsed with the strict decoder so duplicate keys in
  // a vector input are surfaced rather than silently collapsed.
  final root = decodeStrictJsonUtf8(file.readAsBytesSync());
  final vectors = (root as Map<String, Object?>)['vectors'] as List<Object?>;

  test('fixture contains vectors', () {
    expect(vectors, isNotEmpty);
  });

  for (final raw in vectors) {
    final vector = raw as Map<String, Object?>;
    final name = vector['name'] as String;
    test('vector: $name', () {
      final expected = vector['canonical'] as String;
      final input = vector['input'];
      final actual = canonicalSyncBytes(input);
      expect(utf8.decode(actual), expected);
      expect(actual, utf8.encode(expected));
      // The expected canonical text must itself be a fixed point.
      expect(canonicalJsonString(decodeStrictJson(expected)), expected);
    });
  }
}
