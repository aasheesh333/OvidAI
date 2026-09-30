import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/hook_service.dart';

/// Claude Code hook matcher parity (audit 2026-09-25).
///
/// A matcher is a regex matched against the WHOLE tool name (or the CC session
/// source token), not a substring. `Edit` must fire on `Edit` only — the old
/// unanchored implementation fired on `MultiEdit`/`NotebookEdit` too.
void main() {
  Map<String, dynamic> tool(String name) => {'tool': name};
  Map<String, dynamic> session(String reason) => {'reason': reason};

  bool applies(String event, String? matcher, Map<String, dynamic> p) =>
      HookService.matcherAppliesForTest(event, matcher, p);

  group('tool-name matchers are full-string', () {
    test('an exact tool name does not match a longer tool', () {
      expect(applies('pre_tool', 'Edit', tool('Edit')), isTrue);
      expect(applies('pre_tool', 'Edit', tool('MultiEdit')), isFalse);
      expect(applies('pre_tool', 'Edit', tool('NotebookEdit')), isFalse);
    });

    test('an alternation matches each whole alternative', () {
      expect(applies('pre_tool', 'Edit|Write', tool('Write')), isTrue);
      expect(applies('pre_tool', 'Edit|Write', tool('Edit')), isTrue);
      expect(applies('pre_tool', 'Edit|Write', tool('MultiEdit')), isFalse);
    });

    test('a pattern still works when anchored', () {
      expect(applies('pre_tool', 'Notebook.*', tool('NotebookEdit')), isTrue);
      expect(applies('pre_tool', 'mcp__.*', tool('mcp__srv__do')), isTrue);
      expect(applies('pre_tool', 'Notebook.*', tool('Edit')), isFalse);
    });

    test('empty / star / null match everything', () {
      expect(applies('pre_tool', null, tool('Edit')), isTrue);
      expect(applies('pre_tool', '', tool('Edit')), isTrue);
      expect(applies('pre_tool', '*', tool('Edit')), isTrue);
    });
  });

  group('session-source matchers are full-string', () {
    test('startup does not match a longer token', () {
      expect(applies('session_start', 'startup', session('created')), isTrue);
      expect(applies('session_start', 'resume', session('restored')), isTrue);
      // A hypothetical longer subject must not substring-match.
      expect(applies('session_start', 'start', session('created')), isFalse);
    });
  });

  group('MCP server-prefix matchers (Claude Code rule)', () {
    // `mcp__server-name` catches EVERY tool of that server, and Ovid dispatches
    // those tools as `mcp__<server>__<tool>`. Full-string anchoring killed this
    // rule, so every MCP-scoped plugin hook silently stopped firing.
    Map<String, dynamic> tool(String name) => {'tool': name};

    test('a bare server name matches all of that server\'s tools', () {
      expect(
        applies('pre_tool', 'mcp__github', tool('mcp__github__create_issue')),
        isTrue,
      );
      expect(
        applies('post_tool', 'mcp__github', tool('mcp__github__list_prs')),
        isTrue,
      );
      expect(applies('pre_tool', 'mcp__github', tool('mcp__github')), isTrue);
    });

    test('the prefix is boundary-exact, not a substring', () {
      expect(
        applies('pre_tool', 'mcp__github', tool('mcp__githubv2__thing')),
        isFalse,
        reason: 'a different server must not be caught',
      );
      expect(
        applies('pre_tool', 'mcp__git', tool('mcp__github__create_issue')),
        isFalse,
      );
    });

    test('a real regex branch still goes through the anchored path', () {
      expect(applies('pre_tool', 'mcp__.*', tool('mcp__srv__do')), isTrue);
      expect(applies('pre_tool', 'mcp__.*', tool('file_read')), isFalse);
    });

    test('an alternation keeps both the exact and the prefix rule', () {
      expect(
        applies('pre_tool', 'Edit|mcp__github', tool('mcp__github__x')),
        isTrue,
      );
      expect(applies('pre_tool', 'Edit|mcp__github', tool('Edit')), isTrue);
      expect(applies('pre_tool', 'Edit|mcp__github', tool('MultiEdit')), isFalse);
    });

    test('the prefix rule is scoped to tool events only', () {
      expect(
        applies('session_start', 'mcp__github', session('created')),
        isFalse,
      );
    });
  });

  group('events with no Claude Code matcher vocabulary still fire', () {
    // Only tool events, session start/end and compaction have matcher
    // semantics. A declared matcher on any other event used to be compared
    // against an empty subject, so the hook was permanently and silently dead.
    test('compaction matches manual/auto from the trigger', () {
      expect(
        applies('pre_compact', 'manual', {'trigger': 'manual'}),
        isTrue,
      );
      expect(applies('pre_compact', 'manual', {'trigger': 'auto'}), isFalse);
      expect(applies('pre_compact', 'auto', {'trigger': 'auto'}), isTrue);
    });

    test('a matcher on a matcher-less event does not kill the hook', () {
      for (final event in ['stop', 'notification', 'subagent_start', 'user_prompt_submit']) {
        expect(applies(event, 'anything', {}), isTrue,
            reason: '$event has no matcher vocabulary — ignoring it beats '
                'silently never firing');
      }
    });

    test('session_end carries a matchable CC reason', () {
      // Deleting a chat maps to CC's `clear`; the fire site now passes it, so a
      // plugin matcher can actually match instead of seeing an empty subject.
      expect(applies('session_end', 'clear', {'reason': 'clear'}), isTrue);
      expect(applies('session_end', 'logout', {'reason': 'clear'}), isFalse);
      expect(
        applies('session_end', 'clear|logout', {'reason': 'clear'}),
        isTrue,
      );
    });
  });
}
