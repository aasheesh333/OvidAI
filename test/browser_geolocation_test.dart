import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/agent_service.dart';

/// Browser geolocation bridge (2026-09-29).
///
/// THE GAP. webview_flutter_android surfaces no geolocation prompt at all: its
/// `PermissionRequestConstants` are audio capture, MIDI sysex, video capture and
/// protected media only, because Android delivers location through
/// `WebChromeClient.onGeolocationPermissionsShowPrompt` — and this app must not
/// install its own WebChromeClient (the plugin's file chooser, JS dialogs and
/// console bridge hang off it). So `navigator.geolocation.getCurrentPosition`
/// never answered: no success callback, no error callback, no timeout. Pages with
/// a location-gated login just hung, and `browser_console` had nothing to show.
///
/// THE FIX. A per-document JS shim routes every request through an
/// `OvidGeolocation` channel to Dart, which checks `Permission.locationWhenInUse`
/// and reads a CACHED native fix (`locationFix` → `getLastKnownLocation`), then
/// answers `window.__ovidGeoReply(id, payload)`.
///
/// These are pure-function and source-pin tests on purpose: the interesting
/// failures are a wrong W3C error code (a page retries forever on code 2 but
/// stops on code 1), a shim that stops being installed (silent hang again), and a
/// native side that starts a location stream for a web page (radio on, battery
/// drained from inside a login flow). None of those need a real WebView, and a
/// test that needed one would be the first thing skipped when it got flaky.
void main() {
  final agentSrc = File('lib/core/agent_service.dart').readAsStringSync();
  final handlerSrc = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt',
  ).readAsStringSync();

  group('native fix → page payload', () {
    test('an available fix becomes a W3C position payload', () {
      final p = AgentService.geoPayloadFromFix({
        'available': true,
        'lat': 12.9716,
        'lon': 77.5946,
        'accuracy': 24.5,
        'ageMs': 1500,
      });
      expect(p['ok'], isTrue);
      expect(p['lat'], 12.9716);
      expect(p['lon'], 77.5946);
      expect(p['accuracy'], 24.5);
      expect(p['ageMs'], 1500);
      // No error code on a success payload: the shim tests `ok` first, and a
      // stray `code` would invite a page to branch on it.
      expect(p.containsKey('code'), isFalse);
    });

    test('a refused permission is code 1, never code 2', () {
      // This distinction is the whole point of the mapper. PERMISSION_DENIED
      // makes a page stop and show its own fallback; POSITION_UNAVAILABLE makes
      // it retry forever — the same hang the shim exists to remove.
      final p = AgentService.geoPayloadFromFix(const {}, denied: true);
      expect(p['ok'], isFalse);
      expect(p['code'], 1);
      expect(p['message'], isNotEmpty);
    });

    test('a missing fix is code 2 and keeps the native reason', () {
      final noFix = AgentService.geoPayloadFromFix(const {
        'available': false,
        'reason': 'no fix',
      });
      expect(noFix['ok'], isFalse);
      expect(noFix['code'], 2);
      expect(noFix['message'], 'no fix');

      final noService = AgentService.geoPayloadFromFix(const {
        'available': false,
        'reason': 'no location service',
      });
      expect(noService['message'], contains('location service'));

      // No `available` key at all — the native side answered something
      // unexpected. Still an honest failure, never a crash and never a
      // half-formed position.
      final odd = AgentService.geoPayloadFromFix(const {'lat': 1.0, 'lon': 2.0});
      expect(odd['ok'], isFalse);
      expect(odd['code'], 2);
    });

    test('available-without-coordinates fails instead of sending NaN', () {
      final p = AgentService.geoPayloadFromFix(const {'available': true});
      expect(p['ok'], isFalse);
      expect(p['code'], 2);
      expect(p['message'], contains('malformed'));
    });

    test('ints from the platform become the numeric types the shim expects', () {
      // Kotlin Long/Int cross the channel as int. The shim only accepts a
      // numeric `accuracy` (`typeof … === 'number'`), so a String here would
      // silently zero the page's accuracy instead of reporting it.
      final p = AgentService.geoPayloadFromFix(const {
        'available': true,
        'lat': 10,
        'lon': 20,
        'accuracy': 30,
        'ageMs': 40,
      });
      expect(p['lat'], isA<double>());
      expect(p['lon'], isA<double>());
      expect(p['accuracy'], isA<double>());
      expect(p['ageMs'], isA<int>());
    });
  });

  group('the reply script', () {
    test('it targets the shim callback with the request id', () {
      final js = AgentService.geoReplyJs(7, {'ok': true, 'lat': 1.5});
      expect(js, startsWith('window.__ovidGeoReply && '));
      expect(js, contains('__ovidGeoReply(7,'));
      expect(js, contains('"lat":1.5'));
    });

    test('a </script>-shaped value is left inert (defence in depth)', () {
      // NOT the HTML hazard this test's old name implied: the script goes out via
      // runJavaScript, which evaluates JS directly, so no parser can be tricked
      // into closing a context. The escape is still worth pinning — `message`
      // comes from the device (a provider name, an error string) so it is not
      // ours to sanitise, and the same text also lands in console logs and the
      // transcript, where staying inert still matters.
      final js = AgentService.geoReplyJs(1, const {
        'ok': false,
        'code': 2,
        'message': '</script><img src=x>',
      });
      expect(js, isNot(contains('</script>')));
      expect(js, contains(r'\u003c'));
    });
  });

  group('the document shim', () {
    final shim = AgentService.geolocationShimJs;

    test('it installs once per document and replaces all three methods', () {
      expect(shim, contains('__ovidGeoInstalled'));
      for (final m in ['getCurrentPosition', 'watchPosition', 'clearWatch']) {
        expect(shim, contains(m), reason: 'the shim must override $m');
      }
    });

    test('it reaches the Dart bridge and can receive the answer', () {
      expect(shim, contains('OvidGeolocation.postMessage'));
      expect(shim, contains('window.__ovidGeoReply = function'));
      expect(shim, contains('JSON.stringify'));
    });

    test('it can never hang — every failure path calls the error callback', () {
      // The exact bug being fixed. Each of these has to reach `error`; a path
      // that returns silently is a page waiting forever.
      expect(shim, contains('Geolocation unavailable in this browser'));
      expect(shim, contains('Geolocation bridge failed'));
      expect(shim, contains('Timed out waiting for a position'));
      expect(shim, contains('setTimeout'));
      // …and the page's own `timeout` option is honoured, not ignored.
      expect(shim, contains('options.timeout'));
    });

    test('it uses the W3C error codes pages branch on', () {
      expect(shim, contains('PERMISSION_DENIED = 1'));
      expect(shim, contains('POSITION_UNAVAILABLE = 2'));
      expect(shim, contains('TIMEOUT = 3'));
    });

    test('the timestamp is honest about a cached fix', () {
      // Only a LAST-KNOWN fix is ever read, so reporting Date.now() would tell
      // the page the position is fresher than it is — which is exactly what a
      // fraud check is comparing.
      expect(shim, contains('Date.now() - (payload.ageMs || 0)'));
    });

    test('a watch settles once and never fabricates movement', () {
      expect(shim, contains('watch: !!watch'));
      // One-shot requests are dropped after answering; a watch stays registered
      // so clearWatch still works — but nothing re-fires it.
      expect(shim, contains('if (!entry.watch) delete pending[id];'));
      expect(shim, isNot(contains('setInterval')));
    });

    test('it degrades instead of throwing when navigator is frozen', () {
      expect(shim, contains('Object.defineProperty(navigator'));
      expect(shim, contains('if (navigator.geolocation)'));
    });
  });

  group('wiring pins — a detached shim is a silent hang again', () {
    test('the bridge channel is registered with the controller', () {
      expect(agentSrc, contains("'OvidGeolocation'"));
      expect(agentSrc, contains('_onGeoRequest(tab, msg.message)'));
    });

    test('the shim is injected from onPageFinished, not once per tab', () {
      final finished = agentSrc.indexOf('onPageFinished: (url) async {');
      final inject = agentSrc.indexOf('runJavaScript(geolocationShimJs)');
      expect(finished, greaterThan(-1));
      expect(inject, greaterThan(-1));
      expect(
        inject,
        greaterThan(finished),
        reason:
            'a fresh document has a fresh navigator, so a one-time install '
            'would leave every later navigation hanging',
      );
    });

    test('the native side answers locationFix from a cached fix only', () {
      expect(agentSrc, contains("'locationFix'"));
      expect(handlerSrc, contains('"locationFix"'));
      expect(handlerSrc, contains('getLastKnownLocation'));
      // Never start a location stream on behalf of a web page: that switches on
      // a radio and keeps it awake from inside somebody's login flow. Pinned on
      // the CALL form, so the explanatory comment that names the API neither
      // satisfies nor breaks the check.
      expect(handlerSrc, isNot(contains('.requestLocationUpdates(')));
      expect(handlerSrc, isNot(contains('.requestSingleUpdate(')));
      expect(handlerSrc, isNot(contains('FusedLocationProviderClient')));
    });

    test('the native side re-checks permission itself', () {
      // Dart owns the dialog, but this is the layer JS cannot reach around: a
      // page must never widen what Ovid itself was granted.
      expect(handlerSrc, contains('ACCESS_FINE_LOCATION'));
      expect(handlerSrc, contains('ACCESS_COARSE_LOCATION'));
      expect(handlerSrc, contains('PERMISSION_GRANTED'));
    });

    test('picks the NEWEST cached fix, not the first provider that answered', () {
      expect(handlerSrc, contains('newestIndex'));
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android.permission.ACCESS_FINE_LOCATION'));
      expect(manifest, contains('android.permission.ACCESS_COARSE_LOCATION'));
    });

    test('the OS dialog is raised only while the user is browsing', () {
      // Same discipline as the camera/mic handler above it: a modal mid-run
      // stalls the agent, so the page gets PERMISSION_DENIED instead.
      final start = agentSrc.indexOf('Future<void> _onGeoRequest(');
      expect(start, greaterThan(-1));
      final body = agentSrc.substring(start, start + 4000);
      expect(body, contains('Permission.locationWhenInUse'));
      expect(body, contains('!busy && !browserBusy'));
      expect(body, contains('geoPayloadFromFix(const {}, denied: true)'));
    });

    test('the decision is visible to the agent and the user', () {
      final start = agentSrc.indexOf('Future<void> _onGeoRequest(');
      final body = agentSrc.substring(start, start + 4000);
      // Without this a location-gated login fails and browser_console shows
      // nothing — the agent would be left guessing.
      expect(body, contains("_emit('browser'"));
      expect(body, contains('tab.consoleLog.add'));
    });
  });
}
