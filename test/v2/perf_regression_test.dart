// Performance regression guards for the minimal-UI surface.
//
// The refactor moved every screen onto `OScreen` / `OContent`. These tests
// pin the performance properties that refactor could quietly undo:
//
//  * a long list stays lazy (mounted rows are bounded, not proportional to
//    the data);
//  * typing in the composer does not rebuild the transcript;
//  * markdown is parsed once per unchanged message;
//  * a finished tool row has no ticker left running;
//  * image decoding is capped at the size the card is drawn at;
//  * reduced motion is read through `maybeDisableAnimationsOf`.
//
// Everything is counted (mounted widgets and element builds) rather than
// timed, so the numbers are deterministic on CI.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/message_blocks.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_tiles.dart';
import 'package:ovid_ai/ui/v2/library/artifacts_page.dart';
import 'package:ovid_ai/ui/v2/schedules/schedules_page.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';

Widget _app(Widget home) => MaterialApp(theme: OTheme.light(), home: home);

void _useScreen(WidgetTester tester, double width, {double height = 900}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

List<V2LiveChatItem> _thinkingItems(int count) => <V2LiveChatItem>[
  for (var i = 0; i < count; i++)
    V2LiveThinking(id: 't$i', label: 'Step $i', details: const ['detail']),
];

/// Counts element builds by widget runtime type through Flutter's debug seam.
///
/// This is a build counter, not a stopwatch: `debugOnRebuildDirtyWidget` fires
/// for every element the framework actually builds, including the first mount.
class _BuildRecorder {
  final Map<String, int> _counts = <String, int>{};

  void start() {
    _counts.clear();
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      final name = element.widget.runtimeType.toString();
      _counts[name] = (_counts[name] ?? 0) + 1;
    };
  }

  void stop() => debugOnRebuildDirtyWidget = null;

  int count(String widgetType) => _counts[widgetType] ?? 0;
}

/// Sidebar rows are private; match them by type name so the test can count the
/// mounted window without exporting the widget.
Finder _sidebarRows(String typeName) => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == typeName,
);

/// A valid 1x1 transparent PNG, enough to construct a real [MemoryImage].
const List<int> _tinyPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

