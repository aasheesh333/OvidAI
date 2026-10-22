import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';

/// Structural golden for the live chat screen.
///
/// This repository keeps no PNG goldens: they pin a Flutter version's text
/// rasteriser more than the layout. The golden here is the *composition* — one
/// canonical fixture, pumped once, with the screen's regions asserted in visual
/// order and the composer asserted as a single row. A layout change that moves,
/// duplicates, drops or reorders a region fails this test, which is the part of
/// a pixel golden that is worth keeping.
///
/// Keep the fixture boring and fixed: no clocks, no network, no caller data
/// that changes between runs.
const _fixture = V2LiveChatData(
  sessionId: 'golden',
  sessionTitle: 'Landing page',
  modelLabel: 'Auto',
  items: <V2LiveChatItem>[
    V2LiveUserMessage(id: 'u1', text: 'Build a landing page'),
    V2LiveThinking(
      id: 't1',
      label: 'Thinking',
      details: <String>['Read the brief', 'Chose one column'],
    ),
    V2LiveTool(
      id: 'tool1',
      title: 'Writing index.html',
      status: 'Done',
      progress: 1,
    ),
    V2LiveAssistantMessage(
      id: 'a1',
      markdown: 'The page is ready. **One column**, no decoration.',
    ),
    V2LiveArtifact(
      id: 'art1',
      fileName: 'index.html',
      meta: 'HTML · 4 KB',
      statusLabel: 'Ready',
      previewLabel: 'Landing page',
      href: 'https://example.test/index.html',
    ),
  ],
  running: false,
  draft: 'Make it calmer',
);

Future<void> _pump(WidgetTester tester, {bool dark = false}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: V2LiveChatPage(
        data: _fixture,
        onMenu: () {},
        onModelChipTap: () {},
        onSend: (_) {},
        onStop: () {},
        onAttach: () {},
        onMic: () {},
        onPermissionTap: () {},
        permissionLabel: 'General',
      ),
    ),
  );
  // Let the entrance animations and the transcript settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Top edge of the first match, for order assertions.
double _top(WidgetTester tester, Finder finder) =>
    tester.getTopLeft(finder.first).dy;

void main() {
  testWidgets('live chat composition is the golden', (tester) async {
    await _pump(tester);

    // Exactly one header: the session name, not the product name again.
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Landing page'),
      ),
      findsOneWidget,
    );

    final order = <String, double>{
      'header': _top(tester, find.byType(AppBar)),
      'user': _top(tester, find.text('Build a landing page')),
      'thinking': _top(tester, find.text('Thinking')),
      'tool': _top(tester, find.text('Writing index.html')),
      'assistant': _top(
        tester,
        find.textContaining('The page is ready.', findRichText: true),
      ),
      'artifact': _top(tester, find.text('index.html')),
      'composer': _top(tester, find.text('Make it calmer')),
    };

    final tops = order.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    expect(
      tops.map((e) => e.key).toList(),
      <String>[
        'header',
        'user',
        'thinking',
        'tool',
        'assistant',
        'artifact',
        'composer',
      ],
      reason:
          'one header, then transcript order, then the composer — the shape of '
          'the screen is the golden',
    );

    // Nothing is repeated: the permanent model/token line and the idle status
    // row are gone, and "Ready" repeats the artifact row itself.
    expect(find.text('Auto · 50M tokens left today'), findsNothing);
    expect(find.text('Ready'), findsNothing);
    expect(find.text('Press stop to pause'), findsNothing);
  });

  testWidgets('the composer is one row of controls', (tester) async {
    await _pump(tester);

    final field = find.byType(TextField);
    final voice = find.bySemanticsLabel('Voice input');
    final plus = find.bySemanticsLabel('Add attachment or action');
    final send = find.bySemanticsLabel('Send');

    expect(field, findsOneWidget);
    expect(voice, findsOneWidget);
    expect(plus, findsOneWidget);
    expect(send, findsOneWidget);

    // One row: every control shares the field's vertical centre band.
    final centre = tester.getCenter(field).dy;
    for (final finder in <Finder>[voice, plus, send]) {
      expect(
        (tester.getCenter(finder).dy - centre).abs(),
        lessThan(24),
        reason: 'composer controls must sit on the field row',
      );
    }

    // The permission chip is a control: it only renders with a handler.
    expect(find.text('General'), findsOneWidget);
  });

  testWidgets('the golden composition holds in dark', (tester) async {
    await _pump(tester, dark: true);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Build a landing page'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
