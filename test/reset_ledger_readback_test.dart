import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_ledger.dart';

void main() {
  late Directory root;
  final ledger = SessionLedger.I;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ledger-reset-readback-');
    SessionLedger.rootOverrideForTest = root;
  });

  tearDown(() async {
    for (final id in ledger.sinkOpensForTest.keys.toList()) {
      await ledger.close(id);
    }
    SessionLedger.rootOverrideForTest = null;
    await root.delete(recursive: true);
  });

  test('an empty root enumerates no sessions and reads back empty', () async {
    expect(await ledger.storedSessionIds(), isEmpty);
    expect(await ledger.isEmpty(), isTrue);
  });

  test('storedSessionIds reflects what delete removes', () async {
    await ledger.append('alpha', 'note', {'text': 'a'});
    await ledger.append('beta', 'turn_start', {'turn': 1});
    await ledger.flush('alpha');
    await ledger.flush('beta');

    expect(await ledger.storedSessionIds(), {'alpha', 'beta'});
    expect(await ledger.isEmpty(), isFalse);

    await ledger.delete('alpha');
    await ledger.delete('beta');

    expect(await ledger.storedSessionIds(), isEmpty);
    expect(await ledger.isEmpty(), isTrue);
  });
}
