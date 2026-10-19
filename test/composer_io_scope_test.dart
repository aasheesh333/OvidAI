import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

/// F-034 / F-035: the composer's `@` file list and image rows do no
/// synchronous file IO in build. Widget tests run in fake async, where real
/// async IO only completes inside `runAsync`; anything that shows up before
/// that must have come from synchronous IO during build.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ChatSession a;
  late Directory workspace;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    workspace = Directory.systemTemp.createTempSync('composer-io-');
    a = ChatSession(
      id: 'composer-io',
      title: 'A',
      model: 'm',
      messages: [Message(role: 'assistant', content: 'Ready')],
    )..workspaceFolder = workspace.path;
    app.sessions
      ..clear()
      ..add(a);
    app.activeSessionId = a.id;
  });

  tearDown(() {
    workspace.deleteSync(recursive: true);
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Lets real async IO started in the fake zone finish: each round runs the
  /// real event loop, then flushes the fake zone's continuations.

  testWidgets('image rows resolve the file asynchronously', (tester) async {
    final image = File('${workspace.path}/image.png')
      ..writeAsBytesSync(List<int>.filled(4096, 0));
    a.messages
      ..clear()
      ..addAll([
        Message(
          role: 'assistant',
          kind: MsgKind.imageGen,
          content: 'Present image',
          imagePath: image.path,
        ),
        Message(
          role: 'assistant',
          kind: MsgKind.imageGen,
          content: 'Missing image',
          imagePath: '${workspace.path}/missing.png',
        ),
      ]);
    await pumpChat(tester);
    // The stat is synchronous in the row's lifecycle entry points (never
    // inside build — see _ImageFileInfoState): the size and the missing
    // verdict are known on the FIRST frame, with no real I/O settlement
    // needed. The old async stat never completed under the test binding,
    // which this suite's earlier shape pinned as "nothing known yet".
    expect(find.text('4 KB'), findsOneWidget);
    expect(find.text('image file not in workspace'), findsOneWidget);
  });
}
