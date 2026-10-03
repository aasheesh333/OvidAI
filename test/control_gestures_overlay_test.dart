import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

/// Owner-reported control/browser/overlay work (2026-09-25).
///
/// Four complaints, each traced to a concrete cause:
///
/// 1. **"Full human gestures should work in control mode too."** Only tap,
///    swipe, long-press and node-scroll existed. A double-click could not be
///    produced at all: two `device_tap` calls arrive as two unrelated
///    `dispatchGesture` invocations, so the platform double-tap timeout never
///    sees them as one gesture. Multi-stroke gestures are now sent as ONE
///    `GestureDescription`.
///
/// 2. **"The agent cannot see the keyboard."** `readScreen` walked exactly one
///    root, and `findTargetRootNode()` filters to `TYPE_APPLICATION`. The soft
///    keyboard is a separate `TYPE_INPUT_METHOD` window owned by another
///    process, so every key was invisible and coordinate taps into it were
///    guesses.
///
/// 3. **"Control mode is very slow."** Every action paid for a full `readRaw()`
///    tree walk first, purely to learn the foreground package. On an animated
///    screen the node cache is dirty on every content-change event, so that was
///    a 300-node binder walk on the main thread ahead of each tap — and it
///    serialized against the action itself, both being `@Synchronized`.
///
/// 4. **Overlay**: a small draggable circle clamped inside the display (the old
///    pill could be dragged off-screen and lost), an expanded white box, and an
///    edge glow coloured by run state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agentSrc = File('lib/core/agent_service.dart').readAsStringSync();
  final kotlinSrc = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
  ).readAsStringSync();
  final activitySrc = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
  ).readAsStringSync();

  group('control mode: full human gesture set', () {
    const gestures = [
      'device_double_tap',
      'device_drag',
      'device_pinch',
      'device_two_finger_swipe',
    ];

    for (final tool in gestures) {
      test('$tool is declared, gated to Control mode, and handled', () {
        expect(agentSrc, contains("'name': '$tool'"), reason: 'tool schema');
        // Gated: subagents and non-Control sessions must be refused.
        final gate = agentSrc.indexOf("return 'DENIED: Subagents cannot control");
        expect(gate, greaterThan(-1));
        final gateBlock = agentSrc.substring(gate - 900, gate);
        expect(gateBlock, contains("case '$tool':"));
        // Handled, not just declared.
        expect(agentSrc, contains("case '$tool':"));
      });
    }

    // The gesture primitives live in Api24Actions; the service-level methods of
    // the same name only validate and delegate. Searching from the top of the
    // file finds the delegate and proves nothing.
    final primitives = kotlinSrc.indexOf('private object Api24Actions');

    test('a multi-tap is ONE gesture, not N separate dispatches', () {
      // The whole point: two dispatchGesture calls never read as a double-click.
      expect(primitives, greaterThan(-1));
      final multi = kotlinSrc.indexOf('fun multiTap(', primitives);
      expect(multi, greaterThan(-1));
      final body = kotlinSrc.substring(multi, multi + 900);
      expect(body, contains('GestureDescription.Builder()'));
      expect(
        body.indexOf('addStroke'),
        lessThan(body.indexOf('dispatchGesture')),
        reason: 'every stroke must be added before the single dispatch',
      );
      expect(
        RegExp(r'dispatchGesture').allMatches(body).length,
        1,
        reason: 'one dispatch, or the platform sees unrelated taps',
      );
    });

    test('a drag holds at the origin before moving', () {
      // Without the dwell, an icon pick-up or a selection handle becomes a
      // fling and the target app treats it as a scroll.
      expect(kotlinSrc, contains('fun drag('));
      final drag = kotlinSrc.indexOf('fun drag(', primitives);
      final body = kotlinSrc.substring(drag, drag + 1400);
      expect(body, contains('continueStroke'), reason: 'API 26+ hold-then-move');
      expect(body, contains('Build.VERSION_CODES.O'), reason: 'guarded for 23-25');
    });

    test('pinch and two-finger swipe use two parallel strokes', () {
      for (final fn in ['fun pinch(', 'fun twoFingerSwipe(']) {
        final i = kotlinSrc.indexOf(fn, primitives);
        expect(i, greaterThan(-1), reason: fn);
        final body = kotlinSrc.substring(i, i + 1200);
        expect(
          RegExp(r'addStroke').allMatches(body).length,
          2,
          reason: '$fn needs exactly two fingers',
        );
      }
    });

    test('every gesture reaches the native side over the channel', () {
      for (final m in [
        'deviceMultiTap',
        'deviceDrag',
        'devicePinch',
        'deviceTwoFingerSwipe',
      ]) {
        expect(activitySrc, contains('"$m"'), reason: '$m handler');
      }
    });
  });

  group('control mode: the keyboard is visible', () {
    test('the IME window is walked alongside the app window', () {
      expect(kotlinSrc, contains('TYPE_INPUT_METHOD'));
      expect(kotlinSrc, contains('private fun imeRoot()'));
      final read = kotlinSrc.indexOf('fun readScreen(');
      expect(read, greaterThan(-1));
      final body = kotlinSrc.substring(read, read + 6000);
      expect(
        body,
        contains('imeRoot()'),
        reason: 'readScreen must consult the IME window',
      );
    });

    test('the IME cannot crowd out the app tree', () {
      // Keyboards expose 40-80 key nodes; uncapped they would push the screen
      // the agent is actually driving out of the dump.
      expect(kotlinSrc, contains('IME_NODE_BUDGET'));
      expect(kotlinSrc, contains('softCap'));
      final read = kotlinSrc.indexOf('fun readScreen(');
      final body = kotlinSrc.substring(read, read + 6000);
      expect(body, contains('softCap = (rows.size + IME_NODE_BUDGET)'));
      expect(
        body.indexOf('softCap = (rows.size + IME_NODE_BUDGET)'),
        greaterThan(body.indexOf('visit(root, 0)')),
        reason: 'the app tree must be visited first',
      );
    });

    test("Ovid's own overlay is never read back as the keyboard", () {
      final i = kotlinSrc.indexOf('private fun imeRoot()');
      final body = kotlinSrc.substring(i, i + 900);
      expect(body, contains('myPkg'), reason: 'own package is skipped');
    });
  });

  group('control mode: latency', () {
    test('the per-action guard no longer walks the tree', () {
      final handler = agentSrc.indexOf('Future<String> _handleDeviceControlTool');
      expect(handler, greaterThan(-1));
      final body = agentSrc.substring(handler, handler + 4000);
      expect(
        body,
        contains('device.foregroundPackage()'),
        reason: 'the sensitive-target guard needs only the package name',
      );
      // The expensive pre-action read must be gone from this path.
      expect(body, isNot(contains('final metadata = await device.readRaw()')));
    });

    test('a cheap foreground probe exists end to end', () {
      expect(kotlinSrc, contains('internal fun foregroundPackage()'));
      final probe = kotlinSrc.indexOf('internal fun foregroundPackage()');
      final body = kotlinSrc.substring(probe, probe + 700);
      expect(body, contains('rootInActiveWindow'));
      expect(
        body,
        isNot(contains('getChild(')),
        reason: 'reading one node package must not walk children',
      );
      expect(activitySrc, contains('"deviceForegroundPackage"'));
    });

    test('device_read gets a spill cap big enough to keep the middle', () {
      // A 300-node dump is 15-60 KB; the old 6000-char cap handed the model the
      // head and tail and dropped the middle, so it re-read in a loop.
      expect(agentSrc, contains('_toolOutputCapFor'));
      expect(agentSrc, contains("'device_read' => 24000"));
    });
  });

  group('overlay: draggable circle, clamped inside the display', () {
    test('drag coordinates are clamped, never written raw', () {
      final i = kotlinSrc.indexOf('overlayDragTouchListener');
      expect(i, greaterThan(-1));
      final body = kotlinSrc.substring(i, i + 3000);
      expect(body, contains('coerceIn'), reason: 'clamp on every move');
      expect(body, contains('displaySize('));
      // Raw coordinates must not reach the layout params unchecked.
      expect(
        body,
        isNot(contains('params.x = event.rawX.toInt() + origin[0]\n')),
      );
    });

    test('the window is re-clamped on expand and on rotation', () {
      expect(kotlinSrc, contains('clampOverlayIntoDisplay()'));
      expect(kotlinSrc, contains('override fun onConfigurationChanged'));
      final expand = kotlinSrc.indexOf('private fun setOverlayExpanded');
      final body = kotlinSrc.substring(expand, expand + 900);
      expect(
        body,
        contains('clampOverlayIntoDisplay'),
        reason: 'the box is a different size than the circle',
      );
    });

    test('a tap is distinguished from a drag', () {
      final i = kotlinSrc.indexOf('overlayDragTouchListener');
      final body = kotlinSrc.substring(i, i + 3000);
      expect(body, contains('getLongPressTimeout'));
      expect(body, contains('Math.hypot'), reason: 'movement threshold');
      expect(body, contains('onTap()'));
    });

    test('the box is white with cross, text, mic and a green send', () {
      final i = kotlinSrc.indexOf('private fun overlayBoxView');
      expect(i, greaterThan(-1));
      final body = kotlinSrc.substring(i, i + 9000);
      expect(body, contains('0xFFFFFFFF'), reason: 'simple white surface');
      expect(body, contains('ic_menu_close_clear_cancel'), reason: 'cross');
      expect(body, contains('ic_btn_speak_now'), reason: 'mic');
      expect(body, contains('ic_menu_send'), reason: 'send');
      expect(body, contains('0xFF1FA05F'), reason: 'green when armed');
      expect(
        body,
        contains('isEnabled = armed'),
        reason: 'an empty field must never send',
      );
    });
  });

  group('overlay: edge glow reports run state', () {
    test('Dart drives the colour from the single approval setter', () {
      // Hooked in `set pendingApproval`, not at each prompt site, so a new
      // prompt path cannot forget it.
      final i = agentSrc.indexOf('set pendingApproval(ApprovalRequest? v) {');
      expect(i, greaterThan(-1));
      final body = agentSrc.substring(i, i + 900);
      expect(body, contains('overlayStatePermission'));
      expect(body, contains('overlayStateRunning'));
      expect(agentSrc, contains('setOverlayState(overlayStateError)'));
    });

    test('errors only recolour the glow while a run is live', () {
      final i = agentSrc.indexOf('void _emitToRun(');
      final body = agentSrc.substring(i, i + 2500);
      expect(body, contains('run.activeRunId != null'));
      expect(body, contains('overlayStateError'));
    });
  });

  group('browser: real gesture tools', () {
    const tools = [
      'browser_double_click',
      'browser_tap_at',
      'browser_long_press',
      'browser_swipe',
    ];

    for (final tool in tools) {
      test('$tool is declared, handled and denied in read-only mode', () {
        expect(agentSrc, contains("'name': '$tool'"));
        expect(agentSrc, contains("case '$tool':"));
        final ro = agentSrc.indexOf('// Page interactions can submit forms');
        expect(ro, greaterThan(-1));
        final roBlock = agentSrc.substring(ro - 2500, ro);
        expect(roBlock, contains("case '$tool':"));
      });
    }

    test('a double-click increments detail and fires dblclick', () {
      final i = agentSrc.indexOf("case 'browser_double_click':");
      final body = agentSrc.substring(i, i + 2500);
      expect(body, contains('detail:i'));
      expect(body, contains("'dblclick'"));
    });

    test('a tap dispatches pointer, touch AND mouse phases', () {
      final i = agentSrc.indexOf('static String _humanTapJs');
      expect(i, greaterThan(-1));
      final body = agentSrc.substring(i, i + 2000);
      expect(body, contains('PointerEvent'));
      expect(body, contains('TouchEvent'));
      expect(body, contains('MouseEvent'));
      expect(body, contains("pointerType:'touch'"));
      expect(body, contains('elementFromPoint'));
    });

    test('a long-press holds for real elapsed time across two evaluations', () {
      // Faking the duration inside one synchronous script fires down and up
      // with nothing between them — and elapsed time is what the handler
      // measures.
      final i = agentSrc.indexOf("case 'browser_long_press':");
      final body = agentSrc.substring(i, i + 5000);
      final down = body.indexOf('runJavaScriptReturningResult(lpDown)');
      final delay = body.indexOf('Future<void>.delayed');
      final up = body.indexOf('runJavaScriptReturningResult(lpUp)');
      expect(down, greaterThan(-1));
      expect(delay, greaterThan(down));
      expect(up, greaterThan(delay));
    });

    test('a swipe interpolates move frames with touch pointer type', () {
      final i = agentSrc.indexOf("case 'browser_swipe':");
      final body = agentSrc.substring(i, i + 3500);
      expect(body, contains("pointerType:'touch'"));
      expect(body, contains('touchmove'));
      expect(body, contains('swSteps'));
    });
  });

  group('sign-in: providers that reject embedded browsers', () {
    test('Google, Microsoft, Apple, Facebook, LinkedIn and X are named', () {
      expect(externalSignInProvider('https://accounts.google.com/signin'), 'Google');
      expect(
        externalSignInProvider('https://login.microsoftonline.com/common/oauth2'),
        'Microsoft',
      );
      expect(externalSignInProvider('https://appleid.apple.com/auth/authorize'), 'Apple');
      expect(externalSignInProvider('https://www.facebook.com/login.php'), 'Facebook');
      expect(externalSignInProvider('https://www.linkedin.com/login'), 'LinkedIn');
      expect(externalSignInProvider('https://x.com/i/flow/login'), 'X');
    });

    test('subdomains match, suffix spoofs do not', () {
      expect(
        externalSignInProvider('https://mail.accounts.google.com/x'),
        'Google',
      );
      expect(
        externalSignInProvider('https://accounts.google.com.evil.example/'),
        isNull,
        reason: 'a dot-boundary match only',
      );
      expect(externalSignInProvider('https://notgoogle.com/'), isNull);
    });

    test('ordinary browsing is untouched', () {
      expect(externalSignInProvider('https://github.com/aasheesh333/OvidAI'), isNull);
      expect(externalSignInProvider('https://example.com/'), isNull);
      expect(externalSignInProvider('not a url'), isNull);
      expect(externalSignInProvider(''), isNull);
      expect(isExternalSignInUrl('https://github.com/login'), isFalse);
    });

    // Navigation and explicit external opening are exercised by
    // browser_external_signin_test.dart; proactive sign-in tips were retired.
  });

  group('screenshots and recents are no longer blocked', () {
    test('FLAG_SECURE is gone from every layer', () {
      expect(kotlinSrc, isNot(contains('FLAG_SECURE')));
      expect(activitySrc, isNot(contains('FLAG_SECURE')));
      final state = File('lib/core/state.dart').readAsStringSync();
      expect(state, isNot(contains('secureScreen')));
      final settings = File('lib/ui/settings_screen.dart').readAsStringSync();
      expect(settings, isNot(contains('Block screenshots')));
    });
  });

  group('gesture bridges are wired', () {
    test('the Dart bridge exposes every new gesture', () {
      final bridge = File(
        'lib/core/device_control_service.dart',
      ).readAsStringSync();
      for (final m in [
        'Future<Object?> multiTap',
        'Future<Object?> drag',
        'Future<Object?> pinch',
        'Future<Object?> twoFingerSwipe',
        'Future<String?> foregroundPackage',
      ]) {
        expect(bridge, contains(m), reason: m);
      }
    });

    test('a multi-tap count is clamped to a real multi-click', () {
      // count 1 is just a tap; 5+ is not a gesture any app recognises.
      expect(
        DeviceControlService.multiTapClampForTest(7),
        4,
      );
      expect(DeviceControlService.multiTapClampForTest(1), 2);
      expect(DeviceControlService.multiTapClampForTest(3), 3);
    });
  });
}
