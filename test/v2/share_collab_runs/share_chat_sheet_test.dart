import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/share/share_chat_sheet.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

V2ShareChatSheetData _data({
  bool active = true,
  V2ShareStatus status = V2ShareStatus.ready,
  String creatorName = '',
}) {
  return V2ShareChatSheetData(
    link: 'https://ovid.si/c/8f92a10c',
    active: active,
    status: status,
    creatorName: creatorName,
  );
}

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  // Let the staggered fade-ins start and finish so every row is in the
  // semantics tree and fully painted.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps at the smallest supported width with the largest supported text size.
Future<void> _pumpSmall(
  WidgetTester tester,
  Widget child,
  ThemeData theme,
) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 640),
          textScaler: const TextScaler.linear(2),
        ),
        child: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('renders the fork note and chat link in light and dark', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(
        tester,
        ShareChatSheet(data: _data(), onStopSharing: () {}),
        theme,
      );

      expect(find.text('Share this chat'), findsOneWidget);
      expect(
        find.text('Anyone with the link can view or fork it.'),
        findsOneWidget,
      );
      expect(find.text('https://ovid.si/c/8f92a10c'), findsOneWidget);
      expect(
        find.text(
          'Forking makes a copy in their own account. Your original stays private.',
        ),
        findsOneWidget,
      );
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
      expect(
        find.text('Shared chats never include your files or connectors.'),
        findsOneWidget,
      );
    }
  });

  testWidgets('empty state creates a link', (tester) async {
    var created = 0;
    await _pump(
      tester,
      ShareChatSheet(data: _data(active: false), onCreateLink: () => created++),
      OTheme.light(),
    );

    expect(find.text('This chat is not shared yet'), findsOneWidget);
    await tester.ensureVisible(find.text('Create link'));
    await tester.pump();
    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, 1);
  });

  testWidgets('error state shows retry and fires it', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      ShareChatSheet(
        data: _data(status: V2ShareStatus.error),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );

    expect(find.text('We could not load the share link.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('copy link callback fires', (tester) async {
    var copies = 0;
    await _pump(
      tester,
      ShareChatSheet(data: _data(), onCopyLink: () => copies++),
      OTheme.light(),
    );

    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 1);
  });

  testWidgets('show my name toggle uses the chat variant callbacks', (
    tester,
  ) async {
    bool? showName;
    await _pump(
      tester,
      ShareChatSheet(
        data: _data(),
        onToggleShowName: (value) => showName = value,
      ),
      OTheme.dark(),
    );

    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    expect(showName, isFalse);
  });

  testWidgets('share target reports which target was picked', (tester) async {
    V2ShareTarget? chosen;
    await _pump(
      tester,
      ShareChatSheet(
        data: _data(),
        onShareTarget: (target) => chosen = target,
      ),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('WhatsApp'));
    await tester.pump();
    await tester.tap(find.text('WhatsApp'));
    await tester.pump();
    expect(chosen, V2ShareTarget.whatsApp);
  });

  testWidgets('no placeholder person is shown by default', (tester) async {
    await _pump(
      tester,
      ShareChatSheet(data: _data(), onToggleShowName: (_) {}),
      OTheme.light(),
    );
    expect(find.text('Displays you as creator'), findsOneWidget);
    expect(find.textContaining('Aarav'), findsNothing);

    await _pump(
      tester,
      ShareChatSheet(
        data: _data(creatorName: 'Meera Nair'),
        onToggleShowName: (_) {},
      ),
      OTheme.light(),
    );
    expect(find.text('Displays Meera Nair as creator'), findsOneWidget);
  });

  testWidgets('controls keep their labels and 48 dp target', (tester) async {
    await _pump(
      tester,
      ShareChatSheet(
        data: _data(),
        onCopyLink: () {},
        onClose: () {},
        onShareTarget: (_) {},
        onStopSharing: () {},
      ),
      OTheme.light(),
    );

    for (final label in ['Copy link', 'Stop sharing']) {
      final finder = find.widgetWithText(OButton, label);
      expect(finder, findsOneWidget);
      expect(
        tester.getSize(finder).height,
        greaterThanOrEqualTo(48),
        reason: '$label is too short to tap',
      );
    }

    void expectSemanticLabel(Finder content, String expected) {
      final labels = tester
          .widgetList<Semantics>(
            find.ancestor(of: content, matching: find.byType(Semantics)),
          )
          .map((semantics) => semantics.properties.label);
      expect(labels, contains(expected));
    }

    expectSemanticLabel(find.text('WhatsApp'), 'Share on WhatsApp');
    expectSemanticLabel(find.text('Copy link'), 'Copy link');
    expectSemanticLabel(find.byIcon(Icons.close_rounded), 'Close share sheet');
    expect(
      tester.getSize(find.byType(OIconButton)).width,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('the chat variant offers Collab and Read only before sharing', (
    tester,
  ) async {
    V2ShareMode? picked;
    await _pump(
      tester,
      ShareChatSheet(
        data: _data(),
        onModeChanged: (mode) => picked = mode,
      ),
      OTheme.light(),
    );

    expect(find.text('Collab'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    expect(
      find.text('Anyone with the link can view or fork it.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Collab'));
    await tester.pump();
    expect(picked, V2ShareMode.collab);

    await _pump(
      tester,
      ShareChatSheet(
        data: V2ShareChatSheetData(
          link: 'https://ovid.si/c/8f92a10c',
          mode: V2ShareMode.collab,
          memberCount: 4,
        ),
      ),
      OTheme.dark(),
    );

    expect(find.text('4 of 50 members'), findsOneWidget);
    expect(find.text('One person sends at a time'), findsOneWidget);
    expect(find.text('You pay for storage'), findsOneWidget);
    expect(
      find.textContaining('Up to 50 people can join'),
      findsOneWidget,
    );
    expect(
      find.text('Anyone with the link can view or fork it.'),
      findsNothing,
    );
    expect(find.text('Fork into my account'), findsNothing);
  });

  testWidgets('a read-only chat viewer can fork the chat', (tester) async {
    var forks = 0;
    await _pump(
      tester,
      ShareChatSheet(
        data: V2ShareChatSheetData(
          link: 'https://ovid.si/c/8f92a10c',
          viewerCanFork: true,
        ),
        onFork: () => forks++,
      ),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Fork into my account'));
    await tester.pump();
    await tester.tap(find.text('Fork into my account'));
    await tester.pump();
    expect(forks, 1);
  });

  testWidgets('320 dp and 200% text do not overflow', (tester) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pumpSmall(
        tester,
        ShareChatSheet(data: _data(), onStopSharing: () {}),
        theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);

      await _pumpSmall(
        tester,
        ShareChatSheet(
          data: _data(active: false),
          onCreateLink: () {},
        ),
        theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Create link'), findsOneWidget);

      await _pumpSmall(
        tester,
        ShareChatSheet(
          data: _data(status: V2ShareStatus.error),
          onRetry: () {},
        ),
        theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Try again'), findsOneWidget);
    }
  });
}
