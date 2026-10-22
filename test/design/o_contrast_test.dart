import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_contrast.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';

/// Pairings tracked as known, accepted gaps.
///
/// This map used to hold `dark/accentFill/onAccent` at 4.35:1 — white on the
/// old #7C5CFF violet fill, below the 4.5:1 body gate. The token was darkened
/// to #7857FA (4.62:1) so the gap is closed and the map is empty. Any new
/// entry here is a palette bug, not a documented exception.
const knownGaps = <String, double>{};

void main() {
  group('OContrast maths', () {
    test(
      'black on white is the maximum 21:1 and a colour against itself is 1:1',
      () {
        expect(
          OContrast.ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
          closeTo(21.0, 0.01),
        );
        expect(
          OContrast.ratio(const Color(0xFF000000), const Color(0xFF000000)),
          closeTo(1.0, 0.0001),
        );
        expect(
          OContrast.ratio(const Color(0xFFFFFFFF), const Color(0xFFFFFFFF)),
          closeTo(1.0, 0.0001),
        );
      },
    );

    test('ratio agrees with Color.computeLuminance for opaque colours', () {
      final pairs = <(Color, Color)>[
        (OColors.light.text, OColors.light.bg),
        (OColors.light.accentFill, OColors.light.onAccent),
        (OColors.dark.danger, OColors.dark.onDanger),
        (OColors.dark.textMuted, OColors.dark.surfaceRaised),
      ];
      for (final (fg, bg) in pairs) {
        final l1 = fg.computeLuminance();
        final l2 = bg.computeLuminance();
        final hi = l1 > l2 ? l1 : l2;
        final lo = l1 > l2 ? l2 : l1;
        expect(
          OContrast.ratio(fg, bg),
          closeTo((hi + 0.05) / (lo + 0.05), 1e-9),
        );
      }
    });

    test('translucent foregrounds are composited over the background', () {
      // Fully transparent text cannot be read at all.
      expect(
        OContrast.ratio(const Color(0x00FFFFFF), const Color(0xFF000000)),
        closeTo(1.0, 1e-9),
      );
      // 50 % white over black lands around 5.3:1.
      expect(
        OContrast.ratio(const Color(0x80FFFFFF), const Color(0xFF000000)),
        closeTo(5.32, 0.02),
      );

      final flattened = OContrast.compositeOver(
        const Color(0x80FFFFFF),
        const Color(0xFF000000),
      );
      expect(flattened.a, 1.0);
      expect(
        OContrast.ratio(flattened, const Color(0xFF000000)),
        closeTo(
          OContrast.ratio(const Color(0x80FFFFFF), const Color(0xFF000000)),
          1e-9,
        ),
      );
    });

    test('translucent backgrounds are flattened onto white', () {
      // 50 % black over white is the same as #7F7F7F.
      expect(
        OContrast.ratio(const Color(0xFF000000), const Color(0x80000000)),
        closeTo(
          OContrast.ratio(const Color(0xFF000000), const Color(0xFF7F7F7F)),
          1e-9,
        ),
      );
    });

    test('relative luminance uses the WCAG curve', () {
      expect(
        OContrast.relativeLuminance(const Color(0xFF000000)),
        closeTo(0.0, 1e-9),
      );
      expect(
        OContrast.relativeLuminance(const Color(0xFFFFFFFF)),
        closeTo(1.0, 1e-9),
      );
      expect(
        OContrast.relativeLuminance(const Color(0xFF808080)),
        closeTo(0.2158, 0.001),
      );
    });

    test('grade reports the WCAG bands', () {
      expect(OContrast.grade(21.0), 'AAA');
      expect(OContrast.grade(7.0), 'AAA');
      expect(OContrast.grade(6.99), 'AA');
      expect(OContrast.grade(4.5), 'AA');
      expect(OContrast.grade(4.49), 'AA large');
      expect(OContrast.grade(3.0), 'AA large');
      expect(OContrast.grade(2.99), 'Fail');
    });

    test('meets uses the tier minimum', () {
      const fg = Color(0xFF777777);
      const bg = Color(0xFFFFFFFF);
      final measured = OContrast.ratio(fg, bg);
      expect(measured, greaterThan(3.0));
      expect(measured, lessThan(4.5));
      expect(OContrast.meets(fg, bg, tier: OContrastTier.caption), isTrue);
      expect(OContrast.meets(fg, bg, tier: OContrastTier.graphic), isTrue);
      expect(OContrast.meets(fg, bg), isFalse);
    });
  });

  group('audit coverage', () {
    for (final (label, colors) in <(String, OColors)>[
      ('light', OColors.light),
      ('dark', OColors.dark),
    ]) {
      test('$label covers every pairing the brief calls out', () {
        final names = OContrast.audit(
          colors,
        ).map((check) => check.name).toSet();
        expect(
          names,
          containsAll(<String>[
            'text/bg',
            'textMuted/bg',
            'accentFill/onAccent',
            'danger/onDanger',
          ]),
        );
      });

      test('$label checks carry their tier minimum', () {
        for (final check in OContrast.audit(colors)) {
          expect(check.required, check.tier.minimum);
          expect(check.summary, contains(check.ratio.toStringAsFixed(2)));
        }
        expect(
          OContrast.audit(
            colors,
          ).where((check) => check.tier == OContrastTier.body),
          isNotEmpty,
        );
        expect(
          OContrast.audit(
            colors,
          ).where((check) => check.tier == OContrastTier.caption),
          isNotEmpty,
        );
      });
    }
  });

  for (final (label, colors) in <(String, OColors)>[
    ('light', OColors.light),
    ('dark', OColors.dark),
  ]) {
    group('$label palette', () {
      final checks = OContrast.audit(colors);

      test('every body pairing clears AA (4.5:1)', () {
        final failures = checks
            .where((check) => check.tier == OContrastTier.body)
            .where((check) => !check.passes)
            .where((check) => !knownGaps.containsKey('$label/${check.name}'))
            .map((check) => check.summary)
            .toList();
        expect(
          failures,
          isEmpty,
          reason: 'Body contrast below 4.5:1: $failures',
        );
      });

      test('every caption pairing clears AA-large (3:1)', () {
        final failures = checks
            .where((check) => check.tier == OContrastTier.caption)
            .where((check) => !check.passes)
            .map((check) => check.summary)
            .toList();
        expect(
          failures,
          isEmpty,
          reason: 'Caption contrast below 3:1: $failures',
        );
      });

      test('meaningful non-text UI clears 3:1', () {
        for (final check in checks.where(
          (check) => check.tier == OContrastTier.graphic,
        )) {
          expect(check.passes, isTrue, reason: check.summary);
        }
      });

      test('only tracked gaps fail their declared tier', () {
        final failed = checks
            .where((check) => !check.passes)
            .map((check) => '$label/${check.name}')
            .toSet();
        expect(
          knownGaps.keys.toSet().containsAll(failed),
          isTrue,
          reason: 'Untracked contrast failures: $failed',
        );
        for (final name in failed) {
          expect(knownGaps[name], isNotNull);
        }
      });
    });
  }

  group('palette contrast', () {
    test('dark primary button label clears AA body', () {
      final check = OContrast.audit(
        OColors.dark,
      ).firstWhere((check) => check.name == 'accentFill/onAccent');
      expect(check.ratio, closeTo(4.90, 0.05));
      expect(check.passes, isTrue);
      expect(check.grade, 'AA');
      // Regression floor: the fill must never drift back under the gate.
      expect(check.ratio, greaterThanOrEqualTo(4.5));
    });

    test('accent on the translucent accentSoft fill clears AA body', () {
      for (final (label, colors) in <(String, OColors)>[
        ('light', OColors.light),
        ('dark', OColors.dark),
      ]) {
        final check = OContrast.audit(
          colors,
        ).firstWhere((check) => check.name == 'accent/accentSoft');
        expect(check.ratio, greaterThanOrEqualTo(4.5), reason: label);
      }
    });

    test('status tints clear AA-large in both themes', () {
      for (final (label, colors) in <(String, OColors)>[
        ('light', OColors.light),
        ('dark', OColors.dark),
      ]) {
        for (final name in <String>[
          'success/successTint',
          'warn/warnTint',
          'danger/dangerTint',
        ]) {
          final check = OContrast.audit(
            colors,
          ).firstWhere((check) => check.name == name);
          expect(check.ratio, greaterThanOrEqualTo(3.0), reason: '$label/$name');
        }
      }
    });

    test('no light-theme pairing fails its declared tier', () {
      expect(
        OContrast.audit(OColors.light).where((check) => !check.passes),
        isEmpty,
      );
    });

    test('dark textFaint clears the caption floor on every surface', () {
      final checks = OContrast.audit(OColors.dark)
          .where((c) => c.name.startsWith('textFaint/'));
      for (final check in checks) {
        expect(check.passes, isTrue, reason: check.name);
      }
      final onSurface = OContrast.audit(
        OColors.dark,
      ).firstWhere((check) => check.name == 'textFaint/surface');
      expect(onSurface.ratio, closeTo(4.75, 0.05));
    });

    test(
      'brief-required pairs in both themes are reported with real numbers',
      () {
        final light = OContrast.audit(OColors.light);
        final dark = OContrast.audit(OColors.dark);

        OContrastCheck pick(List<OContrastCheck> checks, String name) =>
            checks.firstWhere((check) => check.name == name);

        // Paper/Ink palette: Ink on Paper is 15.27:1, Paper on Ink 16.34:1.
        expect(pick(light, 'text/bg').ratio, closeTo(15.27, 0.05));
        expect(pick(light, 'textMuted/bg').ratio, closeTo(5.89, 0.05));
        expect(pick(light, 'accentFill/onAccent').ratio, closeTo(4.90, 0.05));
        expect(pick(light, 'danger/onDanger').ratio, closeTo(5.49, 0.05));

        expect(pick(dark, 'text/bg').ratio, closeTo(16.34, 0.05));
        expect(pick(dark, 'textMuted/bg').ratio, closeTo(7.34, 0.05));
        expect(pick(dark, 'accentFill/onAccent').ratio, closeTo(4.90, 0.05));
        expect(pick(dark, 'danger/onDanger').ratio, closeTo(6.92, 0.05));
      },
    );
  });

  group('report', () {
    test('renders every check and reports the new fill', () {
      final report = OContrast.report(OColors.dark, label: 'dark');
      expect(report, contains('dark'));
      expect(report, contains('text/bg'));
      expect(report, contains('textMuted/bg'));
      expect(report, contains('accentFill/onAccent'));
      expect(report, contains('danger/onDanger'));
      expect(report, contains('4.90:1'));
      expect(report, isNot(contains('FAIL')));
    });

    test('light report is clean', () {
      final report = OContrast.report(OColors.light, label: 'light');
      expect(
        report,
        contains('All ${OContrast.audit(OColors.light).length} pairs meet'),
      );
      expect(report, isNot(contains('FAIL')));
    });

    test('reportAll covers both themes', () {
      final report = OContrast.reportAll();
      expect(report, contains('light'));
      expect(report, contains('dark'));
      expect('FAIL'.allMatches(report), isEmpty);
    });
  });
}
