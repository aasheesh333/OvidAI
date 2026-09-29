import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Guard-rail: `firstWhere` without an `orElse` throws when nothing matches —
/// the "48 unguarded lookups" finding from docs/ENGINEERING_AUDIT.md. Prefer
/// `firstWhereOrNull` (from package:collection) with explicit null handling, or
/// an explicit `orElse:` that names the failure. This keeps new unguarded
/// lookups from creeping back in.
void main() {
  test('no firstWhere without orElse in lib/ (prefer firstWhereOrNull)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r'\.firstWhere\(').allMatches(src)) {
        // A generous look-ahead: the matching call's orElse may sit a few
        // lines down. If none appears before the next firstWhere or a clear
        // statement boundary, flag it.
        final tail =
            src.substring(m.start, (m.start + 600).clamp(0, src.length));
        if (!tail.contains('orElse')) {
          offenders.add(f.path);
          break;
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'unguarded firstWhere:\n${offenders.join('\n')}');
  });
}
