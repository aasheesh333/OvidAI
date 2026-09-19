import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/agent_service.dart';

void main() {
  group('substituteCommandArguments', () {
    test(r'replaces $ARGUMENTS with the full argument string', () {
      expect(
        AgentService.substituteCommandArguments(
          r'Summarize $ARGUMENTS please',
          'the release notes',
        ),
        'Summarize the release notes please',
      );
    });

    test(r'replaces $@ with the full argument string', () {
      expect(
        AgentService.substituteCommandArguments(r'Run $@ now', 'a b c'),
        'Run a b c now',
      );
    });

    test(r'replaces positional $1 and $2 from whitespace-split args', () {
      expect(
        AgentService.substituteCommandArguments(
          r'Fix issue $1 in $2',
          'auth login',
        ),
        'Fix issue auth in login',
      );
    });

    test(r'replaces positional $10 and above', () {
      expect(
        AgentService.substituteCommandArguments(
          r'$10',
          'a b c d e f g h i j',
        ),
        'j',
      );
    });

    // Choice: an out-of-range positional placeholder is left as-is rather
    // than erased, so the model still sees that an argument was expected.
    test(r'leaves an out-of-range positional placeholder as-is', () {
      expect(
        AgentService.substituteCommandArguments(r'A $3 B', 'x y'),
        r'A $3 B',
      );
      expect(
        AgentService.substituteCommandArguments(r'A $10 B', 'x y'),
        r'A $10 B',
      );
    });

    test(r'unescapes \$ to a literal dollar sign without substituting', () {
      expect(
        AgentService.substituteCommandArguments(r'cost \$5 and $1', 'x'),
        r'cost $5 and x',
      );
      expect(
        AgentService.substituteCommandArguments(r'\$ARGUMENTS', 'ignored'),
        r'$ARGUMENTS',
      );
    });

    test('leaves the body unchanged when it has no placeholders', () {
      expect(
        AgentService.substituteCommandArguments('plain instruction', 'args'),
        'plain instruction',
      );
    });

    test('substitutes multiple occurrences', () {
      expect(
        AgentService.substituteCommandArguments(
          r'$1 then $1 then $ARGUMENTS',
          'one two',
        ),
        'one then one then one two',
      );
    });
  });

  group('commandArgumentTrailer', () {
    test('appends the legacy trailer when no placeholders exist', () {
      expect(
        AgentService.commandArgumentTrailer(
          'plain instruction',
          'a b',
          'Arguments',
        ),
        '\n\nArguments: a b',
      );
      expect(
        AgentService.commandArgumentTrailer(
          'plain instruction',
          'do it',
          'User instruction',
        ),
        '\n\nUser instruction: do it',
      );
    });

    test('is empty when the body declares placeholders', () {
      expect(
        AgentService.commandArgumentTrailer(r'Fix $1', 'a b', 'Arguments'),
        '',
      );
      expect(
        AgentService.commandArgumentTrailer(
          r'Fix $ARGUMENTS',
          'a b',
          'Arguments',
        ),
        '',
      );
    });

    test('is empty when there are no arguments', () {
      expect(
        AgentService.commandArgumentTrailer(
          'plain instruction',
          '',
          'Arguments',
        ),
        '',
      );
    });
  });
}
