import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/widgets/attachment_tiles.dart';

const _longPdf =
    'very_long_quarterly_financial_report_name_for_the_board_final.pdf';
const _longXlsx = 'another_extremely_long_spreadsheet_file_name_2026.xlsx';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('middleEllipsize', () {
    test('keeps both stem ends and the whole extension', () {
      final s = middleEllipsize('very_long_report_name_final.pdf', 12);
      expect(s, 'very_lo\u2026final.pdf');
      expect(s, endsWith('.pdf'));
    });

    test('returns short names unchanged', () {
      expect(middleEllipsize('a.txt', 10), 'a.txt');
    });

    test('names without an extension are shortened in the middle', () {
      expect(middleEllipsize('Makefile_with_long_name', 8), 'Make\u2026name');
    });

    test('never splits grapheme clusters', () {
      final s = middleEllipsize('👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧.png', 2);
      expect(s, '👨‍👩‍👧…👨‍👩‍👧.png');
    });
  });

  test('kind by extension', () {
    expect(attachmentKindFor('x.PDF'), AttachmentKind.pdf);
    expect(attachmentKindFor('x.docx'), AttachmentKind.doc);
    expect(attachmentKindFor('x.xlsx'), AttachmentKind.sheet);
    expect(attachmentKindFor('x.csv'), AttachmentKind.csv);
    expect(attachmentKindFor('x.zip'), AttachmentKind.archive);
    expect(attachmentKindFor('x.dart'), AttachmentKind.code);
    expect(attachmentKindFor('x.m4a'), AttachmentKind.audio);
    expect(attachmentKindFor('x.mov'), AttachmentKind.video);
    expect(attachmentKindFor('x.jpeg'), AttachmentKind.image);
    expect(attachmentKindFor('README'), AttachmentKind.other);
    expect(attachmentKindFor('.env'), AttachmentKind.other);
  });

  Future<void> pumpHost(
    WidgetTester tester,
    Widget child, {
    double width = 320,
    double scale = 1,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? Aether.theme(),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: c!,
        ),
        home: Scaffold(
          body: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    );
    await tester.pump();
  }

  List<AttachmentTileData> mixed() => const [
    AttachmentTileData(name: 'photo.jpg', size: 2400000, path: '/w/photo.jpg'),
    AttachmentTileData(name: _longPdf, size: 1258291, path: '/w/r.pdf'),
    AttachmentTileData(name: 'shot.png', size: 900000, path: '/w/shot.png'),
    AttachmentTileData(name: _longXlsx, size: 48000, path: '/w/s.xlsx'),
  ];

  group('composer row', () {
    for (final scale in [1.0, 2.0]) {
      for (final dark in [false, true]) {
        testWidgets('images + long names fit one row at 320dp, ${scale}x, '
            '${dark ? 'dark' : 'light'}', (tester) async {
          final removed = <String>[];
          await pumpHost(
            tester,
            ComposerAttachmentRow(
              scrollKey: const ValueKey('row'),
              items: mixed(),
              max: 20,
              onRemove: (a) => removed.add(a.name),
            ),
            scale: scale,
            theme: Aether.themeFor(dark: dark),
          );
          expect(tester.takeException(), isNull);
          final row = find.byKey(const ValueKey('row'));
          expect(tester.getSize(row).height, lessThanOrEqualTo(72));
          // Horizontal, not wrapping.
          final scrollable = tester.widget<Scrollable>(
            find.descendant(of: row, matching: find.byType(Scrollable)),
          );
          expect(scrollable.axisDirection, AxisDirection.right);
          // Image thumbnails are square.
          final thumb = find.byType(AttachmentImageThumb).first;
          expect(tester.getSize(thumb), const Size(56, 56));
          // File cards are compact and their names keep the extension.
          final card = find.byType(AttachmentFileCard).first;
          expect(tester.getSize(card).width, lessThanOrEqualTo(180));
          expect(tester.getSize(card).height, lessThanOrEqualTo(56));
          final name = tester.widget<Text>(
            find
                .descendant(
                  of: card,
                  matching: find.descendant(
                    of: find.byType(MiddleEllipsisText),
                    matching: find.byType(Text),
                  ),
                )
                .first,
          );
          // The test font is very wide, so only a few characters fit;
          // the head, the tail and the extension all survive.
          final shown = name.data!;
          expect(shown, contains('\u2026'));
          expect(shown, endsWith('l.pdf'));
          expect(_longPdf, startsWith(shown.split('\u2026').first));
          expect(_longPdf, endsWith(shown.split('\u2026').last));
          expect(find.text(_longPdf), findsNothing);
        });
      }
    }

    testWidgets('remove button has a 48dp target and removes that file', (
      tester,
    ) async {
      final removed = <String>[];
      final semantics = tester.ensureSemantics();
      await pumpHost(
        tester,
        ComposerAttachmentRow(
          items: mixed(),
          max: 20,
          onRemove: (a) => removed.add(a.name),
        ),
      );
      final remove = find.byTooltip('Remove attachment $_longPdf');
      expect(remove, findsOneWidget);
      final size = tester.getSize(remove);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(
        tester
            .getSemantics(remove)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      await tester.tap(remove);
      expect(removed, [_longPdf]);
      semantics.dispose();
    });

    testWidgets('tiles expose full name, type and size to screen readers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpHost(
        tester,
        ComposerAttachmentRow(items: mixed(), max: 20, onRemove: (_) {}),
      );
      expect(
        find.bySemanticsLabel('$_longPdf, PDF document, 1.2 MB'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('photo.jpg, Image, 2.3 MB'), findsOneWidget);
      await pumpHost(
        tester,
        ComposerAttachmentRow(
          items: [mixed()[3], mixed()[1]],
          max: 20,
          onRemove: (_) {},
        ),
      );
      expect(
        find.bySemanticsLabel('$_longXlsx, Spreadsheet, 47 KB'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('long-press shows the full name in a tooltip', (tester) async {
      await pumpHost(
        tester,
        ComposerAttachmentRow(items: mixed(), max: 20, onRemove: (_) {}),
      );
      await tester.longPress(find.byType(AttachmentFileCard).first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_longPdf), findsOneWidget);
    });

    testWidgets('tap opens the image viewer or the file info sheet', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpHost(
        tester,
        ComposerAttachmentRow(
          items: mixed(),
          max: 20,
          onRemove: (_) {},
          onOpenImage: opened.add,
        ),
      );
      await tester.tap(find.byType(AttachmentImageThumb).first);
      expect(opened, ['/w/photo.jpg']);

      await tester.tap(find.byType(AttachmentFileCard).first);
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('attachment-info-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text(_longPdf)),
        findsOneWidget,
      );
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('PDF document · 1.2 MB'), findsOneWidget);
    });

    testWidgets('staging placeholder shows progress', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpHost(
        tester,
        ComposerAttachmentRow(
          items: const [],
          staging: 1,
          max: 20,
          onRemove: (_) {},
        ),
      );
      expect(
        find.byKey(const ValueKey('attachment-staging-tile')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel('Adding file…'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('count hint appears only near the limit', (tester) async {
      List<AttachmentTileData> n(int count) => [
        for (var i = 0; i < count; i++)
          AttachmentTileData(name: 'f$i.txt', size: 10, path: '/w/$i.txt'),
      ];
      await pumpHost(
        tester,
        ComposerAttachmentRow(items: n(14), max: 20, onRemove: (_) {}),
      );
      expect(find.textContaining('/20 files'), findsNothing);
      await pumpHost(
        tester,
        ComposerAttachmentRow(items: n(15), max: 20, onRemove: (_) {}),
      );
      expect(find.text('15/20 files'), findsOneWidget);
    });

    testWidgets('right-to-left puts the remove button on the start corner', (
      tester,
    ) async {
      await pumpHost(
        tester,
        Directionality(
          textDirection: TextDirection.rtl,
          child: ComposerAttachmentRow(
            items: const [
              AttachmentTileData(name: 'a.pdf', size: 1, path: '/w/a.pdf'),
            ],
            max: 20,
            onRemove: (_) {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.byType(AttachmentFileCard));
      final remove = tester.getRect(find.byTooltip('Remove attachment a.pdf'));
      expect(remove.left, lessThan(card.left));
    });
  });

  group('transcript', () {
    List<AttachmentTileData> images(int n) => [
      for (var i = 0; i < n; i++)
        AttachmentTileData(name: 'img$i.png', size: 1000, path: '/w/$i.png'),
    ];

    Set<double> columns(WidgetTester tester) => {
      for (final e in find.byType(AttachmentImageThumb).evaluate())
        tester.getTopLeft(find.byWidget(e.widget)).dx,
    };

    testWidgets('four images form a 2-column grid, three a 3-column grid', (
      tester,
    ) async {
      await pumpHost(
        tester,
        SizedBox(width: 280, child: TranscriptAttachments(items: images(4))),
      );
      expect(columns(tester), hasLength(2));
      await pumpHost(
        tester,
        SizedBox(width: 280, child: TranscriptAttachments(items: images(3))),
      );
      expect(columns(tester), hasLength(3));
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('images + files never overflow at 320dp, ${scale}x', (
        tester,
      ) async {
        final opened = <String>[];
        await pumpHost(
          tester,
          SizedBox(
            width: 240,
            child: TranscriptAttachments(
              items: [
                ...images(5),
                const AttachmentTileData(name: _longPdf, size: 1258291),
                const AttachmentTileData(
                  name: _longXlsx,
                  size: 48000,
                  path: '/w/s.xlsx',
                ),
              ],
              onOpenImage: opened.add,
            ),
          ),
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        final box = tester.getRect(
          find.byKey(const ValueKey('transcript-attachments')),
        );
        expect(box.width, lessThanOrEqualTo(240));
        for (final e in find.byType(AttachmentFileCard).evaluate()) {
          final r = tester.getRect(find.byWidget(e.widget));
          expect(r.width, lessThanOrEqualTo(180));
          expect(r.right, lessThanOrEqualTo(box.right + 0.01));
        }
        await tester.tap(find.byType(AttachmentImageThumb).first);
        expect(opened, ['/w/0.png']);
        // A file from an older message without a stored path still opens
        // its info sheet, which says the file is gone.
        await tester.tap(find.byType(AttachmentFileCard).first);
        await tester.pumpAndSettle();
        expect(
          find.text('This file is no longer available on this device.'),
          findsOneWidget,
        );
      });
    }
  });

  group('chat screen', () {
    late ChatSession session;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      app.seenWelcomeVersion = AppState.welcomeVersion;
      AgentService.I.debugPauseScheduleTimerForTest(true);
      session = ChatSession(
        id: 'attachment-tiles',
        title: 'Chat',
        model: 'm',
        messages: [
          Message(
            role: 'user',
            content: 'Look at these',
            attachments: [
              MessageAttachment(name: 'a.png', size: 1000, path: '/w/a.png'),
              MessageAttachment(name: 'b.png', size: 1000, path: '/w/b.png'),
              MessageAttachment(name: _longPdf, size: 1258291, path: '/w/r'),
            ],
          ),
          Message(role: 'assistant', content: 'Ready'),
        ],
      );
      app.sessions
        ..clear()
        ..add(session);
      app.activeSessionId = session.id;
      AgentService.I.clearAttachment();
    });

    tearDown(() {
      AgentService.I.clearAttachment();
      AppState.resetTestInstance();
    });

    Future<void> pumpChat(WidgetTester tester, {double scale = 1}) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const ChatScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('sent message shows compact tiles at 320dp, ${scale}x', (
        tester,
      ) async {
        await pumpChat(tester, scale: scale);
        expect(tester.takeException(), isNull);
        expect(find.byType(TranscriptAttachments), findsOneWidget);
        expect(find.byType(AttachmentImageThumb), findsNWidgets(2));
        expect(find.byType(AttachmentFileCard), findsOneWidget);
        expect(find.text(_longPdf), findsNothing);
      });
    }

    testWidgets('transcript image opens the fullscreen viewer', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byType(AttachmentImageThumb).first);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byTooltip('Share'), findsOneWidget);
    });

    testWidgets('composer shows staged files as one compact row', (
      tester,
    ) async {
      AgentService.I.pendingAttachments.addAll([
        (name: 'pic.jpg', path: '/w/pic.jpg', size: 3000),
        (name: _longPdf, path: '/w/r.pdf', size: 1258291),
      ]);
      await pumpChat(tester, scale: 2);
      expect(tester.takeException(), isNull);
      final row = find.byKey(const ValueKey('composer-attachments-scroll'));
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, lessThanOrEqualTo(72));
      await tester.tap(find.byTooltip('Remove attachment $_longPdf'));
      await tester.pump();
      expect(AgentService.I.pendingAttachments.map((a) => a.name), ['pic.jpg']);
    });
  });
}
