import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/share_actions.dart';

ChatSession _session({bool withMessages = true}) => ChatSession(
  id: 's1',
  title: 'Share target',
  model: 'm',
  messages: withMessages ? [Message(role: 'user', content: 'hello')] : [],
);

Widget _host(ChatSession? session, {double textScale = 1}) => MaterialApp(
  theme: Aether.theme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    appBar: AppBar(actions: [ChatShareButton(session: session)]),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  void mockNativeShare({bool success = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
          call,
        ) async {
          calls.add(call);
          return success;
        });
  }

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
  });

  testWidgets('menu opens with both actions and dispatches the transcript', (
    tester,
  ) async {
    mockNativeShare();
    await tester.pumpWidget(_host(_session()));

    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    expect(find.text('Share chat transcript'), findsOneWidget);
    expect(find.text('Share local file…'), findsOneWidget);

    await tester.tap(find.text('Share chat transcript'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'shareTranscript');
    expect(calls.single.arguments['text'], 'Share target\n\nYou:\nhello\n');
  });

  testWidgets('transcript action is disabled without a session or messages', (
    tester,
  ) async {
    PopupMenuItem<String> itemOf(String label) =>
        tester.widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (widget) => widget is PopupMenuItem<String>,
            ),
          ),
        );

    mockNativeShare();
    await tester.pumpWidget(_host(null));
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    expect(itemOf('Share chat transcript').enabled, isFalse);
    expect(itemOf('Share local file…').enabled, isTrue);
    await tester.tap(find.text('Share chat transcript'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('Share chat transcript'), findsOneWidget);

    // Keep the popup open: the current live entry must track session changes.
    await tester.pumpWidget(_host(_session(withMessages: false)));
    await tester.pumpAndSettle();
    expect(itemOf('Share chat transcript').enabled, isFalse);
    expect(itemOf('Share local file…').enabled, isTrue);
    await tester.tap(find.text('Share chat transcript'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('Share chat transcript'), findsOneWidget);

    await tester.pumpWidget(_host(_session()));
    await tester.pumpAndSettle();
    expect(itemOf('Share chat transcript').enabled, isTrue);
    expect(itemOf('Share local file…').enabled, isTrue);

    // Disabling an already-enabled entry must also remove its tap action.
    await tester.pumpWidget(_host(_session(withMessages: false)));
    await tester.pumpAndSettle();
    expect(itemOf('Share chat transcript').enabled, isFalse);
    await tester.tap(find.text('Share chat transcript'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('Share chat transcript'), findsOneWidget);

    await tester.pumpWidget(_host(_session()));
    await tester.pumpAndSettle();
    expect(itemOf('Share chat transcript').enabled, isTrue);
    await tester.tap(find.text('Share chat transcript'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'shareTranscript');
    expect(calls.single.arguments['text'], 'Share target\n\nYou:\nhello\n');
    expect(find.text('Share chat transcript'), findsNothing);
  });

  testWidgets('menu items wrap readably without overflow at 320px/2x', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    mockNativeShare();
    await tester.pumpWidget(_host(_session(), textScale: 2));
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();

    // The pre-fix Row(icon + plain Text) overflowed the popup width here.
    expect(tester.takeException(), isNull);
    for (final label in ['Share chat transcript', 'Share local file…']) {
      expect(find.text(label), findsOneWidget);
      final text = tester.widget<Text>(find.text(label));
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      expect(text.maxLines, isNull);
      expect(find.text(label).hitTestable(), findsOneWidget);
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    }
  });

  testWidgets('native share refusal surfaces the retry snackbar', (
    tester,
  ) async {
    mockNativeShare(success: false);
    await tester.pumpWidget(_host(_session()));

    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share chat transcript'));
    await tester.pumpAndSettle();

    expect(calls.single.method, 'shareTranscript');
    expect(find.text('Could not open sharing. Please retry.'), findsOneWidget);
  });

  testWidgets('file action failure surfaces the retry snackbar', (
    tester,
  ) async {
    // No file_picker plugin handler exists in tests: the pick throws and the
    // error path must surface the snackbar instead of a silent no-op.
    await tester.pumpWidget(_host(_session()));

    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share local file…'));
    await tester.pumpAndSettle();

    expect(find.text('Could not open sharing. Please retry.'), findsOneWidget);
    expect(calls, isEmpty);
  });
}
