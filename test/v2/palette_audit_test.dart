import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_contrast.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';

/// Ratchet: the Paper / Ink / Signal Red / Stone palette, flat, in both themes.
///
/// The brief is exact: Paper `#F4F1EA` is the page, Ink `#1B1B1B` is the text,
/// Signal Red `#E5484D` belongs to the agent alone, Stone `#8A867D` is the only
/// secondary text. Paper and Ink carry ~90 % of every surface; Signal Red gets
/// the remaining ~10 % and is never a status colour, a badge tint or an error.
///
/// Everything here is computed from the tokens, not from copies of the hex
/// values, so a palette edit has to keep the contrast floors and the flat
/// contract true or this file fails. The only hard-coded numbers are the four
/// canonical hexes, the floors and the pinned ratios quoted beside them.
const int paperHex = 0xFFF4F1EA;
const int inkHex = 0xFF1B1B1B;
const int signalRedHex = 0xFFE5484D;
const int stoneHex = 0xFF8A867D;

/// The dark page lifts Signal Red for legibility on Ink. Same hue, lighter
/// value; `test/design/o_theme_test.dart` pins the same constant, so this is a
/// documented step of the palette rather than a second colour.
const int signalRedDarkHex = 0xFFFF6B6F;

/// Colour references to Signal Red. `V2CollabMessageKind.agent` and a local
/// `final agent = …` are not colour references and must not match.
final RegExp _signalRedReference = RegExp(
  r'(?:\bc|colors|colours|palette|dialogColors|dialogColours|tokens)\.agent\b'
  r'|OColors\.(?:light|dark)\.agent\b'
  r'|\bsignalRed\b'
  r'|Color\(0xFFE5484D\)'
  r'|Color\(0xFFFF6B6F\)',
);

/// A Signal Red reference is a misuse when the statement around it is an error,
/// a destructive action or a generic badge. The window is one line either side
/// so a wrapped `TextStyle(color: …)` cannot slip through.
final RegExp _nonAgentPurpose = RegExp(
  r'\b(error|errors|danger|dangerous|delete|deleted|deleting|destructive'
  r'|destruction|remove|removed|trash|failure|failed|fail)\b',
  caseSensitive: false,
);

/// Every `agent` colour reference whose statement also talks about errors or
/// destruction. Returns `path:line | code | near "context"` strings.
List<String> findSignalRedMisuses(String source, {String path = 'source'}) {
  final lines = source.split('\n');
  final hits = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (!_signalRedReference.hasMatch(lines[i])) continue;
    final from = math.max(0, i - 1);
    final to = math.min(lines.length - 1, i + 1);
    for (var j = from; j <= to; j++) {
      if (_nonAgentPurpose.hasMatch(lines[j])) {
        hits.add(
          '$path:${i + 1} | ${lines[i].trim()} | near "${lines[j].trim()}"',
        );
        break;
      }
    }
  }
  return hits;
}

final RegExp _flatPaint = RegExp(
  r'\b(LinearGradient|RadialGradient|SweepGradient|ShaderMask)\b',
);
final RegExp _glow = RegExp(r'\b(BoxShadow|blurRadius|spreadRadius)\b');
final RegExp _elevation = RegExp(r'\belevation:\s*([0-9]+(?:\.[0-9]+)?)');

List<File> _v2Files() {
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
  // Guards against a path change making every scan vacuously green.
  expect(files.length, greaterThan(100));
  return files;
}

