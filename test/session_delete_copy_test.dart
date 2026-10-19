// CH-030: the chat delete dialog says what a CLOUD delete does — the chat
// and its history go on every device; the per-user Studio workspace stays.
// It never claims a "sandbox workspace" is deleted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/session_actions.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(AppState.resetTestInstance);

  testWidgets('delete dialog copy matches server delete semantics', (
    tester,
  ) async {
    final session = ChatSession(id: 's1', title: 'Trip', model: 'm');
    AppState.I.sessions
      ..clear()
      ..add(session);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: Aether.theme(),
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    final result = askDeleteSessionConfirmed(ctx, session);
    await tester.pumpAndSettle();
    expect(find.textContaining('on all your devices'), findsOneWidget);
    expect(find.textContaining('Studio workspace are kept'), findsOneWidget);
    expect(find.textContaining('sandbox'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });
}
