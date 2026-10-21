import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';

Widget _app(
  Widget home, {
  bool dark = false,
  double textScale = 1,
  bool reducedMotion = false,
}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reducedMotion,
    ),
    child: child!,
  ),
  home: home,
);

const _items = <V2LiveChatItem>[
  V2LiveUserMessage(
    id: 'u1',
    text:
        'Can you build a clean personal portfolio landing page for me? I need dark mode and a projects showcase.',
    timeLabel: '10:24 AM',
  ),
  V2LiveThinking(
    id: 'think1',
    label: 'Thinking process (3.2s)',
    details: [
      'Use semantic HTML5 layout with a mobile-first hero.',
      'Set the palette to obsidian with violet accents.',
    ],
  ),
  V2LiveTool(
    id: 'tool1',
    title: 'Browsing modern portfolio trends',
    status: 'Analyzing 4 design systems on GitHub',
    progress: 0.72,
  ),
  V2LiveAssistantMessage(
    id: 'a1',
    markdown:
        'I designed and coded a sleek dark-mode portfolio for you called **Vortex Studio**. It features an interactive hero and project cards.',
  ),
  V2LiveArtifact(
    id: 'art1',
    fileName: 'portfolio-index.html',
    meta: '14.2 KB · Just generated',
    statusLabel: 'Ready',
    previewLabel: 'Interactive HTML5 canvas',
  ),
];

const _data = V2LiveChatData(
  sessionTitle: 'Personal Portfolio Page',
  items: _items,
);

void main() {
  testWidgets('renders the transcript in light', (tester) async {
    await tester.pumpWidget(_app(const V2LiveChatPage(data: _data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Personal Portfolio Page'), findsOneWidget);
    expect(
      find.textContaining('clean personal portfolio', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Thinking process (3.2s)'), findsOneWidget);
    expect(find.text('Browsing modern portfolio trends'), findsOneWidget);
    expect(
      find.textContaining('Vortex Studio', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('renders the transcript in dark', (tester) async {
    await tester.pumpWidget(
      _app(const V2LiveChatPage(data: _data), dark: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Thinking process (3.2s)'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
  });

  testWidgets('empty state action fires', (tester) async {
    var started = 0;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(),
          onStartChat: () => started++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('No messages yet'), findsOneWidget);
    await tester.tap(find.text('Start a chat'));
    expect(started, 1);
  });

  testWidgets('loading history shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(const V2LiveChatPage(data: V2LiveChatData(loading: true))),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            errorMessage: 'Ovid could not load this chat.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('send callback carries the typed text', (tester) async {
    String? sent;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(),
          onSend: (text) => sent = text,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), 'Add a contact drawer');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(sent, 'Add a contact drawer');
  });

  testWidgets('thinking row expands on tap', (tester) async {
    String? toggledId;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: _data,
          onThinkingToggle: (id, expanded) => toggledId = id,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text('Use semantic HTML5 layout with a mobile-first hero.'),
      findsNothing,
    );
    await tester.tap(find.text('Thinking process (3.2s)'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Use semantic HTML5 layout with a mobile-first hero.'),
      findsOneWidget,
    );
    expect(toggledId, 'think1');
  });

  testWidgets('artifact download reports its id', (tester) async {
    String? downloaded;
    await tester.pumpWidget(
      _app(V2LiveChatPage(data: _data, onDownload: (id) => downloaded = id)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.ensureVisible(find.text('Download'));
    await tester.pump();
    await tester.tap(find.text('Download'));
    expect(downloaded, 'art1');
  });

  testWidgets('stop button is shown while running', (tester) async {
    var stops = 0;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(items: _items, running: true),
          onStop: () => stops++,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Ovid is generating code...'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop_rounded));
    expect(stops, 1);
  });

  testWidgets('lays out at 320 dp with 200 % text in every state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const states = <String, V2LiveChatData>{
      'content': _data,
      'running': V2LiveChatData(items: _items, running: true),
      'empty': V2LiveChatData(),
      'error': V2LiveChatData(errorMessage: 'Ovid could not load this chat.'),
    };

    for (final dark in [false, true]) {
      for (final entry in states.entries) {
        await tester.pumpWidget(
          _app(V2LiveChatPage(data: entry.value), dark: dark, textScale: 2),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          tester.takeException(),
          isNull,
          reason:
              'overflow in ${entry.key} state at 320 dp / 200 % text '
              '(${dark ? 'dark' : 'light'})',
        );
      }
    }
  });

  testWidgets('primary controls expose semantic labels', (tester) async {
    await tester.pumpWidget(_app(const V2LiveChatPage(data: _data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.bySemanticsLabel('Open menu'), findsOneWidget);
    expect(find.bySemanticsLabel('Open Studio'), findsOneWidget);
    expect(find.bySemanticsLabel('Open Browser'), findsOneWidget);
    expect(find.bySemanticsLabel('More options'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Change model')), findsOneWidget);
    expect(find.bySemanticsLabel('Voice input'), findsOneWidget);
    expect(find.bySemanticsLabel('Attach a file'), findsOneWidget);

    await tester.ensureVisible(find.text('Download'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.bySemanticsLabel(RegExp('Download')), findsWidgets);
  });

  testWidgets('reduced motion still shows the whole transcript', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const V2LiveChatPage(data: _data), reducedMotion: true),
    );
    await tester.pump();

    // No entrance animation to wait for: rows are on screen at first paint.
    expect(find.text('Thinking process (3.2s)'), findsOneWidget);
    expect(find.text('Browsing modern portfolio trends'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);

    await tester.tap(find.text('Thinking process (3.2s)'));
    await tester.pump();
    expect(
      find.text('Use semantic HTML5 layout with a mobile-first hero.'),
      findsOneWidget,
    );
  });

  testWidgets('send is announced as disabled until text is typed', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2LiveChatPage(data: _data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(label: 'Send', isButton: true, isEnabled: false),
    );

    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.pump();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(label: 'Send', isButton: true, isEnabled: true),
    );
  });
}
