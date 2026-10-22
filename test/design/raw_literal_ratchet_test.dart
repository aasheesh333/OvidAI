import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ratchet: no v2 screen may invent a colour or a radius.
///
/// The contract (`docs/design/MINIMAL_UI_CONTRACT.md` §4) says every colour
/// comes from `OColors` and every radius from `ORadius`. A raw `Color(0x…)`,
/// a `Colors.*` constant or a `circular(<4)` literal bypasses the theme, so it
/// cannot answer light/dark or a token change.
///
/// The allowlist below is the complete set of documented one-offs. It is a
/// *token* allowlist, not a file allowlist: every new site still fails, even
/// in a file that already uses an exempt token. Keep it tiny; add an entry
/// only when the value is genuinely not a painted design colour or radius.
const Map<String, String> _colourAllowlist = <String, String>{
  'Colors.transparent':
      'Not a colour: it is the sentinel for "no fill" / "not selected" on '
      'conditional backgrounds and icon tints. Painting transparent cannot '
      'drift from the palette, so there is no token to use instead.',
};

/// No radius may be below this. `ORadius.xs` (4 dp) is the smallest rung;
/// 0 is allowed because a square is a deliberate shape, not a near-miss.
const double _minimumRadius = 4;

final RegExp _rawHex = RegExp(r'\bColor\(0x');
final RegExp _materialColour = RegExp(r'\bColors\.([A-Za-z_][A-Za-z0-9_]*)');
final RegExp _radiusLiteral = RegExp(
  r'\b(?:BorderRadius|Radius)\.circular\(\s*([0-9]+(?:\.[0-9]+)?)\s*\)',
);

void main() {
  test('lib/ui/v2 uses OColors and ORadius, never raw literals', () {
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
    expect(files.length, greaterThan(100));

    final found = <String>[];
    final usedExemptions = <String>{};

    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      final source = file.readAsStringSync();

      int lineOf(int offset) =>
          '\n'.allMatches(source.substring(0, offset)).length + 1;

      for (final match in _rawHex.allMatches(source)) {
        found.add('$path:${lineOf(match.start)} raw ${match.group(0)}');
      }

      for (final match in _materialColour.allMatches(source)) {
        final token = 'Colors.${match.group(1)}';
        if (_colourAllowlist.containsKey(token)) {
          usedExemptions.add(token);
          continue;
        }
        found.add('$path:${lineOf(match.start)} $token');
      }

      for (final match in _radiusLiteral.allMatches(source)) {
        final value = double.parse(match.group(1)!);
        if (value == 0 || value >= _minimumRadius) continue;
        found.add(
          '$path:${lineOf(match.start)} '
          'circular(${match.group(1)}) — below ORadius.xs ($_minimumRadius)',
        );
      }
    }

    expect(
      found,
      isEmpty,
      reason:
          'Raw design values bypass the theme. Use OColors.of(context) for '
          'colour and ORadius.xs/s/m/l/xl/pill for radius:\n'
          '${found.join('\n')}',
    );

    final stale = _colourAllowlist.keys
        .where((token) => !usedExemptions.contains(token))
        .toList();
    expect(
      stale,
      isEmpty,
      reason:
          'Stale allowlist entries: $stale no longer occur. Delete them so '
          'the ratchet stays honest.',
    );
  });
}
