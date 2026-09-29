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
}
