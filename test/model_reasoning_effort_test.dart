import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  group('modelSupportsReasoningEffort (F-132)', () {
    test('accepts known reasoning families', () {
      for (final m in [
        'o3-mini',
        'o3',
        'o4-mini',
        'o1',
        'openai/o3-mini',
        'gpt-5',
        'gpt-5-mini',
        'openai/gpt-5-codex-mini-2025-09-15',
        'gpt-oss-120b',
        'gemini-2.5-pro',
        'google/gemini-2.5-flash',
        'grok-3-mini',
        'o3-mini · High',
      ]) {
        expect(modelSupportsReasoningEffort(m), isTrue, reason: m);
      }
    });

    test('rejects non-reasoning models that matched the old substrings', () {
      for (final m in [
        'gpt-4o-mini',
        'gpt-4.1',
        'gpt-5-chat-latest',
        'gpt-3.5-turbo',
        'o1-mini',
        'grok-2',
        'grok-4',
        'deepseek-chat',
        'deepseek-r1',
        'qwen3-coder',
        'claude-sonnet-4',
        'kimi-k2',
        'glm-4.6',
        'gemini-2.0-flash',
        'research-r1-proxy',
        'auto',
      ]) {
        expect(modelSupportsReasoningEffort(m), isFalse, reason: m);
      }
    });
  });
}
