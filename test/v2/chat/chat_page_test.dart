import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

void main() {
  testWidgets('renders the top bar, empty state and suggestions in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('What should we build today?'), findsOneWidget);
    expect(
      find.text('Ask anything. Ovid works in the background.'),
      findsOneWidget,
    );
    expect(find.text('Build me a landing page'), findsOneWidget);
    expect(find.text('Research a topic for me'), findsOneWidget);
    expect(find.text('Fix a bug in my repo'), findsOneWidget);
    expect(find.text('Auto · 50M tokens left today'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(const V2ChatPage(data: V2ChatPageData()), dark: true),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('What should we build today?'), findsOneWidget);
    expect(find.text('Auto · 50M tokens left today'), findsOneWidget);
  });

  testWidgets('suggestion card fires and fills the composer', (tester) async {
    V2ChatSuggestion? tapped;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onSuggestionTap: (suggestion) => tapped = suggestion,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Build me a landing page'));
    await tester.pump();

    expect(tapped, isNotNull);
    expect(tapped!.title, 'Build me a landing page');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Build me a landing page');
  });

  testWidgets('draft is controlled by data and emits changes', (tester) async {
    String? changed;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(draft: 'Start here'),
          onDraftChanged: (value) => changed = value,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Start here');

    await tester.enterText(find.byType(TextField), 'Keep going');
    expect(changed, 'Keep going');
  });

  testWidgets('send callback carries the typed text', (tester) async {
    String? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), onSend: (text) => sent = text),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), 'Build a pricing page');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(sent, 'Build a pricing page');
  });

  testWidgets('model chip and top bar actions report taps', (tester) async {
    var modelTaps = 0;
    var studioTaps = 0;
    var browserTaps = 0;
    var moreTaps = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onModelChipTap: () => modelTaps++,
          onStudio: () => studioTaps++,
          onBrowser: () => browserTaps++,
          onMore: () => moreTaps++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Auto'));
    await tester.tap(find.bySemanticsLabel('Open Studio'));
    await tester.tap(find.bySemanticsLabel('Open Browser'));
    await tester.tap(find.bySemanticsLabel('More options'));
    await tester.pump();

    expect(modelTaps, 1);
    expect(studioTaps, 1);
    expect(browserTaps, 1);
    expect(moreTaps, 1);
  });

  testWidgets('loading state shows history skeletons', (tester) async {
    await tester.pumpWidget(
      _app(const V2ChatPage(data: V2ChatPageData(state: V2ChatState.loading))),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(state: V2ChatState.error),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('offline queue explains that messages will send later', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(
            state: V2ChatState.offline,
            queuedCount: 2,
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Messages will send when you reconnect.'), findsOneWidget);
    expect(find.text('2 messages are waiting to send.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('daily limit state shows reset time and plans action', (
    tester,
  ) async {
    var plans = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(state: V2ChatState.planLimited),
          onSeePlans: () => plans++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Daily limit reached'), findsOneWidget);
    expect(
      find.text("You've used all 50M free tokens for today. Resets in 6h 12m."),
      findsOneWidget,
    );
    await tester.tap(find.text('See plans'));
    expect(plans, 1);
  });

  testWidgets('running state shows a stop action', (tester) async {
    var stops = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(state: V2ChatState.running),
          onStop: () => stops++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Ovid is working'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    expect(stops, 1);
  });

  for (final dark in [false, true]) {
    testWidgets(
      '320 dp at 200% text lays out cleanly (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);

        for (final state in V2ChatState.values) {
          errors.clear();
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 640),
                  textScaler: TextScaler.linear(2),
                ),
                child: V2ChatPage(
                  data: V2ChatPageData(state: state, queuedCount: 2),
                  onSend: (_) {},
                  onStop: () {},
                  onRetry: () {},
                  onSeePlans: () {},
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));

          for (final error in errors) {
            debugPrint('$state: $error');
          }
          expect(errors, isEmpty, reason: 'state $state overflowed');
        }
      },
    );
  }

  testWidgets('composer controls are reachable and labelled at 320 dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var attaches = 0;
    var mics = 0;
    var permissions = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onAttach: () => attaches++,
          onMic: () => mics++,
          onPermissionTap: () => permissions++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    for (final label in [
      'Open menu',
      'Open Studio',
      'Open Browser',
      'More options',
      'Attach a file',
      'Voice input',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(48), reason: label);
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
    }

    final permission = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Permission: General. Change' &&
          widget.properties.button == true,
    );
    expect(permission, findsOneWidget);
    expect(tester.getSize(permission).height, greaterThanOrEqualTo(48));

    await tester.tap(find.bySemanticsLabel('Attach a file'));
    await tester.tap(find.bySemanticsLabel('Voice input'));
    await tester.tap(permission);
    await tester.pump();

    expect(attaches, 1);
    expect(mics, 1);
    expect(permissions, 1);
  });

  testWidgets('send is announced as disabled until a draft exists', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(
        label: 'Send',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.pump();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(
        label: 'Send',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a long model label does not break the top bar', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      _app(
        const V2ChatPage(
          data: V2ChatPageData(modelLabel: 'Ovid Si Pro Reasoning'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(errors, isEmpty);
    expect(find.text('Ovid Si'), findsOneWidget);
  });
}
