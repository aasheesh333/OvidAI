import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/hook_service.dart';

/// H2: untrusted plugin hook matchers are compiled as regex and run
/// synchronously on every dispatch with no bound — a crafted pattern can hang
/// the isolate (ReDoS). H3: hook payloads forward raw tool args (including
/// provider API keys) to any observing plugin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => HookService.I.resetForTest());
  tearDown(() => HookService.I.resetForTest());

  group('H2 matcher safety', () {
    test('an oversized matcher is rejected, not compiled', () {
      final huge = 'a' * 5000;
      expect(HookService.isSafeMatcher(huge), isFalse);
    });

    test('a nested-quantifier pattern is rejected', () {
      expect(HookService.isSafeMatcher(r'(a+)+$'), isFalse);
      expect(HookService.isSafeMatcher(r'(a*)*b'), isFalse);
      expect(HookService.isSafeMatcher(r'(.*)*'), isFalse);
    });

    test('ordinary matchers are accepted', () {
      expect(HookService.isSafeMatcher('startup|clear|compact'), isTrue);
      expect(HookService.isSafeMatcher(r'^Bash$'), isTrue);
      expect(HookService.isSafeMatcher('*'), isTrue);
      expect(HookService.isSafeMatcher(''), isTrue);
    });
  });

  group('H3 payload redaction', () {
    test('secret-named keys are redacted recursively', () {
      final redacted = HookService.redactHookPayload({
        'tool': 'catalog_set_provider_key',
        'args': {'provider_id': 'openai', 'api_key': 'sk-live-secret'},
        'headers': {'Authorization': 'Bearer xyz'},
        'password': 'hunter2',
        'token': 'ghp_abc',
      });
      expect(redacted['tool'], 'catalog_set_provider_key');
      final args = redacted['args'] as Map;
      expect(args['provider_id'], 'openai');
      expect(args['api_key'], isNot('sk-live-secret'));
      expect((redacted['headers'] as Map)['Authorization'], isNot('Bearer xyz'));
      expect(redacted['password'], isNot('hunter2'));
      expect(redacted['token'], isNot('ghp_abc'));
    });

    test('non-secret values are untouched', () {
      final redacted = HookService.redactHookPayload({
        'tool': 'run_shell',
        'args': {'command': 'ls -la'},
      });
      expect((redacted['args'] as Map)['command'], 'ls -la');
    });

    test('nested lists are walked', () {
      final redacted = HookService.redactHookPayload({
        'items': [
          {'name': 'a', 'secret': 'x'},
        ],
      });
      final first = (redacted['items'] as List).first as Map;
      expect(first['name'], 'a');
      expect(first['secret'], isNot('x'));
    });
  });
}
