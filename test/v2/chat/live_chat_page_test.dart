
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/composer_attachments.dart';
import 'package:ovid_ai/ui/v2/chat/composer_row.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/model_chip.dart';
import 'package:ovid_ai/ui/v2/chat/queue_dock.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_actions.dart';
import 'package:ovid_ai/ui/v2/chat/voice_reply_card.dart';
import 'package:ovid_ai/ui/v2/library/artifact_detail_page.dart';

void _noop() {}

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
    href: 'https://files.example.com/portfolio-index.html',
  ),
  _voiceReply,
];

const _voiceReply = V2LiveVoiceReply(
  id: 'voice1',
  reply: V2VoiceReplyData(
    title: 'Your portfolio is ready',
    subtitle: 'A dark portfolio with four project cards.',
    metrics: [
      V2VoiceMetric(label: 'Projects', value: '4'),
      V2VoiceMetric(label: 'Load time', value: '0.8 s'),
    ],
    actionLabel: 'Open preview',
    transcript: 'I built the dark portfolio you asked for.',
    duration: Duration(seconds: 18),
    position: Duration(seconds: 4),
  ),
);

const _data = V2LiveChatData(
  sessionTitle: 'Personal Portfolio Page',
  items: _items,
);

/// The chat page as the shell mounts it. The header drops any control whose
/// handler is null, so a bare page has no menu, Studio or Browser glyph.
Widget _wired({V2LiveChatData data = _data}) => V2LiveChatPage(
  data: data,
  onMenu: _noop,
  onModelChipTap: _noop,
  onStudio: _noop,
  onBrowser: _noop,
  onMore: _noop,
  onAttach: _noop,
  onPlus: _noop,
  onMic: _noop,
  onSend: (_) {},
);

