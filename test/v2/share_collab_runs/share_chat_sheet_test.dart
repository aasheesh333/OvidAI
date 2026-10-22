import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/share/share_chat_sheet.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

import '_harness.dart';

const List<V2SharedChatMessage> _sampleRows = <V2SharedChatMessage>[
  V2SharedChatMessage(
    id: 'u1',
    role: V2SharedChatRole.user,
    text: 'First question',
  ),
  V2SharedChatMessage(
    id: 't1',
    role: V2SharedChatRole.thinking,
    text: 'Thought about the data for a while',
  ),
  V2SharedChatMessage(
    id: 'tool1',
    role: V2SharedChatRole.tool,
    text: 'Searched the workspace',
  ),
  V2SharedChatMessage(
    id: 'a1',
    role: V2SharedChatRole.assistant,
    text: 'Second answer from the shared chat.',
  ),
];

const String _url = 'https://ovid.si/c/8f92a10c';

V2ShareChatSheetData _data({
  bool viewerCanFork = false,
  bool active = true,
  V2ShareStatus status = V2ShareStatus.ready,
  V2SharedChatAvailability availability = V2SharedChatAvailability.live,
  List<V2SharedChatMessage>? transcript,
  String errorMessage = 'We could not load the share link.',
  V2ShareMode mode = V2ShareMode.readOnly,
  bool revoked = false,
  bool collabAvailable = true,
  bool readOnlyAvailable = true,
  String? collabUnavailableReason,
  String? readOnlyUnavailableReason,
}) {
  return V2ShareChatSheetData(
    link: _url,
    shareId: '8f92a10c',
    creatorName: 'Meera Nair',
    viewerCanFork: viewerCanFork,
    active: active,
    mode: mode,
    status: status,
    availability: availability,
    revoked: revoked,
    collabAvailable: collabAvailable,
    readOnlyAvailable: readOnlyAvailable,
    collabUnavailableReason: collabUnavailableReason,
    readOnlyUnavailableReason: readOnlyUnavailableReason,
    transcript: transcript ?? (viewerCanFork ? _sampleRows : const []),
    errorMessage: errorMessage,
  );
}

List<V2SharedChatMessage> _longTranscript(int count) {
  return <V2SharedChatMessage>[
    for (var i = 0; i < count; i++)
      V2SharedChatMessage(
        id: 'm$i',
        role: i.isEven ? V2SharedChatRole.user : V2SharedChatRole.assistant,
        text: 'Message $i',
      ),
  ];
}

