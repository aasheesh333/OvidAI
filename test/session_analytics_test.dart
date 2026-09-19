import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/agent_service.dart';

void main() {
  test('pricing estimates known models and refuses unknown models', () {
    expect(
      AgentService.estimatedCostForModel('deepseek-chat', 1000000, 1000000),
      closeTo(1.37, 0.000001),
    );
    expect(
      AgentService.estimatedCostForModel('my-private-model', 100, 100),
      isNull,
    );
  });

  test('session analytics are isolated and persist through JSON', () {
    final first = ChatSession(id: 'a', title: 'A', model: 'deepseek-chat');
    final second = ChatSession(id: 'b', title: 'B', model: 'deepseek-chat');

    first.recordAnalytics(
      inputTokens: 1200,
      outputTokens: 300,
      turns: 2,
      toolCalls: 3,
      toolMs: 4200,
      llmMs: 8000,
      ttftMs: 700,
      decodeTokens: 300,
      cacheReadTokens: 100,
      cacheWriteTokens: 50,
      estimatedCostUsd: 0.000654,
      contextTokens: 1500,
      contextLimit: 32768,
    );

    expect(first.analytics.inputTokens, 1200);
    expect(first.analytics.outputTokens, 300);
    expect(first.analytics.toolCalls, 3);
    expect(second.analytics.inputTokens, 0);
    expect(second.analytics.estimatedCostUsd, 0);

    final restored = ChatSession.fromJson(first.toJson());
    expect(restored.analytics.inputTokens, 1200);
    expect(restored.analytics.outputTokens, 300);
    expect(restored.analytics.turns, 2);
    expect(restored.analytics.contextTokens, 1500);
    expect(restored.analytics.contextLimit, 32768);
    expect(restored.analytics.estimatedCostUsd, closeTo(0.000654, 0.0000001));
  });

  test('analytics accumulates each completed model request', () {
    final session = ChatSession(id: 'a', title: 'A', model: 'gpt-4o');
    session.recordAnalytics(
      inputTokens: 100,
      outputTokens: 20,
      turns: 1,
      estimatedCostUsd: 0.001,
    );
    session.recordAnalytics(
      inputTokens: 200,
      outputTokens: 30,
      turns: 1,
      estimatedCostUsd: 0.002,
    );
    expect(session.analytics.inputTokens, 300);
    expect(session.analytics.outputTokens, 50);
    expect(session.analytics.turns, 2);
    expect(session.analytics.estimatedCostUsd, closeTo(0.003, 0.0000001));
  });
}
