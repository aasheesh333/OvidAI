import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner request (2026-09-28): "do add pop up feature in browser".
///
/// WHY THIS IS A SOURCE-PIN SUITE. webview_flutter exposes no `onCreateWindow`,
/// so the whole feature lives in a JavaScript shim injected into the page plus
/// the native side that receives it — neither is reachable from a unit test
/// (no WebView, no platform channel), and the notice widget itself is private.
/// The repo's established answer for exactly this shape of feature is to pin the
/// contract text (see control_gestures_overlay_test.dart, which pins Kotlin and
/// manifest source). These pins are the guard rail: they fail loudly if a
/// refactor drops the bridge, the cap, the gesture flag or the host-grant gate —
/// each of which is a silent regression a user would only notice as "the click
/// did nothing" or "this site opened something I never asked for".
///
/// The four halves of the contract, each with the failure it prevents:
///   capture  — window.open AND target=_blank are both bridged (a _blank tap
///              never reaches window.open, so hooking only one loses clicks);
///   queue    — held per tab, hard-capped, so a window.open loop cannot grow it;
///   surface  — the Browser panel shows a blocked-popup bar with Open/Dismiss;
///   safety   — opening goes through the SAME host-grant gate as browser_open,
///              because a popup is a navigation the user did not ask for.
void main() {
  final agentSrc = File('lib/core/agent_service.dart').readAsStringSync();
  final uiSrc = File('lib/ui/browser_screen.dart').readAsStringSync();

  group('popup capture: both escape routes are bridged', () {
    test('a dedicated JS channel exists and routes to _onPagePopup', () {
      // Without this channel the page-side shim has nowhere to post, and the
      // whole feature is inert.
      expect(agentSrc, contains("'OvidPopup',"));
      expect(
        agentSrc,
        contains('onMessageReceived: (msg) => _onPagePopup(tab, msg.message),'),
      );
    });

    test('window.open is overridden in the page', () {
      expect(agentSrc, contains('window.open = (u, t, f) => {'));
      // The forwarded payload must say where it came from, or a _blank click and
      // a scripted window.open are indistinguishable in the logs.
      expect(agentSrc, contains("source: 'window.open'"));
    });

    test('window.open returns null instead of opening a real window', () {
      // Deliberate: opening here would dodge the host-grant gate that
      // browser_popups applies on the native side.
      expect(agentSrc, contains('  return null;\n};'));
    });

    test('a real user gesture is detected and forwarded', () {
      // `gesture` is what separates "the user clicked" from "the page scripted
      // it" — the difference between opening a tab and merely recording one.
      expect(
        agentSrc,
        contains(
          'gesture: !!(navigator.userActivation && navigator.userActivation.isActive),',
        ),
      );
    });

    test('target=_blank clicks are captured in the capture phase', () {
      // A `_blank` anchor never calls window.open, and there is no
      // onCreateWindow, so without this listener those taps did nothing at all.
      expect(agentSrc, contains("document.addEventListener('click', (ev) => {"));
      expect(
        agentSrc,
        contains("if (tgt !== '_blank' && tgt !== '_new') return;"),
      );
      // Hooked exactly once per document — re-injecting the listener on every
      // navigation would multiply the popups recorded per click.
      expect(agentSrc, contains('if (!window.__ovidBlankHooked) {'));
      expect(agentSrc, contains('window.__ovidBlankHooked = true;'));
    });
  });

  group('popup queue: per-tab, bounded on BOTH sides', () {
    test('the queue is a per-tab list', () {
      // Per tab, not global: a popup held in one tab must not be offered as an
      // action in another (sessions also isolate their tabs entirely).
      expect(agentSrc, contains('final List<String> popupRequests = [];'));
    });

    test('the page-side list is capped', () {
      expect(
        agentSrc,
        contains(
          'if (window.__ovidPopups.length > 40) window.__ovidPopups.shift();',
        ),
      );
    });

    test('the native-side list is capped by the same bound', () {
      // A page stuck in a window.open loop would otherwise grow this list for
      // the life of the tab. Both ends must agree, or the smaller cap is the
      // only one that matters.
      expect(
        agentSrc,
        contains('void _recordPopup(BrowserTab tab, String url, {String? warn}) {'),
      );
      expect(agentSrc, contains('if (tab.popupRequests.length > 40) {'));
      expect(
        agentSrc,
        contains('tab.popupRequests.removeRange(0, tab.popupRequests.length - 40);'),
      );
    });

    test('a recorded popup also lands in the console log when warned', () {
      // The user-facing trace of "this page tried to open something".
      expect(agentSrc, contains("kind: 'warn', text: warn));"));
    });
  });

  group('popup surface: the Browser panel shows a blocked-popup bar', () {
    test('the notice widget exists and is mounted', () {
      expect(uiSrc, contains('class _PopupNotice extends StatelessWidget {'));
      expect(uiSrc, contains('_PopupNotice('));
    });

    test('it hides entirely when nothing is held', () {
      expect(uiSrc, contains('final pending = tab.popupRequests;'));
      expect(
        uiSrc,
        contains('if (pending.isEmpty) return const SizedBox.shrink();'),
      );
    });

    test('the label names the host, and counts when several are held', () {
      // Naming the host is what makes the bar actionable; a bare "popup blocked"
      // tells the user nothing about which site asked.
      expect(uiSrc, contains('final host = Uri.tryParse(last)?.host ?? last;'));
      expect(uiSrc, contains('pending.length == 1'));
    });

    test('stable keys for the bar and both actions', () {
      // Keyed so a widget test (and the accessibility tree) can find them
      // without depending on label wording.
      expect(uiSrc, contains("key: const ValueKey('popup-notice'),"));
      expect(uiSrc, contains("key: const ValueKey('popup-open'),"));
      expect(uiSrc, contains("key: const ValueKey('popup-dismiss'),"));
    });

    test('Open routes through openBrowserPopup, Dismiss through the service', () {
      expect(uiSrc, contains('final opened = _agent.openBrowserPopup(tab);'));
      expect(uiSrc, contains('required this.onOpen,'));
      expect(uiSrc, contains('required this.onDismiss,'));
      // A refused popup must SAY so rather than look like a dead button.
      expect(uiSrc, contains('if (opened == null) {'));
    });
  });

  group('popup safety: opening is gated, not free', () {
    test('the user-facing open refuses anything that is not http(s)', () {
      expect(
        agentSrc,
        contains('String? openBrowserPopup(BrowserTab tab, [String? url]) {'),
      );
      expect(
        agentSrc,
        contains("if (uri == null || scheme != 'http' && scheme != 'https') {"),
      );
      // Returns null on refusal so the UI can distinguish "opened" from
      // "refused" — and the queue entry survives, staying visible/auditable.
      expect(agentSrc, contains('return null;'));
    });

    test('a successful open leaves the queue', () {
      // Otherwise the bar would keep offering a popup that is already open,
      // and Open would spawn a duplicate tab every press.
      expect(agentSrc, contains('tab.popupRequests.remove(raw);'));
    });

    test('dismiss clears the tab queue', () {
      expect(agentSrc, contains('void dismissBrowserPopups(BrowserTab tab) {'));
      expect(agentSrc, contains('tab.popupRequests.clear();'));
    });

    test('the agent tool applies the same host-grant gate as browser_open', () {
      // The point of returning null in the shim: the native side stays in
      // control, so a popup URL is still a navigation the user must grant.
      expect(
        agentSrc,
        contains(
          'Future<String> _handleBrowserPopups(Map<String, dynamic> args) async {',
        ),
      );
      expect(
        agentSrc,
        contains(
          "if (!await _checkHostGrant(popupUri!.host, tool: 'browser_popups')) {",
        ),
      );
    });

    test('the agent tool exposes list / open / clear', () {
      expect(agentSrc, contains("? 'no popup requests'"));
      expect(agentSrc, contains("if (action == 'open') {"));
      expect(agentSrc, contains("if (action == 'clear') {"));
      expect(agentSrc, contains("return 'popups cleared';"));
    });

    test('the tool description tells the model what it is reading', () {
      // A tool the model cannot interpret is a tool it will not use at the
      // moment a login flow needs it.
      expect(
        agentSrc,
        contains(
          "'List popup requests (window.open) intercepted on the current '",
        ),
      );
    });
  });
}
