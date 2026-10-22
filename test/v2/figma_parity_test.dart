// The Figma sheet and the app must describe the same screens.
//
// The sheet is the design reference a designer works from, and the registry is
// what the app can render. They were two hand-kept lists, so they drifted: the
// sheet still drew a `share_sheet` frame after that screen was removed from the
// app as a duplicate. A design file that shows a screen the product does not
// have is worse than no design file.
//
// This test reads both lists and fails on any difference, in either direction.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screen ids the generator draws, in sheet order.
List<String> _sheetScreenIds(String svgPath) {
  final file = File(svgPath);
  if (!file.existsSync()) {
    fail(
      'Missing $svgPath. Run `python3 tool/figma_sheet.py` (and `--dark`) '
      'before this test; the sheet is generated, not committed by hand.',
    );
  }
  final svg = file.readAsStringSync();
  // Each frame is one <g id="screen_id">; the -label and -frame children carry
  // a suffix and are not screens.
  return RegExp(r'<g id="([a-z_]+)"')
      .allMatches(svg)
      .map((match) => match.group(1)!)
      .where((id) => !id.endsWith('-label') && !id.endsWith('-frame'))
      .toList();
}

/// Screen ids the app can render, in registry order.
List<String> _registryIds() {
  final source = File('lib/ui/v2/v2_registry.dart').readAsStringSync();
  return RegExp(r"V2ScreenEntry\(([\s\S]*?)\n  \),")
      .allMatches(source)
      .map((block) => RegExp(r"id: '([^']+)'").firstMatch(block.group(1)!))
      .whereType<RegExpMatch>()
      .map((match) => match.group(1)!)
      .toList();
}

void main() {
  test('the Figma sheet draws exactly the screens the app has', () {
    final sheet = _sheetScreenIds('build/figma/ovid-si-screens.svg');
    final registry = _registryIds();

    final inSheetOnly = sheet.toSet().difference(registry.toSet()).toList()
      ..sort();
    final inAppOnly = registry.toSet().difference(sheet.toSet()).toList()
      ..sort();

    expect(
      inSheetOnly,
      isEmpty,
      reason:
          'The design sheet draws screens the app cannot open: '
          '${inSheetOnly.join(', ')}. Remove them from tool/figma_sheet.py, or '
          'wire the screen in the app — a design file must not show a screen '
          'the product does not have.',
    );
    expect(
      inAppOnly,
      isEmpty,
      reason:
          'The app has screens the design sheet does not draw: '
          '${inAppOnly.join(', ')}. Add them to tool/figma_sheet.py so the '
          'design reference stays complete.',
    );
    expect(sheet.length, equals(registry.length));
  });

  test('the dark sheet draws the same screens as the light one', () {
    final light = _sheetScreenIds('build/figma/ovid-si-screens.svg');
    final dark = _sheetScreenIds('build/figma/ovid-si-screens-dark.svg');
    expect(
      dark,
      equals(light),
      reason:
          'The two themes are generated from the same builder list, so a '
          'difference means one was generated from a stale copy of the tool.',
    );
  });

  test('the sheet covers every screen group, not just a subset', () {
    // A regression guard for the generator: it once drew only the 16 primary
    // screens and the sheet looked complete.
    final sheet = _sheetScreenIds('build/figma/ovid-si-screens.svg');
    expect(
      sheet.length,
      greaterThanOrEqualTo(45),
      reason:
          'The sheet has only ${sheet.length} screens. Every registered screen '
          'must be drawn, not just the primary ones.',
    );
  });
}
