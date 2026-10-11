import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_ledger.dart';

void main() {
  late Directory root;
  final ledger = SessionLedger.I;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ledger-projection-');
    SessionLedger.rootOverrideForTest = root;
  });

  tearDown(() async {
    for (final id in ledger.sinkOpensForTest.keys.toList()) {
      await ledger.close(id);
    }
    SessionLedger.rootOverrideForTest = null;
    await root.delete(recursive: true);
  });

  test('LLM time sums turn_end.llmMs (no llm events are emitted)', () async {
    for (var i = 0; i < 2; i++) {
      await ledger.append('p', 'turn_start', {});
      await ledger.append('p', 'turn_end', {'llmMs': 1000});
    }
    final p = await ledger.projection('p');
    expect(p.turns, 2);
    expect(p.llmMs, 2000);
  });

  test('running totals from one run bucket add only the delta', () async {
    // The agent writes the bucket's cumulative counters into turn_end.
    await ledger.append('c', 'turn_start', {});
    await ledger.append('c', 'turn_end', {'turns': 1, 'llmMs': 1000});
    await ledger.append('c', 'turn_start', {});
    await ledger.append('c', 'turn_end', {'turns': 3, 'llmMs': 2500});
    // App restarted: a fresh bucket starts counting from zero again.
    await ledger.append('c', 'turn_start', {});
    await ledger.append('c', 'turn_end', {'turns': 1, 'llmMs': 400});
    expect((await ledger.projection('c')).llmMs, 2900);
  });

  test('explicit llm events are not double counted with turn_end', () async {
    await ledger.append('e', 'turn_start', {});
    await ledger.append('e', 'llm', {'ms': 700});
    await ledger.append('e', 'turn_end', {'turns': 1, 'llmMs': 700});
    expect((await ledger.projection('e')).llmMs, 700);
  });
}