void main() {
  testWidgets('renders the transcript in light', (tester) async {
    await tester.pumpWidget(_app(const V2LiveChatPage(data: _data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Personal Portfolio Page'), findsOneWidget);
    expect(find.text('Ovid Si'), findsNothing);
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
    // The transcript is lazy: the artifact and the voice reply are the last
    // two rows, so they mount once the list scrolls to them.
    await tester.drag(
      find.byKey(const ValueKey<String>('v2-live-transcript')),
      const Offset(0, -3000),
    );
    await tester.pump();
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Actions for portfolio-index.html'),
      findsOneWidget,
    );
    expect(find.text('Your portfolio is ready'), findsOneWidget);
  });

  testWidgets('renders the transcript in dark', (tester) async {
    await tester.pumpWidget(
      _app(const V2LiveChatPage(data: _data), dark: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Thinking process (3.2s)'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey<String>('v2-live-transcript')),
      const Offset(0, -3000),
    );
    await tester.pump();
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

    expect(find.text('Ask Ovid anything'), findsOneWidget);
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

    await tester.drag(
      find.byKey(const ValueKey<String>('v2-live-transcript')),
      const Offset(0, -3000),
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Actions for portfolio-index.html'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(downloaded, 'art1');
  });

  testWidgets('the artifact row shows a real thumbnail when it has one', (
    tester,
  ) async {
    final png = Uint8List.fromList(const <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
      0x42, 0x60, 0x82,
    ]);
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveArtifact(
                id: 'art-thumb',
                fileName: 'hero.png',
                meta: 'Image',
                statusLabel: 'Ready',
                previewLabel: 'Preview',
                icon: Icons.image_outlined,
                thumbnail: MemoryImage(png),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNothing);
  });

  testWidgets('artifact Copy puts the inline text on the clipboard', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            items: [
              V2LiveArtifact(
                id: 'art-copy',
                fileName: 'preview.html',
                meta: 'Web page',
                statusLabel: 'Ready',
                previewLabel: 'Preview',
                content: '<h1>Real page</h1>',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.bySemanticsLabel('Actions for preview.html'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, '<h1>Real page</h1>');
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('voice reply wires play, seek and action to its id', (
    tester,
  ) async {
    String? played;
    String? acted;
    String? soughtId;
    Duration? sought;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(items: [_voiceReply]),
          onVoicePlay: (id) => played = id,
          onVoiceSeek: (id, position) {
            soughtId = id;
            sought = position;
          },
          onVoiceAction: (id) => acted = id,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.ensureVisible(find.bySemanticsLabel('Play voice reply'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Play voice reply'));
    expect(played, 'voice1');

    final waveform = find.byKey(const ValueKey('voice-reply-waveform'));
    await tester.ensureVisible(waveform);
    await tester.pump();
    await tester.tapAt(tester.getCenter(waveform));
    expect(soughtId, 'voice1');
    expect(sought!.inMilliseconds, inInclusiveRange(8500, 9500));

    await tester.ensureVisible(find.text('Open preview'));
    await tester.pump();
    await tester.tap(find.text('Open preview'));
    expect(acted, 'voice1');
  });

  testWidgets('voice reply transcript expands in place', (tester) async {
    String? toggledId;
    bool? expanded;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(items: [_voiceReply]),
          onVoiceTranscriptToggle: (id, value) {
            toggledId = id;
            expanded = value;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.ensureVisible(find.text('Show transcript'));
    await tester.pump();
    expect(
      find.text('I built the dark portfolio you asked for.'),
      findsNothing,
    );
    await tester.tap(find.text('Show transcript'));
    await tester.pump();

    expect(toggledId, 'voice1');
    expect(expanded, isTrue);
    expect(
      find.text('I built the dark portfolio you asked for.'),
      findsOneWidget,
    );
    expect(find.text('Hide transcript'), findsOneWidget);
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
    // The header subtitle is state-only: it exists while a run is active.
    expect(find.text('Working'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop_rounded));
    expect(stops, 1);
  });

  testWidgets('idle header has no subtitle line', (tester) async {
    await tester.pumpWidget(_app(const V2LiveChatPage(data: _data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Personal Portfolio Page'), findsOneWidget);
    expect(find.text('Working'), findsNothing);
    expect(find.text('Ovid Si'), findsNothing);
  });

  testWidgets('top bar reads menu, model, title, then actions', (tester) async {
    await tester.pumpWidget(_app(_wired()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    double x(Finder finder) => tester.getCenter(finder).dx;
    final title = find.text('Personal Portfolio Page');
    expect(
      x(find.bySemanticsLabel('Open menu')),
      lessThan(x(find.byType(V2ModelChip))),
    );
    expect(x(find.byType(V2ModelChip)), lessThan(x(title)));
    expect(x(title), lessThan(x(find.bySemanticsLabel('Open Studio'))));
    expect(
      x(find.bySemanticsLabel('Open Studio')),
      lessThan(x(find.bySemanticsLabel('Open Browser'))),
    );
    expect(
      x(find.bySemanticsLabel('Open Browser')),
      lessThan(x(find.bySemanticsLabel('More options'))),
    );
  });

  testWidgets('tablet composer stays inside the 720 dp column', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(const V2LiveChatPage(data: _data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final column = find.byKey(const ValueKey('v2-live-composer-column'));
    expect(tester.getSize(column).width, lessThanOrEqualTo(720));
    expect(tester.getTopLeft(column).dx, closeTo((1000 - 720) / 2, 1));
  });

  testWidgets('tablet transcript centres at 720 and bubbles cap at 560', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        const V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveUserMessage(id: 'u', text: 'hello'),
              V2LiveAssistantMessage(id: 'a', markdown: 'A reply'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final list = find.byKey(const ValueKey<String>('v2-live-transcript'));
    expect(tester.getSize(list).width, lessThanOrEqualTo(720));
    expect(tester.getTopLeft(list).dx, closeTo((1000 - 720) / 2, 1));

    final userBubble = tester.getSize(
      find
          .ancestor(of: find.text('hello'), matching: find.byType(Container))
          .first,
    );
    expect(userBubble.width, lessThanOrEqualTo(560));
    expect(userBubble.width, lessThanOrEqualTo(720 * 0.78));

    // The assistant answer has no card and no inner cap: it spans the whole
    // content column (720 minus the 24 dp gutters).
    final reply = tester.getSize(
      find.textContaining('A reply', findRichText: true),
    );
    expect(reply.width, closeTo(720 - 2 * OSpace.xl, 1));
  });

  testWidgets('long unbroken user text wraps at 320 dp and 200 % text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveUserMessage(id: 'u', text: 'a' * 240),
              V2LiveAssistantMessage(id: 'a', markdown: 'b' * 240),
            ],
          ),
        ),
        textScale: 2,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
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
    await tester.pumpWidget(_app(_wired()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.bySemanticsLabel('Open menu'), findsOneWidget);
    expect(find.bySemanticsLabel('Open Studio'), findsOneWidget);
    expect(find.bySemanticsLabel('Open Browser'), findsOneWidget);
    expect(find.bySemanticsLabel('More options'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Change model')), findsOneWidget);
    expect(find.bySemanticsLabel('Voice input'), findsOneWidget);
    expect(find.bySemanticsLabel('Add attachment or action'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey<String>('v2-live-transcript')),
      const Offset(0, -3000),
    );
    await tester.pump();
    // The row's actions live in one labelled menu, not an icon per action.
    expect(
      find.bySemanticsLabel(RegExp('Actions for')),
      findsOneWidget,
    );
  });

  testWidgets('composer is exactly one row in the contract order', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(items: _items),
          onAttach: _noop,
          onPlus: _noop,
          onMic: _noop,
          onSend: (_) {},
          onPermissionTap: _noop,
          permissionLabel: 'Studio',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final stack = tester.widget<Column>(
      find.byKey(const ValueKey('v2-live-composer-stack')),
    );
    expect(stack.children.whereType<V2ComposerRow>(), hasLength(1));
    expect(stack.children.whereType<Row>(), isEmpty);

    final permission = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Permission: Studio. Change',
    );
    final plus = find.bySemanticsLabel('Add attachment or action');
    final field = find.byType(TextField);
    final mic = find.bySemanticsLabel('Voice input');
    final send = find.bySemanticsLabel('Send');
    final centres = [
      plus,
      permission,
      field,
      mic,
      send,
    ].map(tester.getCenter).toList();
    for (var i = 1; i < centres.length; i++) {
      expect(
        centres[i].dx,
        greaterThan(centres[i - 1].dx),
        reason: 'control $i must sit right of control ${i - 1}',
      );
      expect(
        centres[i].dy,
        closeTo(centres.first.dy, 1),
        reason: 'control $i must share the composer row',
      );
    }
    expect(tester.widget<TextField>(field).minLines, 1);
    expect(tester.widget<TextField>(field).maxLines, 3);
  });

  testWidgets('reduced motion still shows the whole transcript', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const V2LiveChatPage(data: _data), reducedMotion: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // No entrance animation to wait for: the first rows are on screen at
    // first paint. The list is still lazy, so the last rows need a scroll.
    expect(find.text('Thinking process (3.2s)'), findsOneWidget);
    expect(find.text('Browsing modern portfolio trends'), findsOneWidget);

    await tester.tap(find.text('Thinking process (3.2s)'));
    await tester.pump();
    expect(
      find.text('Use semantic HTML5 layout with a mobile-first hero.'),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey<String>('v2-live-transcript')),
      const Offset(0, -3000),
    );
    await tester.pump();
    expect(find.text('portfolio-index.html'), findsOneWidget);
  });

  testWidgets('send is announced as disabled until text is typed', (
    tester,
  ) async {
    // A composer with a real send handler: with none, Send stays disabled by
    // design (no control may announce a send that goes nowhere).
    await tester.pumpWidget(_app(V2LiveChatPage(data: _data, onSend: (_) {})));
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

  testWidgets('top bar uses the shared model chip with plan and subagents', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            items: _items,
            modelLabel: 'Ovid Pro 1.5',
            autoOnly: true,
            subagentCount: 2,
          ),
          onModelChipTap: () => taps++,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final chip = tester.widget<V2ModelChip>(find.byType(V2ModelChip));
    expect(chip.label, 'Ovid Pro 1.5');
    expect(chip.autoOnly, isTrue);
    expect(chip.subagentCount, 2);
    expect(chip.enabled, isTrue);
    expect(
      find.bySemanticsLabel(
        'Model: Ovid Pro 1.5. Auto only. 2 subagents. Change model',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byType(V2ModelChip));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('model chip is disabled when the host cannot change models', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2LiveChatPage(data: _data)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final chip = tester.widget<V2ModelChip>(find.byType(V2ModelChip));
    expect(chip.enabled, isFalse);
    expect(
      find.bySemanticsLabel('Model: Auto. Model selection unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('plus callback replaces the file picker', (tester) async {
    var plus = 0;
    var attaches = 0;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(),
          onPlus: () => plus++,
          onAttach: () => attaches++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.bySemanticsLabel('Add attachment or action'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('Attach a file'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pump();

    expect(plus, 1);
    expect(attaches, 0);
  });

  testWidgets('composer opens its plus menu and File reaches the host seam', (
    tester,
  ) async {
    var attaches = 0;
    await tester.pumpWidget(
      _app(V2LiveChatPage(data: _data, onAttach: () => attaches++)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.bySemanticsLabel('Add attachment or action'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('Attach a file'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pumpAndSettle();
    expect(find.text('Add to chat'), findsOneWidget);

    final fileRow = find.byKey(const ValueKey('composer-plus-file'));
    await tester.ensureVisible(fileRow);
    await tester.pumpAndSettle();
    await tester.tap(fileRow);
    await tester.pumpAndSettle();

    expect(attaches, 1);
  });

  testWidgets('queued messages surface in the dock above the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            items: _items,
            running: true,
            queuedCount: 1,
            queuedPreview: 'Then add testimonials',
          ),
          onStop: _noop,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(V2QueueDock), findsOneWidget);
    expect(find.text('1 queued'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(V2QueueDock)).dy,
      lessThan(tester.getTopLeft(find.byType(TextField)).dy),
    );
  });

  testWidgets('a finished tool has no running progress and expands on tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveTool(
                id: 'tool-done',
                title: 'GitHub · list repos',
                status: 'ok',
                progress: 1,
                details: ['Found 12 repositories.'],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('GitHub · list repos'), findsOneWidget);
    // Collapsed rows are one line: the state is the glyph, not a label.
    expect(find.text('Done'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'a finished tool must not keep a progress animation',
    );
    expect(find.text('Found 12 repositories.'), findsNothing);

    await tester.tap(find.text('GitHub · list repos'));
    await tester.pump();

    expect(find.text('Found 12 repositories.'), findsOneWidget);
    // The check glyph already said "Done"; expanding must not repeat it.
    expect(find.text('Status: Done'), findsNothing);

    await tester.tap(find.text('GitHub · list repos'));
    await tester.pump();
    expect(find.text('Found 12 repositories.'), findsNothing);
  });

  testWidgets('a running tool shows its real progress', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveTool(
                id: 'tool-running',
                title: 'Browsing',
                status: 'running',
                progress: 0.4,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.4, 0.001));
  });

  testWidgets('tapping an artifact opens the artifact detail route', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveArtifact(
                id: 'art-route',
                fileName: 'portfolio-index.html',
                meta: '14.2 KB',
                statusLabel: 'Ready',
                previewLabel: 'Interactive HTML5 canvas',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('portfolio-index.html'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ArtifactDetailPage), findsOneWidget);
  });

  testWidgets('artifact tap prefers the host route when provided', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            items: [
              V2LiveArtifact(
                id: 'art-host',
                fileName: 'report.pdf',
                meta: '2.1 MB',
                statusLabel: 'Ready',
                previewLabel: 'PDF document',
              ),
            ],
          ),
          onArtifactTap: (id) => opened = id,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('report.pdf'));
    expect(opened, 'art-host');
    expect(find.byType(ArtifactDetailPage), findsNothing);
  });

  testWidgets('live permission chip appears only with a host handler', (
    tester,
  ) async {
    var changes = 0;
    final chip = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Permission: Studio. Change' &&
          widget.properties.button == true,
    );

    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(items: _items),
          onPermissionTap: () => changes++,
          permissionLabel: 'Studio',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pump();
    expect(changes, 1);

    // Without a handler the chip is absent instead of dead.
    await tester.pumpWidget(
      _app(const V2LiveChatPage(data: V2LiveChatData(items: _items))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            (widget.properties.label ?? '').startsWith('Permission:'),
      ),
      findsNothing,
    );
  });

  testWidgets('Enter sends the live draft and Shift+Enter does not', (
    tester,
  ) async {
    V2ComposerSubmission? sent;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(items: _items),
          onSubmit: (submission) => sent = submission,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(find.byType(TextField), 'Continue the build');
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(sent, isNull, reason: 'Shift+Enter must not send');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sent, isNotNull);
    expect(sent!.text, 'Continue the build');
  });

  testWidgets('transcript links use the real opener and saver by default', (
    tester,
  ) async {
    addTearDown(V2TranscriptIo.reset);
    Uri? opened;
    V2TranscriptIo.debugOpenOverride = (uri) async {
      opened = uri;
      return true;
    };

    await tester.pumpWidget(
      _app(
        const V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveAssistantMessage(
                id: 'links',
                markdown:
                    '[Open docs](https://docs.example.com)\n\n'
                    '[report.txt](ftp://example.com/report.txt)',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.ensureVisible(find.bySemanticsLabel('Open docs'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Open docs'));
    await tester.pump();
    expect(opened, Uri.parse('https://docs.example.com'));

    final download = find.bySemanticsLabel('Download report.txt');
    await tester.ensureVisible(download);
    await tester.pump();
    await tester.tap(download);
    await tester.pump();
    expect(find.text('This file cannot be downloaded.'), findsOneWidget);
  });
}
