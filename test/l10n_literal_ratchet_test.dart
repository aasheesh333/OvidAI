import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/l10n/l10n.dart';

/// Ratchet for hard-coded user-facing strings (F-111).
///
/// Each file below has been touched by the l10n rollout. Its count of raw
/// literals passed to Text(...) or to label/tooltip/title/message-style
/// parameters may only go DOWN: new copy must be added to lib/l10n/app_en.arb
/// and read through `context.l10n`. When you move strings out of a file,
/// lower its number here. Files not listed are not yet in the rollout.
const _baseline = <String, int>{
  'lib/main.dart': 1,
  'lib/l10n/l10n.dart': 0,
  'lib/ui/user_error.dart': 0,
  'lib/ui/widgets/error_views.dart': 0,
  'lib/ui/widgets/attachment_tiles.dart': 0,
  'lib/ui/schedule_screen.dart': 24,
  'lib/ui/providers_screen.dart': 53,
  'lib/ui/settings_screen.dart': 114,
  'lib/ui/settings_backup_screen.dart': 20,
};

final _literal = RegExp(
  r'''\bText\(\s*['"]|\b(?:label|tooltip|title|hintText|labelText|helperText|'''
  r'''message|helper|semanticsLabel|errorText|subtitle|eyebrow|content)'''
  r'''\s*:\s*['"]''',
);

/// A caught exception interpolated into copy (`'Failed: $e'`) leaks
/// `Bad state:`/type names to users; route it through friendlyError instead.
final _rawErrorInterpolation = RegExp(r'''\$e\b|\$\{e\}|\$\{e\.toString\(\)\}''');

void main() {
  group('hard-coded string ratchet', () {
    for (final entry in _baseline.entries) {
      test(entry.key, () {
        final source = File(entry.key).readAsStringSync();
        final count = _literal.allMatches(source).length;
        expect(
          count,
          lessThanOrEqualTo(entry.value),
          reason:
              '${entry.key} gained raw user-facing literals ($count > '
              '${entry.value}). Add new copy to lib/l10n/app_en.arb and use '
              'context.l10n.',
        );
      });
    }
  });

  test('touched files do not interpolate raw exceptions into copy', () {
    for (final path in _baseline.keys) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        expect(
          _rawErrorInterpolation.hasMatch(lines[i]),
          isFalse,
          reason: '$path:${i + 1}: ${lines[i].trim()}',
        );
      }
    }
  });

  test('every ARB message has a translator description', () {
    final arb =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    final keys = arb.keys.where((k) => !k.startsWith('@'));
    expect(keys, isNotEmpty);
    for (final key in keys) {
      final meta = arb['@$key'];
      expect(meta, isA<Map>(), reason: '@$key missing');
      expect(
        ((meta as Map)['description'] as String? ?? '').trim(),
        isNotEmpty,
        reason: '@$key needs a description',
      );
    }
  });

  test('MaterialApp in main.dart wires localization delegates', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(
      main,
      contains(
        'localizationsDelegates: AppLocalizations.localizationsDelegates',
      ),
    );
    expect(main, contains('supportedLocales: AppLocalizations.supportedLocales'));
    expect(AppLocalizations.supportedLocales, isNotEmpty);
    expect(
      AppLocalizations.localizationsDelegates,
      containsAll(<LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ]),
    );
  });

  testWidgets('app delegates resolve AppLocalizations and Material strings', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            captured = context;
            return Text(context.l10n.actionRetry);
          },
        ),
      ),
    );
    expect(AppLocalizations.of(captured), isNotNull);
    expect(MaterialLocalizations.of(captured).okButtonLabel, isNotEmpty);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('context.l10n falls back to English without delegates', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) => Text(context.l10n.actionRetry)),
      ),
    );
    expect(find.text('Retry'), findsOneWidget);
  });
}