void main() {
  group('chat transcript stays lazy', () {
    testWidgets('5,000 messages mount and build a bounded number of rows', (
      tester,
    ) async {
      _useScreen(tester, 800, height: 600);
      final recorder = _BuildRecorder()..start();
      addTearDown(recorder.stop);

      await tester.pumpWidget(
        _app(V2LiveChatPage(data: V2LiveChatData(items: _thinkingItems(5000)))),
      );
      await tester.pump();

      final mounted = find.byType(V2ThinkingTile).evaluate().length;
      final builds = recorder.count('V2ThinkingTile');

      expect(mounted, greaterThan(0));
      // A viewport of 600 dp holds well under 60 rows; an eager `ListView`
      // would mount all 5,000.
      expect(mounted, lessThan(60));
      expect(builds, lessThan(100));

      // Scroll a screenful: the mounted window stays bounded.
      await tester.drag(
        find.byKey(const ValueKey<String>('v2-live-transcript')),
        const Offset(0, -500),
      );
      await tester.pump();

      expect(find.byType(V2ThinkingTile).evaluate().length, lessThan(60));
    });

    testWidgets('row builds do not grow with the history length', (
      tester,
    ) async {
      _useScreen(tester, 800, height: 600);

      Future<int> buildsFor(int count) async {
        final recorder = _BuildRecorder()..start();
        await tester.pumpWidget(
          _app(
            V2LiveChatPage(data: V2LiveChatData(items: _thinkingItems(count))),
          ),
        );
        await tester.pump();
        final builds = recorder.count('V2ThinkingTile');
        recorder.stop();
        return builds;
      }

      final short = await buildsFor(20);
      final long = await buildsFor(5000);
      expect(short, greaterThan(0));
      // Only the visible window is built, so the count is flat, not linear.
      expect(long, lessThanOrEqualTo(short + 6));
    });

    testWidgets('typing in the composer does not rebuild the transcript', (
      tester,
    ) async {
      _useScreen(tester, 800, height: 700);
      String? draft;
      await tester.pumpWidget(
        _app(
          V2LiveChatPage(
            data: V2LiveChatData(items: _thinkingItems(12)),
            onDraftChanged: (value) => draft = value,
            onSend: (_) {},
          ),
        ),
      );
      await tester.pump();

      final before = tester.widget<V2ThinkingTile>(
        find.byType(V2ThinkingTile).first,
      );

      final recorder = _BuildRecorder()..start();
      addTearDown(recorder.stop);

      await tester.enterText(find.byType(TextField), 'hello world');
      await tester.pump();

      final after = tester.widget<V2ThinkingTile>(
        find.byType(V2ThinkingTile).first,
      );

      // Zero transcript builds for a keystroke; the composer updates its own
      // send state through the controller.
      expect(recorder.count('V2ThinkingTile'), 0);
      expect(identical(before, after), isTrue);
      expect(draft, 'hello world');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Send')),
        isSemantics(label: 'Send', isButton: true, isEnabled: true),
      );
    });

    testWidgets('a finished tool row keeps no animation running', (
      tester,
    ) async {
      _useScreen(tester, 800, height: 700);
      await tester.pumpWidget(
        _app(
          V2LiveChatPage(
            data: V2LiveChatData(
              items: <V2LiveChatItem>[
                for (var i = 0; i < 20; i++)
                  V2LiveTool(
                    id: 'tool$i',
                    title: 'Fetched page $i',
                    status: 'done',
                    progress: 1,
                  ),
              ],
            ),
          ),
        ),
      );
      // Let the one-shot entrance animations finish.
      await tester.pumpAndSettle();

      expect(find.byType(V2ToolTile), findsWidgets);
      // The progress bar only exists while a tool is running; a finished row
      // is visually still.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(OPulse), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('long library lists stay lazy', () {
    testWidgets('3,000 sidebar sessions mount a bounded number of rows', (
      tester,
    ) async {
      _useScreen(tester, 900, height: 900);
      final recorder = _BuildRecorder()..start();
      addTearDown(recorder.stop);

      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Sidebar(
              layout: SidebarLayout.rail,
              data: V2SidebarData(
                name: 'Alex',
                today: <V2SidebarSession>[
                  for (var i = 0; i < 3000; i++)
                    V2SidebarSession(
                      id: 's$i',
                      title: 'Session $i',
                      modelLabel: 'Auto',
                      timeLabel: '1h ago',
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final mounted = _sidebarRows('_SessionRow').evaluate().length;
      expect(mounted, greaterThan(0));
      expect(mounted, lessThan(60));
      expect(recorder.count('_SessionRow'), lessThan(80));
    });

    testWidgets('300 sidebar projects mount a bounded number of rows', (
      tester,
    ) async {
      _useScreen(tester, 900, height: 900);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Sidebar(
              layout: SidebarLayout.rail,
              data: V2SidebarData(
                name: 'Alex',
                projects: <V2SidebarProject>[
                  for (var i = 0; i < 300; i++)
                    V2SidebarProject(
                      id: 'p$i',
                      name: 'Project $i',
                      chatCount: i,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_sidebarRows('_ProjectRow').evaluate().length, lessThan(60));
    });

    testWidgets('400 artifacts mount and build a bounded grid window', (
      tester,
    ) async {
      _useScreen(tester, 800, height: 900);
      final recorder = _BuildRecorder()..start();
      addTearDown(recorder.stop);

      await tester.pumpWidget(
        _app(
          ArtifactsPage(
            data: V2ArtifactsData(
              artifacts: <V2ArtifactItem>[
                for (var i = 0; i < 400; i++)
                  V2ArtifactItem(
                    id: 'a$i',
                    name: 'file-$i.png',
                    kind: V2ArtifactKind.image,
                    createdAt: DateTime(2026, 5, 18),
                    sizeLabel: '10 KB',
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final mounted = find.byType(OCard).evaluate().length;
      expect(mounted, greaterThan(0));
      expect(mounted, lessThan(30));
      expect(recorder.count('OCard'), lessThan(40));
    });

    testWidgets('300 schedules mount and build a bounded list window', (
      tester,
    ) async {
      _useScreen(tester, 800, height: 900);
      final recorder = _BuildRecorder()..start();
      addTearDown(recorder.stop);

      await tester.pumpWidget(
        _app(
          SchedulesPage(
            data: V2SchedulesData(
              schedules: <V2ScheduleItem>[
                for (var i = 0; i < 300; i++)
                  V2ScheduleItem(
                    id: 's$i',
                    title: 'Schedule $i',
                    description: 'Runs every day',
                    rule: 'Every day at 9:00 AM',
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final mounted = find.byType(Switch).evaluate().length;
      expect(mounted, greaterThan(0));
      expect(mounted, lessThan(60));
      expect(recorder.count('Switch'), lessThan(80));
    });
  });

  group('markdown and images', () {
    testWidgets('unchanged messages are parsed once across rebuilds', (
      tester,
    ) async {
      _useScreen(tester, 800, height: 700);
      var parses = 0;
      v2MessageParseObserver = (_) => parses++;
      addTearDown(() => v2MessageParseObserver = null);

      await tester.pumpWidget(
        _app(
          V2LiveChatPage(
            data: V2LiveChatData(
              items: <V2LiveChatItem>[
                const V2LiveThinking(
                  id: 'think',
                  label: 'Step 0',
                  details: ['detail'],
                ),
                for (var i = 0; i < 30; i++)
                  V2LiveAssistantMessage(
                    id: 'a$i',
                    markdown: 'Message $i with **bold** and `code`.',
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final initial = parses;
      expect(initial, greaterThan(0));
      // One parse per distinct message, not one per visible row build.
      expect(initial, lessThanOrEqualTo(30));

      // Expanding a row rebuilds the visible window; the markdown is
      // unchanged, so nothing is parsed again.
      await tester.tap(find.text('Step 0'));
      await tester.pump();
      expect(parses, initial);

      // Scrolling away and back rebuilds rows from the cache; a message that
      // was parsed once is never parsed again.
      await tester.drag(
        find.byKey(const ValueKey<String>('v2-live-transcript')),
        const Offset(0, -600),
      );
      await tester.pump();
      final afterScroll = parses;
      expect(afterScroll, greaterThanOrEqualTo(initial));
      await tester.drag(
        find.byKey(const ValueKey<String>('v2-live-transcript')),
        const Offset(0, 600),
      );
      await tester.pump();
      expect(parses, afterScroll);

      // Typing is also not a parse trigger.
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.pump();
      expect(parses, afterScroll);
    });

    test('the parse cache returns the same block list for the same text', () {
      const markdown =
          '## Heading\n\nSome **bold** text with `code`.\n\n- a\n- b';
      final first = parseV2MessageBlocksCached(markdown);
      final second = parseV2MessageBlocksCached(markdown);
      expect(identical(first, second), isTrue);
      expect(first, isNotEmpty);
    });

    testWidgets('artifact thumbnails decode at the drawn card width', (
      tester,
    ) async {
      _useScreen(tester, 400, height: 800);
      final thumbnail = MemoryImage(Uint8List.fromList(_tinyPng));
      await tester.pumpWidget(
        _app(
          ArtifactsPage(
            data: V2ArtifactsData(
              artifacts: <V2ArtifactItem>[
                V2ArtifactItem(
                  id: 'img',
                  name: 'photo.png',
                  kind: V2ArtifactKind.image,
                  createdAt: DateTime(2026, 5, 18),
                  sizeLabel: '12 MB',
                  thumbnail: thumbnail,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image).first);
      final provider = image.image;
      expect(provider, isA<ResizeImage>());
      final resize = provider as ResizeImage;
      // Decode target is the width the card is actually drawn at (1 dpr),
      // never the 12 MP source resolution.
      expect(resize.width, isNotNull);
      expect(resize.width!, greaterThan(0));
      final displayWidth = tester.getSize(find.byType(Image).first).width;
      expect(resize.width!, closeTo(displayWidth, 2));
      expect(resize.width!, lessThanOrEqualTo(400));
    });
  });

  group('reduced motion', () {
    testWidgets('OMove.reduced follows the platform flag', (tester) async {
      late bool reduced;
      late bool animated;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: Builder(
                builder: (context) {
                  reduced = OMove.reduced(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: false),
              child: Builder(
                builder: (context) {
                  animated = OMove.reduced(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      expect(reduced, isTrue);
      expect(animated, isFalse);
    });

    test('OMove.reduced reads maybeDisableAnimationsOf, not MediaQuery.of', () {
      final source = File('lib/ui/design/o_motion.dart').readAsStringSync();
      final start = source.indexOf('static bool reduced(BuildContext context)');
      expect(start, greaterThanOrEqualTo(0));
      final body = source.substring(start, source.indexOf(';', start));
      expect(body, contains('maybeDisableAnimationsOf'));
      expect(body, isNot(contains('MediaQuery.of')));
    });
  });
}
