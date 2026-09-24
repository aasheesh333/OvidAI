import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Desktop mode previously spoofed only the User-Agent *string* and the
/// layout viewport. Modern sites (Softonic, etc.) ignore the UA string and
/// read Chromium's User-Agent Client Hints instead — `navigator.userAgentData
/// .mobile`, the `Sec-CH-UA-Mobile` / `Sec-CH-UA-Platform` request headers,
/// and JS touch probes (`navigator.maxTouchPoints`, `navigator.platform`,
/// coarse-pointer media queries). All of those stayed Android/mobile, so the
/// "switch to a desktop browser" gate fired even with desktop mode enabled.
///
/// Fix: the native WebView handler must set desktop `UserAgentMetadata` (the
/// source of the client-hint headers + `navigator.userAgentData`) and install
/// a document-start feature shim for desktop tabs only.
String _kotlinSource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt',
).readAsStringSync();

String _gradleSource() =>
    File('android/app/build.gradle.kts').readAsStringSync();

/// Returns the body of `private fun <name>(` up to the next top-level `fun`.
String _functionBody(String kotlin, String name) {
  final start = kotlin.indexOf('private fun $name(');
  expect(start, isNot(-1), reason: '$name must exist');
  final next = kotlin.indexOf('private fun ', start + 1);
  return kotlin.substring(start, next == -1 ? kotlin.length : next);
}

void main() {
  group('desktop User-Agent Client Hints', () {
    test('gradle puts androidx.webkit on the app compile classpath', () {
      final gradle = _gradleSource();
      // webview_flutter_android depends on webkit with `implementation`, which
      // is NOT transitive to this module's compile classpath — the app must
      // declare it explicitly to reference WebSettingsCompat/WebViewCompat.
      expect(gradle, contains('androidx.webkit:webkit'));
    });

    test('native handler sets UserAgentMetadata from WebSettingsCompat', () {
      final kotlin = _kotlinSource();
      expect(kotlin, contains('androidx.webkit.WebSettingsCompat'));
      expect(kotlin, contains('setUserAgentMetadata'));
      expect(kotlin, contains('UserAgentMetadata.Builder'));
      expect(kotlin, contains('WebViewFeature.USER_AGENT_METADATA'));
    });

    test('desktop metadata is non-mobile on Windows; mobile stays Android',
        () {
      final kotlin = _kotlinSource();
      final desktop = _functionBody(kotlin, 'desktopMetadata');
      expect(
        desktop,
        matches(RegExp(r'setMobile\(\s*false\s*\)')),
        reason: 'desktop client hints must report mobile=false',
      );
      expect(desktop, contains('"Windows"'));

      final mobile = _functionBody(kotlin, 'mobileMetadata');
      expect(
        mobile,
        matches(RegExp(r'setMobile\(\s*true\s*\)')),
        reason: 'mobile client hints must report mobile=true',
      );
      expect(mobile, contains('"Android"'));
    });

    test('native handler installs a document-start shim, desktop only', () {
      final kotlin = _kotlinSource();
      expect(kotlin, contains('WebViewCompat.addDocumentStartJavaScript'));
      expect(kotlin, contains('WebViewFeature.DOCUMENT_START_SCRIPT'));
      final shim = _functionBody(kotlin, 'applyFeatureShim');
      // Mobile must remove any installed shim rather than register one.
      expect(shim, matches(RegExp(r'if\s*\(!desktop\)')));
      expect(shim, contains('removeFeatureShim'));
    });

    test('shim neutralizes touch + platform + userAgentData signals', () {
      final kotlin = _kotlinSource();
      final shim = _functionBody(kotlin, 'applyFeatureShim');
      // The script body may live in a const; search the whole file for the
      // overrides the shim injects.
      expect(kotlin, contains('maxTouchPoints'));
      expect(kotlin, contains('Win32'));
      expect(kotlin, contains('userAgentData'));
      expect(kotlin, contains('pointer'));
      expect(shim, contains('desktopFeatureShim'));
    });

    test('shim dimensions are parameterized, not hardcoded 1280x800', () {
      final kotlin = _kotlinSource();
      final gen = _functionBody(kotlin, 'desktopFeatureShim');
      expect(gen, contains('width: Int'));
      expect(gen, contains('height: Int'));
      expect(gen, contains('return \$width;'));
      expect(gen, contains('return \$height;'));
      // No hardcoded desktop dimensions left in the generated getters.
      expect(gen, isNot(contains('return 1280;')));
      expect(gen, isNot(contains('return 800;')));
    });

    test('feature shim re-installs when the forced size changes', () {
      final kotlin = _kotlinSource();
      final shim = _functionBody(kotlin, 'applyFeatureShim');
      // Dimension-aware dedupe: same size ⇒ keep, different size ⇒ reinstall.
      expect(shim, contains('existing.first == w'));
      expect(shim, contains('existing.second == h'));
    });
  });
}
