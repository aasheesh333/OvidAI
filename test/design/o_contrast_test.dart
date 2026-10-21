import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_contrast.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';

/// Pairings tracked as known, accepted gaps. The design brief asks us not to
/// touch the shared palette, so these are pinned here and reported instead of
/// silently excluded.
///
/// * `dark/accentFill/onAccent` is 4.35:1: white on the dark violet fill is
///   below the 4.5:1 body gate (it is exactly why `o_theme_test` used 4.3).
/// Delete this entry once the palette is adjusted.
const knownGaps = <String, double>{'dark/accentFill/onAccent': 4.35};

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

  group('known palette gaps', () {
    test('dark primary button label is 4.35:1 - below AA body', () {
      final check = OContrast.audit(
        OColors.dark,
      ).firstWhere((check) => check.name == 'accentFill/onAccent');
      expect(
        check.ratio,
        closeTo(knownGaps['dark/accentFill/onAccent']!, 0.05),
      );
      expect(check.passes, isFalse);
      expect(check.grade, 'AA large');
      // Regression floor: it must not get worse while the palette is shared.
      expect(check.ratio, greaterThanOrEqualTo(4.3));
    });

    test('no light-theme pairing fails its declared tier', () {
      expect(
        OContrast.audit(OColors.light).where((check) => !check.passes),
        isEmpty,
      );
    });

    test('dark textFaint clears AA-large but not AA body (captions only)', () {
      final check = OContrast.audit(
        OColors.dark,
      ).firstWhere((check) => check.name == 'textFaint/surface');
      expect(check.passes, isTrue);
      expect(check.passesStrictBody, isFalse);
      expect(check.ratio, closeTo(3.73, 0.05));
    });

    test(
      'brief-required pairs in both themes are reported with real numbers',
      () {
        final light = OContrast.audit(OColors.light);
        final dark = OContrast.audit(OColors.dark);

        OContrastCheck pick(List<OContrastCheck> checks, String name) =>
            checks.firstWhere((check) => check.name == name);

        expect(pick(light, 'text/bg').ratio, closeTo(17.48, 0.05));
        expect(pick(light, 'textMuted/bg').ratio, closeTo(6.27, 0.05));
        expect(pick(light, 'accentFill/onAccent').ratio, closeTo(5.79, 0.05));
        expect(pick(light, 'danger/onDanger').ratio, closeTo(4.83, 0.05));

        expect(pick(dark, 'text/bg').ratio, closeTo(19.28, 0.05));
        expect(pick(dark, 'textMuted/bg').ratio, closeTo(7.60, 0.05));
        expect(pick(dark, 'accentFill/onAccent').ratio, closeTo(4.35, 0.05));
        expect(pick(dark, 'danger/onDanger').ratio, closeTo(6.62, 0.05));
      },
    );
  });

  group('report', () {
    test('renders every check and flags failures', () {
      final report = OContrast.report(OColors.dark, label: 'dark');
      expect(report, contains('dark'));
      expect(report, contains('text/bg'));
      expect(report, contains('textMuted/bg'));
      expect(report, contains('accentFill/onAccent'));
      expect(report, contains('danger/onDanger'));
      expect(report, contains('FAIL'));
      expect(report, matches(RegExp(r'\d+ of \d+ pairs fail')));
      expect(report, contains('4.35:1'));
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
      expect('FAIL'.allMatches(report), hasLength(1));
    });
  });
}
