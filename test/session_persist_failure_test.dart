import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Session-persist failure must be observable, not silent (audit finding B4).
///
/// A failed write used to complete its awaited future as success, so chat
/// history could quietly stop being durable. The write path now sets
/// [AppState.lastSessionPersistFailed] and notifies listeners; the shell polls
/// it and shows a durability banner. These tests pin the flag behaviour.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(AppState.resetTestInstance);

  test('a failed session write flips lastSessionPersistFailed', () async {
    final app = AppState.createForTest();
    expect(app.lastSessionPersistFailed, isFalse);

    var notified = false;
    app.addListener(() => notified = true);

    app.failNextSessionWriteForTest = true;
    await app.flushSessionPersistence();

    expect(app.lastSessionPersistFailed, isTrue,
        reason: 'the failure must be recorded, not swallowed');
    expect(notified, isTrue, reason: 'the UI is told so it can warn');
  });

  test('a later successful write clears the failure flag', () async {
    final app = AppState.createForTest();
    app.failNextSessionWriteForTest = true;
    await app.flushSessionPersistence();
    expect(app.lastSessionPersistFailed, isTrue);

    // The seam is one-shot, so the next flush writes for real and recovers.
    app.newSession();
    await app.flushSessionPersistence();

    expect(app.lastSessionPersistFailed, isFalse,
        reason: 'durability restored once a write succeeds');
  });
}