String _relative(File file) => file.path.replaceAll(r'\', '/');

/// Hue in degrees, used to prove the dark Signal Red is the same colour.
double _hue(Color color) {
  final max = math.max(color.r, math.max(color.g, color.b));
  final min = math.min(color.r, math.min(color.g, color.b));
  final delta = max - min;
  if (delta == 0) return 0;
  final double raw;
  if (max == color.r) {
    raw = ((color.g - color.b) / delta) % 6;
  } else if (max == color.g) {
    raw = (color.b - color.r) / delta + 2;
  } else {
    raw = (color.r - color.g) / delta + 4;
  }
  return (raw * 60 + 360) % 360;
}

double _hueGap(Color a, Color b) {
  final d = (_hue(a) - _hue(b)).abs();
  return math.min(d, 360 - d);
}

void main() {
  group('palette is exact', () {
    test('light is Paper page, Ink text, Signal Red agent, Stone border', () {
      expect(OColors.light.bg.toARGB32(), paperHex); // Paper page
      expect(OColors.light.text.toARGB32(), inkHex); // Ink text
      expect(OColors.light.agent.toARGB32(), signalRedHex); // Signal Red
      expect(OColors.light.inputBorder.toARGB32(), stoneHex); // Stone
      // Ordinary actions are Ink on Paper; the palette spends no red on them.
      expect(OColors.light.accentFill.toARGB32(), inkHex);
      expect(OColors.light.onAccent.toARGB32(), paperHex);
    });

    test('dark inverts Paper and Ink and keeps Stone exact', () {
      expect(OColors.dark.text.toARGB32(), paperHex); // Paper text
      expect(OColors.dark.onAccent.toARGB32(), inkHex); // Ink on Paper fill
      expect(OColors.dark.accentFill.toARGB32(), paperHex);
      expect(OColors.dark.inputBorder.toARGB32(), stoneHex); // Stone
      expect(OColors.dark.textFaint.toARGB32(), stoneHex); // Stone as caption
      // Pinned so the documented lift cannot drift into a new hue.
      expect(OColors.dark.agent.toARGB32(), signalRedDarkHex);
    });

    test('dark Signal Red is the same hue, only lifted for the Ink page', () {
      expect(_hueGap(OColors.light.agent, OColors.dark.agent), lessThan(1.0));
      expect(_hue(OColors.light.agent), closeTo(358.1, 0.5));
      expect(
        OColors.dark.agent.computeLuminance(),
        greaterThan(OColors.light.agent.computeLuminance()),
      );
    });

    test('the palette file declares the four canonical hexes', () {
      final source = File('lib/ui/design/o_tokens.dart').readAsStringSync();
      for (final hex in <String>[
        '0xFFF4F1EA',
        '0xFF1B1B1B',
        '0xFFE5484D',
        '0xFF8A867D',
      ]) {
        expect(
          source.contains(hex),
          isTrue,
          reason: 'o_tokens.dart no longer declares $hex',
        );
      }
      // Exactly one base Signal Red and one documented dark lift.
      expect('agent: Color(0xFFE5484D)'.allMatches(source), hasLength(1));
      expect('agent: Color(0xFFFF6B6F)'.allMatches(source), hasLength(1));
    });

    test('both themes are first class and the device picks between them', () {
      expect(OTheme.light().extension<OColors>(), OColors.light);
      expect(OTheme.dark().extension<OColors>(), OColors.dark);
      expect(OColors.resolve(Brightness.light), OColors.light);
      expect(OColors.resolve(Brightness.dark), OColors.dark);
      // Device-following by default; anything unknown is also "follow".
      expect(OTheme.modeFor('system'), ThemeMode.system);
      expect(OTheme.modeFor('nonsense'), ThemeMode.system);
    });

    testWidgets('a context without a palette falls back to Paper', (
      tester,
    ) async {
      late OColors resolved;
      late Brightness brightness;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            resolved = OColors.of(context);
            brightness = OTheme.fallbackBrightness(context);
            return const SizedBox.shrink();
          },
        ),
      );
      expect(resolved, OColors.light);
      expect(brightness, Brightness.light);
    });

    test('Signal Red is never a status colour in the light theme', () {
      expect(OColors.light.danger.toARGB32(), isNot(signalRedHex));
      expect(OColors.light.success.toARGB32(), isNot(signalRedHex));
      expect(OColors.light.warn.toARGB32(), isNot(signalRedHex));
    });

    test('no new theme lets Signal Red double as danger/success/warn', () {
      final collisions = <String>{};
      for (final (label, colors) in <(String, OColors)>[
        ('light', OColors.light),
        ('dark', OColors.dark),
      ]) {
        for (final (name, color) in <(String, Color)>[
          ('danger', colors.danger),
          ('success', colors.success),
          ('warn', colors.warn),
        ]) {
          if (color.toARGB32() == colors.agent.toARGB32()) {
            collisions.add('$label/$name');
          }
        }
      }
      expect(
        collisions,
        isEmpty,
        reason:
            'Signal Red is the agent\'s colour only. Use `danger` for errors '
            'and destructive actions, never the agent token.',
      );
    });
  });

  group('contrast floors from the tokens', () {
    test('Ink on Paper clears AAA (>= 7:1)', () {
      final light = OContrast.ratio(OColors.light.text, OColors.light.bg);
      final dark = OContrast.ratio(OColors.dark.text, OColors.dark.bg);
      expect(light, greaterThanOrEqualTo(7.0));
      expect(dark, greaterThanOrEqualTo(7.0));
      // The canonical pairing, pinned: 15.27:1 light, 16.34:1 dark.
      expect(light, closeTo(15.27, 0.05));
      expect(dark, closeTo(16.34, 0.05));
    });

    test('Paper-on-Ink fills clear AAA (>= 7:1) in both themes', () {
      for (final (label, colors) in <(String, OColors)>[
        ('light', OColors.light),
        ('dark', OColors.dark),
      ]) {
        final ratio = OContrast.ratio(colors.onAccent, colors.accentFill);
        expect(ratio, greaterThanOrEqualTo(7.0), reason: label);
        expect(ratio, closeTo(15.27, 0.05), reason: label);
      }
    });

    test('Stone clears 4.5:1 on the page it is painted on', () {
      // On Paper the literal Stone is 3.22:1, so secondary text uses the
      // Stone step `textMuted` (#605C55). On the Ink page Stone itself is
      // 5.08:1 and is used directly.
      final onPaper = OContrast.ratio(
        OColors.light.textMuted,
        OColors.light.bg,
      );
      final onInk = OContrast.ratio(OColors.dark.textFaint, OColors.dark.bg);
      expect(onPaper, greaterThanOrEqualTo(4.5));
      expect(onPaper, closeTo(5.89, 0.05));
      expect(onInk, greaterThanOrEqualTo(4.5));
      expect(onInk, closeTo(5.08, 0.05));
      expect(OColors.dark.textFaint.toARGB32(), stoneHex);
    });

    test(
      'Stone on Paper is below the body floor, so it is never body text',
      () {
        const stone = Color(stoneHex);
        final ratio = OContrast.ratio(stone, OColors.light.bg);
        expect(ratio, closeTo(3.22, 0.05));
        expect(ratio, lessThan(4.5));
        // The light theme must keep the darkened Stone for text.
        expect(OColors.light.textMuted.toARGB32(), isNot(stoneHex));
        expect(OColors.light.textFaint.toARGB32(), isNot(stoneHex));
      },
    );

    test('Signal Red clears 3:1 as a graphic on both pages', () {
      final onPaper = OContrast.ratio(OColors.light.agent, OColors.light.bg);
      final onInk = OContrast.ratio(OColors.dark.agent, OColors.dark.bg);
      expect(onPaper, greaterThanOrEqualTo(3.0));
      expect(onPaper, closeTo(3.47, 0.05));
      expect(onInk, greaterThanOrEqualTo(3.0));
      expect(onInk, closeTo(6.66, 0.05));
    });
  });

  group('flat, no gradients and no glow', () {
    test('lib/ui/v2 paints no gradient and no shader mask', () {
      final found = <String>[];
      for (final file in _v2Files()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (_flatPaint.hasMatch(lines[i])) {
            found.add('${_relative(file)}:${i + 1} | ${lines[i].trim()}');
          }
        }
      }
      expect(
        found,
        isEmpty,
        reason: 'The palette is flat: ${found.join(', ')}',
      );
    });

    test('lib/ui/v2 paints no glow and no blurred shadow', () {
      final found = <String>[];
      for (final file in _v2Files()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (_glow.hasMatch(lines[i])) {
            found.add('${_relative(file)}:${i + 1} | ${lines[i].trim()}');
          }
        }
      }
      expect(found, isEmpty, reason: 'No glow or shadow: ${found.join(', ')}');
    });

    test('lib/ui/v2 never raises a material surface off the page', () {
      final found = <String>[];
      for (final file in _v2Files()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final match = _elevation.firstMatch(lines[i]);
          if (match == null) continue;
          final value = double.parse(match.group(1)!);
          if (value != 0) {
            found.add('${_relative(file)}:${i + 1} | ${lines[i].trim()}');
          }
        }
      }
      expect(found, isEmpty, reason: 'Flat surfaces only: ${found.join(', ')}');
    });
  });

  group('Signal Red is the agent\'s colour only', () {
    test(
      'the detector catches Signal Red on an error or destructive action',
      () {
        const cases = <String>[
          'Text(style: TextStyle(color: c.agent)), // error',
          'if (failed) Icon(Icons.error, color: c.agent),',
          'BoxDecoration(color: c.agent), // delete account',
          'danger: true,\ncolor: c.agent,',
          'const red = Color(0xFFE5484D); // destructive',
        ];
        for (final source in cases) {
          expect(
            findSignalRedMisuses(source, path: 'case.dart'),
            isNotEmpty,
            reason: 'Detector missed:\n$source',
          );
        }
      },
    );

    test('the detector allows the agent mark and agent-authored indicator', () {
      const cases = <String>[
        'if (agent) Icon(Icons.psychology_rounded, color: c.agent),',
        'final nameColor = agent ? c.agent : c.text;',
        'kind: V2CollabMessageKind.agent,',
        'Text("Ovid", style: OType.label.copyWith(color: c.agent)),',
      ];
      for (final source in cases) {
        expect(
          findSignalRedMisuses(source, path: 'case.dart'),
          isEmpty,
          reason: 'Detector false positive:\n$source',
        );
      }
    });

    test(
      'no v2 screen spends Signal Red on an error or a destructive action',
      () {
        final misuses = <String>[];
        for (final file in _v2Files()) {
          misuses.addAll(
            findSignalRedMisuses(
              file.readAsStringSync(),
              path: _relative(file),
            ),
          );
        }
        expect(
          misuses,
          isEmpty,
          reason:
              'Errors and destructive actions must use `danger`. Signal Red '
              '(`c.agent`) is the agent mark only:\n${misuses.join('\n')}',
        );
      },
    );

    test('no v2 screen re-declares Signal Red as a literal', () {
      final found = <String>[];
      for (final file in _v2Files()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (RegExp(r'Color\(0xFF(?:E5484D|FF6B6F)\)').hasMatch(lines[i]) ||
              RegExp(r'\bsignalRed\b').hasMatch(lines[i])) {
            found.add('${_relative(file)}:${i + 1} | ${lines[i].trim()}');
          }
        }
      }
      expect(found, isEmpty, reason: 'Use `c.agent`, never a copy: $found');
    });
  });
}
