import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ratchet: no v2 screen may declare its own generic primitive.
///
/// The design system has exactly one tag (`OPill`), one chip (`OChip`), one
/// card (`OCard`), one section heading (`OSectionTitle`/`OSectionHeader`) and
/// one sheet header (`OSheetHeader`). A screen that declares `_Tag`,
/// `_Pill`, `_Badge`, `_Card`, `_Section`, `_Header`, `_Chip` or `_Row`
/// re-implements one of them and drifts from the shared look.
///
/// A screen may still declare a *specific* widget (`_PlanCard`,
/// `_MemberRow`); the ban is on the generic names that hide a duplicate.
///
/// Allowlist: file path → why the generic name has to stay. Keep this empty;
/// add an entry only with a reviewable reason and a follow-up.
const Map<String, String> _allowlist = <String, String>{};

final RegExp _duplicate = RegExp(
  r'^\s*class\s+_(Tag|Pill|Badge|Card|Section|Header|Chip|Row)\b',
  multiLine: true,
);

void main() {
  test('no v2 screen declares a local Tag/Pill/Badge/Card/Section/Header/'
      'Chip/Row', () {
    final root = Directory('lib/ui/v2');
    expect(
      root.existsSync(),
      isTrue,
      reason: 'Run this test from the package root (lib/ui/v2 must exist).',
    );

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    // Guards against a path change making the scan vacuously green.
    expect(files.length, greaterThan(50));

    final found = <String>[];
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      if (_allowlist.containsKey(path)) continue;
      final source = file.readAsStringSync();
      for (final match in _duplicate.allMatches(source)) {
        final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        found.add('$path:$line declares ${match.group(0)!.trim()}');
      }
    }

    expect(
      found,
      isEmpty,
      reason:
          'Local primitives duplicate the design system. Use OPill, OChip, '
          'OCard, OSectionTitle/OSectionHeader or OSheetHeader instead:\n'
          '${found.join('\n')}',
    );
  });

  test('the allowlist only names files that exist', () {
    for (final path in _allowlist.keys) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'Stale allowlist entry: $path no longer exists.',
      );
    }
  });
}
