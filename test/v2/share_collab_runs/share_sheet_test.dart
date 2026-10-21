import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

V2ShareSheetData _data({
  bool active = true,
  bool copied = false,
  V2ShareStatus status = V2ShareStatus.ready,
}) {
  return V2ShareSheetData(
    link: 'ovidsi.com/c/79f9b4c0e',
    creatorName: 'Aarav Sharma',
    active: active,
    copied: copied,
    status: status,
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
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps at 320 dp wide with 200 % text, the tightest supported layout.
Future<void> _pumpNarrow(
  WidgetTester tester,
  Widget child,
  ThemeData theme,
) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, appChild) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: appChild!,
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'renders the link, permissions and privacy note in light and dark',
    (tester) async {
      for (final theme in [OTheme.light(), OTheme.dark()]) {
        await _pump(tester, ShareSheet(data: _data()), theme);

        expect(find.text('Share this chat'), findsOneWidget);
        expect(find.text('ovidsi.com/c/79f9b4c0e'), findsOneWidget);
        expect(find.text('Copy link'), findsOneWidget);
        expect(find.text('Anyone with the link can view'), findsOneWidget);
        expect(find.text('Show my name'), findsOneWidget);
        expect(find.text('Displays Aarav Sharma as creator'), findsOneWidget);
        expect(find.text('WhatsApp'), findsOneWidget);
        expect(find.text('Gmail'), findsOneWidget);
        expect(find.text('Slack'), findsOneWidget);
        expect(find.text('More'), findsOneWidget);
        expect(find.text('Stop sharing'), findsOneWidget);
        expect(
          find.text('Shared chats never include your files or connectors.'),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets('empty state creates a link', (tester) async {
    var created = 0;
    await _pump(
      tester,
      ShareSheet(data: _data(active: false), onCreateLink: () => created++),
      OTheme.light(),
    );

    expect(find.text('This chat is not shared yet'), findsOneWidget);
    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, 1);
  });

  testWidgets('copy link and stop sharing callbacks fire', (tester) async {
    var copies = 0;
    var stops = 0;
    await _pump(
      tester,
      ShareSheet(
        data: _data(),
        onCopyLink: () => copies++,
        onStopSharing: () => stops++,
      ),
      OTheme.light(),
    );

    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 1);

    await tester.tap(find.text('Stop sharing'));
    await tester.pump();
    expect(stops, 1);
  });

  testWidgets('toggles and a share target update the injected state', (
    tester,
  ) async {
    bool? anyone;
    bool? showName;
    V2ShareTarget? target;
    await _pump(
      tester,
      ShareSheet(
        data: _data(),
        onToggleAnyoneCanView: (value) => anyone = value,
        onToggleShowName: (value) => showName = value,
        onShareTarget: (value) => target = value,
      ),
      OTheme.light(),
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(anyone, isFalse);

    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    expect(showName, isFalse);

    await tester.tap(find.text('Slack'));
    await tester.pump();
    expect(target, V2ShareTarget.slack);
  });

  testWidgets('loading state shows skeletons and error state retries', (
    tester,
  ) async {
    await _pump(
      tester,
      ShareSheet(data: _data(status: V2ShareStatus.loading)),
      OTheme.light(),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Copy link'), findsNothing);

    var retries = 0;
    await _pump(
      tester,
      ShareSheet(
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

  testWidgets('copied state and the close button are wired', (tester) async {
    var closes = 0;
    await _pump(
      tester,
      ShareSheet(data: _data(copied: true), onClose: () => closes++),
      OTheme.light(),
    );

    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Copy link'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Close share sheet'));
    await tester.pump();
    expect(closes, 1);
  });

  testWidgets('share targets are announced, disabled when unwired', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pump(tester, ShareSheet(data: _data()), OTheme.light());
    expect(
      tester.getSemantics(find.bySemanticsLabel('Share on Slack')),
      isSemantics(
        label: 'Share on Slack',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    await _pump(
      tester,
      ShareSheet(data: _data(), onShareTarget: (_) {}),
      OTheme.light(),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Share on Slack')),
      isSemantics(label: 'Share on Slack', isButton: true, isEnabled: true),
    );

    handle.dispose();
  });

  testWidgets('fits 320 dp at 200% text without overflow', (tester) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pumpNarrow(
        tester,
        ShareSheet(
          data: _data(),
          forkNote:
              'Forking makes a copy in their own account. Your original stays '
              'private.',
          onCopyLink: () {},
          onToggleAnyoneCanView: (_) {},
          onToggleShowName: (_) {},
          onShareTarget: (_) {},
          onStopSharing: () {},
          onClose: () {},
        ),
        theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Stop sharing'), findsOneWidget);
      expect(find.text('ovidsi.com/c/79f9b4c0e'), findsOneWidget);
    }

    await _pumpNarrow(
      tester,
      ShareSheet(data: _data(active: false), onCreateLink: () {}),
      OTheme.light(),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Create link'), findsOneWidget);

    await _pumpNarrow(
      tester,
      ShareSheet(data: _data(status: V2ShareStatus.error), onRetry: () {}),
      OTheme.light(),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Try again'), findsOneWidget);
  });
}
