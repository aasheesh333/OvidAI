import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_share.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/share_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
          call,
        ) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), null),
  );

  test(
    'app shares the existing website, not a fabricated session URL',
    () async {
      await NativeShare.app();
      expect(calls.single.method, 'shareText');
      expect(calls.single.arguments, {
        'text': 'Ovid — AI chat, agents & tools\nhttps://dhanuk.page.gd/ovid',
        'title': 'Share Ovid',
      });
    },
  );
  test(
    'local paths with spaces reach the native content URI boundary intact',
    () async {
      await NativeShare.file('/storage/emulated/0/Download/my image.png');
      expect(calls.single.method, 'shareFile');
      expect(calls.single.arguments, {
        'filePath': '/storage/emulated/0/Download/my image.png',
        'title': 'Share file',
      });
    },
  );
  test(
    'transcript exports ordered conversation and names, not private paths',
    () async {
      final s = ChatSession(
        id: 's',
        title: '日本語 / notes',
        providerId: 'p',
        model: 'm',
      );
      s.messages.addAll([
        Message(
          role: 'user',
          content: 'hello',
          attachments: [MessageAttachment(name: 'a.pdf', size: 10)],
        ),
        Message(role: 'assistant', content: 'world'),
        Message(
          role: 'assistant',
          kind: MsgKind.imageGen,
          content: 'a cat',
          imagePath: '/private/session/cat.png',
        ),
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolTitle: 'Read file',
          toolDetail: 'tool output',
        ),
      ]);
      await NativeShare.transcript(s);
      expect(calls.single.method, 'shareTranscript');
      final payload = calls.single.arguments as Map;
      expect(payload['fileName'], 'ovid-chat.txt');
      expect(
        payload['text'],
        '日本語 / notes\n\nYou:\nhello\nAttachment: a.pdf\n\n'
        'Ovid:\nworld\n\nOvid:\na cat\nImage: cat.png\n\nTool: Read file\ntool output\n',
      );
      expect(payload['text'], isNot(contains('/private/')));
    },
  );
  test('native launch refusal is an error, not apparent success', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('ovid/native'),
          (_) async => false,
        );
    await expectLater(
      NativeShare.file('/tmp/a.txt'),
      throwsA(isA<PlatformException>()),
    );
  });

  testWidgets('share menu dispatches the visible session transcript', (
    tester,
  ) async {
    final s = ChatSession(
      id: 'one',
      title: 'Visible session',
      model: 'm',
      messages: [Message(role: 'user', content: 'message to share')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [ChatShareButton(session: s)]),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share chat transcript'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'shareTranscript');
    expect(
      calls.single.arguments['text'],
      'Visible session\n\nYou:\nmessage to share\n',
    );
  });
}
