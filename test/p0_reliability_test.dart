import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P0 (2026-09-13) reliability bundle pins.
void main() {
  group('provider/model identity', () {
    test('inference refuses to guess when the id is ambiguous', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final idx = src.indexOf('String? _inferProviderId');
      expect(idx, greaterThan(0));
      final body = src.substring(idx, idx + 600);
      // Ambiguous (more than one provider) must return null, never first-match.
      expect(body.contains('matches.length != 1'), isTrue);
      expect(body.contains('matches.first.id'), isTrue);
    });
  });
}
