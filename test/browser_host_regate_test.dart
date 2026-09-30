import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// WS5 remainder (audit 2026-09-25): `browser_open`/`browser_navigate` gate the
/// host they navigate TO, but a click, a JS redirect or a `target=_blank` can
/// move the tab elsewhere afterwards — and the page-acting tools then read,
/// evaluated, typed and clicked on that host with no grant at all. Once one
/// host was granted, the model could walk to any other.
///
/// The fix re-checks the tab's LIVE host (`location.host`) before any
/// page-acting tool runs. These pins cover the two things that must not drift:
/// WHICH tools are gated, and that the gate adds no async turn for other tools
/// (the device_* cancellation contract depends on dispatch timing).
void main() {
  final src = File('lib/core/agent_service.dart').readAsStringSync();

  int setStart() {
    final i = src.indexOf('static const Set<String> _browserPageActingTools');
    expect(i, greaterThanOrEqualTo(0));
    return i;
  }

  String gatedSet() {
    final i = setStart();
    return src.substring(i, src.indexOf('};', i));
  }

  group('the page-acting tools are gated on the live host', () {
    test('tools that read or mutate page content are in the set', () {
      final set = gatedSet();
      for (final t in [
        'browser_read',
        'browser_evaluate',
        'browser_click',
        'browser_tap_at',
        'browser_type',
        'browser_fill',
        'browser_screenshot',
        'browser_cookies',
        'browser_snapshot',
        'browser_console',
      ]) {
        expect(set, contains("'$t'"), reason: '$t acts on the live page');
      }
    });

    test('navigation and tab tools are NOT in the set', () {
      final set = gatedSet();
      for (final t in [
        'browser_open',
        'browser_navigate',
        'browser_back',
        'browser_forward',
        'browser_reload',
        'browser_new_tab',
        'browser_close_tab',
        'browser_switch_tab',
        'browser_list_tabs',
        'browser_desktop',
        'browser_resize',
      ]) {
        expect(set, isNot(contains("'$t'")),
            reason: '$t gates its own target or does not touch page content');
      }
    });
  });

  group('the gate cannot disturb other tools or wedge the browser', () {
    test('the set membership test is sync and guards the only await', () {
      final i = src.indexOf('if (_browserPageActingTools.contains(name))');
      expect(i, greaterThanOrEqualTo(0));
      final block = src.substring(i, i + 260);
      // The await lives INSIDE the name test, so a device_* dispatch never
      // gains a microtask turn ahead of its native call.
      expect(block.indexOf('contains(name)'), lessThan(block.indexOf('await')));
      expect(block, contains('_browserHostDenial(name)'));
    });

    test('an unverifiable host proceeds instead of wedging the tool', () {
      final i = src.indexOf('Future<String?> _browserHostDenial(');
      expect(i, greaterThanOrEqualTo(0));
      final body = src.substring(i, src.indexOf('\n  }', i));
      // No tab / no controller / empty host (file:// preview) / probe error
      // all fall through — the explicit-navigation grant still gates those.
      expect(body, contains('if (tabs.isEmpty) return null;'));
      expect(body, contains('if (controller == null) return null;'));
      expect(body, contains('if (host.isEmpty) return null;'));
      expect(body, contains("Diag.swallow('agent_service.browserHostProbe'"));
    });

    test('a refused host returns the standard ACCESS_DENIED shape', () {
      final i = src.indexOf('Future<String?> _browserHostDenial(');
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('_checkHostGrant(host, tool: tool)'));
      expect(body, contains('_accessDeniedMessage('));
    });
  });
}