void main() {
  testWidgets('the creator still gets the minimal link sheet', (tester) async {
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(),
        onCopyLink: () {},
        onModeChanged: (_) {},
        onStopSharing: () {},
        onClose: () {},
      ),
    );

    expect(find.text('Share this chat'), findsOneWidget);
    expect(find.text(_url), findsOneWidget);
    expect(find.bySemanticsLabel('Copy link'), findsOneWidget);
    expect(find.text('Revoke link'), findsOneWidget);
    expect(find.text('Fork'), findsNothing);
    expect(find.textContaining('Forking makes a copy'), findsNothing);
  });

  testWidgets('an unavailable mode reaches the sheet with the real reason', (
    tester,
  ) async {
    V2ShareMode? picked;
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(
          active: false,
          collabAvailable: false,
          collabUnavailableReason: 'Not configured',
          readOnlyAvailable: false,
          readOnlyUnavailableReason: 'Not signed in',
        ),
        onModeChanged: (mode) => picked = mode,
        onCreateLinkForMode: (_) {},
      ),
    );

    expect(find.text('Not configured'), findsWidgets);
    expect(find.text('Not signed in'), findsWidgets);

    await tester.tap(find.text('Collab'), warnIfMissed: false);
    await tester.pump();
    expect(picked, isNull);
  });

  testWidgets('create forwards the selected mode to the host', (tester) async {
    var mode = V2ShareMode.readOnly;
    V2ShareMode? created;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ShareChatSheet(
          data: _data(active: false, mode: mode),
          onModeChanged: (next) => setState(() => mode = next),
          onCreateLinkForMode: (next) => created = next,
        ),
      ),
    );

    await tester.tap(find.text('Collab'));
    await tester.pump();
    expect(mode, V2ShareMode.collab);

    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, V2ShareMode.collab);
    expect(find.text('Creating link'), findsOneWidget);
  });

  testWidgets('an explicitly revoked link is the revoked state', (
    tester,
  ) async {
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(revoked: true),
        onCreateLink: () {},
        onClose: () {},
      ),
    );

    expect(find.text('Link revoked'), findsOneWidget);
    expect(find.text('No one can open it now.'), findsOneWidget);
    expect(find.text(_url), findsNothing);
  });

  testWidgets('switching modes is not mistaken for a revocation', (
    tester,
  ) async {
    var mode = V2ShareMode.collab;
    var active = true;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ShareChatSheet(
          data: _data(mode: mode, active: active),
          onModeChanged: (next) => setState(() {
            mode = next;
            active = false;
          }),
          onCreateLinkForMode: (_) {},
        ),
      ),
    );

    await tester.tap(find.text('Read only'));
    await tester.pump();

    expect(find.text('Link revoked'), findsNothing);
    expect(find.text('Not shared yet'), findsOneWidget);
  });

  testWidgets('a recipient gets read-only content and one Fork action', (
    tester,
  ) async {
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(viewerCanFork: true),
        onFork: (_) async => 'new-session',
      ),
    );

    expect(find.text('Shared chat'), findsOneWidget);
    expect(find.text('Shared by Meera Nair'), findsOneWidget);
    expect(find.bySemanticsLabel('Read only'), findsOneWidget);
    expect(find.text('Fork'), findsOneWidget);
    expect(find.text('First question'), findsOneWidget);
    expect(find.text('Second answer from the shared chat.'), findsOneWidget);

    // The recipient surface has no way to write or mutate the transcript.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
    expect(find.byIcon(Icons.send_rounded), findsNothing);
    expect(find.byIcon(Icons.edit_rounded), findsNothing);
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.text('Revoke link'), findsNothing);
  });

  testWidgets('fork is in flight, then reports the new session id', (
    tester,
  ) async {
    final pending = Completer<String>();
    String? receivedShareId;
    String? forkedSessionId;
    final handle = tester.ensureSemantics();

    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(viewerCanFork: true),
        onFork: (shareId) {
          receivedShareId = shareId;
          return pending.future;
        },
        onForked: (sessionId) => forkedSessionId = sessionId,
      ),
    );

    final fork = tester.getSemantics(find.bySemanticsLabel('Fork'));
    expect(
      fork.getSemanticsData().flagsCollection.isEnabled,
      ui.Tristate.isTrue,
    );

    await tester.tap(find.text('Fork'));
    await tester.pump();

    expect(receivedShareId, '8f92a10c');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Fork'))
          .getSemanticsData()
          .flagsCollection
          .isEnabled,
      ui.Tristate.isFalse,
    );
    expect(forkedSessionId, isNull);

    pending.complete('session-42');
    await tester.pump();
    await tester.pump();

    expect(forkedSessionId, 'session-42');
    expect(find.text('Forked'), findsOneWidget);
    expect(find.text('Fork'), findsNothing);
    handle.dispose();
  });

  testWidgets('fork failure shows the reason and retries the same id', (
    tester,
  ) async {
    var attempts = 0;
    String? forked;
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(viewerCanFork: true),
        onFork: (shareId) async {
          attempts++;
          if (attempts == 1) {
            throw Exception('Sign in again to fork.');
          }
          expect(shareId, '8f92a10c');
          return 'session-7';
        },
        onForked: (sessionId) => forked = sessionId,
      ),
    );

    await tester.tap(find.text('Fork'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Sign in again to fork.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Fork'), findsNothing);
    expect(forked, isNull);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(attempts, 2);
    expect(forked, 'session-7');
    expect(find.text('Forked'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('expired and revoked links are one honest line, never a chat', (
    tester,
  ) async {
    for (final state in const <V2SharedChatAvailability>[
      V2SharedChatAvailability.expired,
      V2SharedChatAvailability.revoked,
    ]) {
      await pumpAt(
        tester,
        ShareChatSheet(
          data: _data(
            viewerCanFork: true,
            availability: state,
            transcript: _sampleRows,
          ),
          onFork: (_) async => 'new-session',
        ),
      );

      final label = state == V2SharedChatAvailability.expired
          ? 'Link expired'
          : 'Link revoked';
      expect(find.text(label), findsOneWidget);
      expect(find.text('First question'), findsNothing);
      expect(find.text('Fork'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    }
  });

  testWidgets('loading and load errors stay inside the shared chat', (
    tester,
  ) async {
    await pumpAt(tester, ShareChatSheet(data: _data(viewerCanFork: true)));
    // The default ready viewer already has its transcript; loading replaces it.
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(viewerCanFork: true, status: V2ShareStatus.loading),
        onFork: (_) async => 'new-session',
      ),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Fork'), findsNothing);
    expect(find.text('First question'), findsNothing);

    var retries = 0;
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(
          viewerCanFork: true,
          status: V2ShareStatus.error,
          errorMessage: 'This link could not load.',
        ),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('This link could not load.'), findsOneWidget);
    expect(find.text('Fork'), findsNothing);
    expect(find.text('First question'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('a 5,000-message share builds only the visible rows', (
    tester,
  ) async {
    final rows = _longTranscript(5000);
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(viewerCanFork: true, transcript: rows),
        onFork: (_) async => 'new-session',
      ),
    );

    expect(find.text('Message 0'), findsOneWidget);
    expect(find.text('Message 4999'), findsNothing);
    final builtRows = find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('shared-row-'),
        )
        .evaluate()
        .length;
    expect(builtRows, greaterThan(0));
    expect(builtRows, lessThan(30), reason: 'lazy list, not 5,000 rows');

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    for (var i = 0; i < 20; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      if (find.text('Message 4999').evaluate().isNotEmpty) break;
    }
    expect(find.text('Message 4999'), findsOneWidget);
  });

  testWidgets('tool and thinking rows are exactly one line', (tester) async {
    await pumpNarrow(
      tester,
      ShareChatSheet(
        data: _data(viewerCanFork: true),
        onFork: (_) async => 'new-session',
      ),
      dark: true,
    );

    final thinking = tester.widget<Text>(
      find.text('Thought about the data for a while'),
    );
    expect(thinking.maxLines, 1);
    expect(thinking.overflow, TextOverflow.ellipsis);
    final tool = tester.widget<Text>(find.text('Searched the workspace'));
    expect(tool.maxLines, 1);
    expect(tool.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('banner is announced and rows read in transcript order', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(viewerCanFork: true),
        onFork: (_) async => 'new-session',
      ),
    );

    final banner = tester.getSemantics(find.bySemanticsLabel('Read only'));
    expect(
      banner.getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
      reason: 'the read-only banner must be announced',
    );

    final labels = _labelsInReadingOrder(tester);
    final user = labels.indexWhere((label) => label.startsWith('You. First'));
    final thinking = labels.indexWhere(
      (label) => label.startsWith('Thinking.'),
    );
    final tool = labels.indexWhere((label) => label.startsWith('Tool.'));
    final assistant = labels.indexWhere((label) => label == 'Assistant');
    expect(user, isNot(-1), reason: 'labels: $labels');
    expect(thinking, isNot(-1), reason: 'labels: $labels');
    expect(tool, isNot(-1), reason: 'labels: $labels');
    expect(assistant, isNot(-1), reason: 'labels: $labels');
    expect(user, lessThan(thinking));
    expect(thinking, lessThan(tool));
    expect(tool, lessThan(assistant));
    handle.dispose();
  });

  testWidgets('read-only layout survives 320 → 1280 at 100 and 200 percent', (
    tester,
  ) async {
    for (final width in const <double>[320, 360, 412, 600, 800, 1024, 1280]) {
      for (final scale in const <double>[1, 2]) {
        for (final dark in const <bool>[false, true]) {
          await pumpAt(
            tester,
            ShareChatSheet(
              data: _data(viewerCanFork: true),
              onFork: (_) async => 'new-session',
            ),
            size: Size(width, 900),
            textScale: scale,
            dark: dark,
          );
          expect(
            tester.takeException(),
            isNull,
            reason:
                '${width.toInt()} dp / ${scale}x / '
                '${dark ? 'dark' : 'light'}',
          );
          expect(find.text('Fork'), findsOneWidget);
          final transcript = tester.getSize(
            find.byKey(const ValueKey<String>('shared-chat-transcript')),
          );
          expect(
            transcript.width,
            lessThanOrEqualTo(width > 720 ? 720 : width),
            reason: 'the transcript keeps a 720 dp reading column',
          );
          expect(
            transcript.width,
            lessThanOrEqualTo(720),
            reason: 'the transcript never grows past 720 dp',
          );
        }
      }
    }
  });

  testWidgets('opening the sheet returns the forked session id', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    String? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showShareChatSheet(
                  context,
                  data: _data(viewerCanFork: true),
                  onFork: (_) async => 'session-42',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Shared chat'), findsOneWidget);

    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(result, 'session-42');
    expect(find.text('Shared chat'), findsNothing);
  });
}

/// Flattens the semantics tree in platform order, honouring the transcript's
/// [OrdinalSortKey]s the same way TalkBack does.
List<String> _labelsInReadingOrder(WidgetTester tester) {
  final root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  final labels = <String>[];
  if (root == null) return labels;

  void visit(SemanticsNode node) {
    final label = node.getSemanticsData().label.trim();
    if (label.isNotEmpty) labels.add(label);
    final children = <SemanticsNode>[];
    node.visitChildren((child) {
      children.add(child);
      return true;
    });
    if (children.length > 1) {
      final keys = children.map((child) => child.sortKey).toList();
      final first = keys.first;
      if (first is OrdinalSortKey &&
          keys.every(
            (key) => key is OrdinalSortKey && key.name == first.name,
          )) {
        children.sort(
          (a, b) => (a.sortKey! as OrdinalSortKey).order.compareTo(
            (b.sortKey! as OrdinalSortKey).order,
          ),
        );
      }
    }
    for (final child in children) {
      visit(child);
    }
  }

  visit(root);
  return labels;
}
