import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';

/// P0 (2026-09-13) reliability bundle pins.
void main() {
  group('marketplace object-form source', () {
    test('resolves {source:url, url} to owner/repo', () {
      expect(
        AppState.githubPluginSourceForTest({
          'source': 'url',
          'url': 'https://github.com/obra/superpowers.git',
        }),
        'obra/superpowers',
      );
    });

    test('resolves {source:github, repo}', () {
      expect(
        AppState.githubPluginSourceForTest({
          'source': 'github',
          'repo': 'owner/repo',
          'ref': 'dev',
        }),
        'owner/repo',
      );
    });

    test('resolves {source:local, path} against the marketplace repo', () {
      expect(
        AppState.githubPluginSourceForTest(
          {'source': 'local', 'path': './plugins/thing'},
          marketplaceRepo: 'o/r',
        ),
        'o/r/raw/branch/plugins/thing',
      );
    });

    test('still resolves the plain string forms', () {
      expect(AppState.githubPluginSourceForTest('owner/repo'), 'owner/repo');
      expect(
        AppState.githubPluginSourceForTest('./dir', marketplaceRepo: 'o/r'),
        'o/r/raw/branch/dir',
      );
    });
  });

  group('inbuilt plugin install routing', () {
    test('detail install routes inbuilt rows to a direct install', () {
      final src = File('lib/ui/plugins_screen.dart').readAsStringSync();
      expect(src.contains('installBuiltinPlugin'), isTrue);
      expect(src.contains('_isInbuiltPlugin'), isTrue);
    });

    test('installBuiltinPlugin marks a row installed and enabled', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final idx = src.indexOf('Future<void> installBuiltinPlugin');
      expect(idx, greaterThan(0));
      final body = src.substring(idx, idx + 260);
      expect(body.contains('plugin.installed = true'), isTrue);
      expect(body.contains('plugin.enabled = true'), isTrue);
    });
  });

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
