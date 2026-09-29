import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Guard-rail: bare `catch (_) {}` blocks are the "silent catch" finding from
/// docs/ENGINEERING_AUDIT.md. Every swallow must go through Diag.swallow so it
/// is observable. This test keeps new bare catches from creeping back in.
void main() {
  test('no bare empty catches remain in lib/ (use Diag.swallow)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      // The single intentional guard lives inside the Diag seam itself.
      if (f.path.endsWith('core/diag.dart')) continue;
      final src = f.readAsStringSync();
      final matches = RegExp(r'catch \(_\) \{\}').allMatches(src).length;
      if (matches > 0) offenders.add('${f.path}: $matches');
    }
    expect(offenders, isEmpty, reason: 'bare catches:\n${offenders.join('\n')}');
  });
}
