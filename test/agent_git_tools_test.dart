import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';

/// The Studio agent's GitHub-native tool roster: clone/commit/push/pull
/// plus read-only status/log/diff. Guards the wiring — every tool the
/// model can call must have a definition, a handler case, and (for the
/// mutating ones) read-only + plan-mode gating.
void main() {
  Map<String, Map<String, dynamic>> toolFns() {
    final out = <String, Map<String, dynamic>>{};
    for (final t in AgentService.I.toolsForTest()) {
      final fn = (t['function'] as Map).cast<String, dynamic>();
      out[fn['name'] as String] = fn;
    }
    return out;
  }

  group('git tool definitions', () {
    test('all five git tools are advertised to the model', () {
      final fns = toolFns();
      for (final name in [
        'git_clone',
        'commit',
        'git_push',
        'git_pull',
        'git_status',
        'git_log',
        'git_diff',
      ]) {
        expect(fns.containsKey(name), isTrue, reason: 'missing tool: $name');
      }
    });

    test('every git tool has a valid function schema', () {
      final fns = toolFns();
      for (final name in [
        'git_push',
        'git_pull',
        'git_status',
        'git_log',
        'git_diff',
      ]) {
        final fn = fns[name]!;
        expect(fn['description'], isA<String>());
        expect((fn['description'] as String).isNotEmpty, isTrue);
        final params = fn['parameters'] as Map;
        expect(params['type'], 'object');
        // Issue 8: zero-arg tools (e.g. git_status) normalize to
        // {'type':'object'} — empty `properties` is omitted, never sent as {}.
        final props = params['properties'];
        expect(props == null || props is Map, isTrue,
            reason: '$name: properties must be a Map or omitted when empty');
      }
    });

    test('git_push/git_pull take optional remote + branch', () {
      final fns = toolFns();
      for (final name in ['git_push', 'git_pull']) {
        final props =
            (fns[name]!['parameters'] as Map)['properties'] as Map;
        expect(props.containsKey('remote'), isTrue);
        expect(props.containsKey('branch'), isTrue);
      }
    });

    test('git_log takes an optional n', () {
      final fns = toolFns();
      final props =
          (fns['git_log']!['parameters'] as Map)['properties'] as Map;
      expect(props.containsKey('n'), isTrue);
    });

    test('git_diff takes staged + stat flags', () {
      final fns = toolFns();
      final props =
          (fns['git_diff']!['parameters'] as Map)['properties'] as Map;
      expect(props.containsKey('staged'), isTrue);
      expect(props.containsKey('stat'), isTrue);
    });

    test('read-only git tools are documented as read-only', () {
      final fns = toolFns();
      for (final name in ['git_status', 'git_log', 'git_diff']) {
        expect(
          (fns[name]!['description'] as String).toLowerCase(),
          contains('read-only'),
        );
      }
    });
  });

  group('git tool presentation', () {
    test('toolTitleFor covers the git tools', () {
      expect(AgentService.toolTitleFor('git_push'), 'Push');
      expect(AgentService.toolTitleFor('git_pull'), 'Pull');
      expect(AgentService.toolTitleFor('git_status'), 'Git status');
      expect(AgentService.toolTitleFor('git_log'), 'Git log');
      expect(AgentService.toolTitleFor('git_diff'), 'Git diff');
    });
  });
}
