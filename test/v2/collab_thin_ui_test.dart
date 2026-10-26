import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';
import 'package:ovid_ai/ui/collab_report_sheet.dart';
import 'package:ovid_ai/ui/collab_session_screen.dart';
import 'package:ovid_ai/ui/v2/app/v2_collab_routes.dart';
import 'package:ovid_ai/ui/v2/collab/collab_live_page.dart';

import 'share_collab_runs/_harness.dart';

// UNEXECUTED: authored while HEAVY-COMMANDS-PAUSED.md forbids Flutter tests.

CollaborationEvent _event(
  int sequence,
  String kind,
  Map<String, Object?> payload,
) =>
    CollaborationEvent.fromWire({
      'schemaVersion': 1,
      'eventId': sequence == 1 ? 'message:message-1' : 'mirror:$sequence-0',
      'sessionId': 'session-1',
      'eventSequence': sequence,
      'senderParticipantId': 'p-owner',
      'kind': kind,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'payload': payload,
    });

void main() {
  test('replay text, tool, and artifact rows stay ordered with real object IDs', () {
    var state = CollaborationState.bootstrap(
      session: const CollaborationSession(
        sessionId: 'session-1',
        ownerParticipantId: 'p-owner',
        lifecycle: SessionLifecycle.active,
      ),
      members: const [
        Member(participantId: 'p-owner', role: MemberRole.owner, status: MemberStatus.active),
      ],
      localParticipantId: 'p-owner',
      lastSequence: 0,
    );
    state = const CollaborationReducer().applyPage(state, [
      _event(1, 'message', {'text': 'Question', 'role': 'user'}),
      _event(2, 'tool_started', {
        'runId': 'run-1',
        'callId': 'call-1',
        'name': 'safe_tool',
        'status': 'running',
      }),
      _event(3, 'artifact_created', {
        'runId': 'run-1',
        'artifactId': 'artifact-1',
        'name': 'result.txt',
        'sizeBytes': 3,
        'contentType': 'text/plain',
      }),
    ]);

    final data = V2CollabRoutes.liveDataFor(state);
    expect(data.messages.map((message) => message.id), [
      'message:message-1',
      'mirror:2-0',
      'mirror:3-0',
    ]);
    expect(data.messages[1].toolName, 'safe_tool');
    expect(data.messages[2].artifactName, 'result.txt');
    expect(data.messages[2].artifactId, 'artifact-1');
    expect(collaborationCanonicalMessageId(data.messages.first.id), 'message-1');
  });

  testWidgets('artifact, report, and remove callbacks carry the real target', (tester) async {
    const message = V2CollabMessage(
      id: 'message:message-1',
      authorId: 'p-other',
      speakerName: 'Other',
      timeLabel: '',
      text: 'Answer',
      kind: V2CollabMessageKind.agent,
      artifactName: 'result.txt',
      artifactId: 'artifact-1',
      canReport: true,
      canRemove: true,
    );
    String? opened;
    final reports = <V2CollabMessage>[];
    final removals = <V2CollabMessage>[];
    await pumpAt(
      tester,
      CollabLivePage(
        data: const V2CollabLivePageData(
          totalMembers: 2,
          creatorPaysStorage: true,
          turnHolderName: '',
          turnTimeLeftLabel: '',
          messages: [message],
          isMyTurn: true,
        ),
        onOpenArtifact: (id) => opened = id,
        onReportMessage: reports.add,
        onRemoveMessage: removals.add,
      ),
    );

    // The artifact row merges into the message bubble's semantics node, so
    // assert the open label is attached to the row text rather than assuming a
    // standalone node.
    expect(
      tester.getSemantics(find.text('result.txt')).label,
      contains('Open result.txt'),
    );
    await tester.tap(find.text('result.txt'));
    await tester.tap(find.bySemanticsLabel('Report message'));
    await tester.tap(find.bySemanticsLabel('Remove message'));
    expect(opened, 'artifact-1');
    expect(reports.single.id, 'message:message-1');
    expect(removals.single.id, 'message:message-1');
  });

  testWidgets('artifact with no ID stays readable but has no open action', (tester) async {
    var opened = 0;
    await pumpAt(
      tester,
      CollabLivePage(
        data: const V2CollabLivePageData(
          totalMembers: 2,
          creatorPaysStorage: true,
          turnHolderName: '',
          turnTimeLeftLabel: '',
          messages: [
            V2CollabMessage(
              id: 'mirror:artifact-without-id',
              speakerName: 'Ovid',
              timeLabel: '',
              text: 'result.txt',
              kind: V2CollabMessageKind.agent,
              artifactName: 'result.txt',
            ),
          ],
        ),
        onOpenArtifact: (_) => opened++,
      ),
    );

    expect(find.text('result.txt'), findsWidgets);
    expect(find.bySemanticsLabel('Open result.txt'), findsNothing);
    expect(opened, 0);
  });

  testWidgets('legacy report and remove controls require canonical message sources', (tester) async {
    var canonicalReports = 0;
    var canonicalRemovals = 0;
    var mirrorReports = 0;
    var mirrorRemovals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CollabMessageBubble(
                message: const CollaborationMessage(
                  sequence: 1,
                  clientEventId: 'message:message-1',
                  author: 'p-other',
                  createdAt: '2026-01-01T00:00:00.000Z',
                  text: 'Canonical',
                  role: MessageRole.user,
                ),
                authorName: 'Other',
                mine: false,
                onReport: () => canonicalReports++,
                onRemove: () => canonicalRemovals++,
              ),
              CollabMessageBubble(
                message: const CollaborationMessage(
                  sequence: 2,
                  clientEventId: 'mirror:not-a-message',
                  author: 'p-other',
                  createdAt: '2026-01-01T00:00:00.000Z',
                  text: 'Mirror',
                  role: MessageRole.user,
                ),
                authorName: 'Other',
                mine: false,
                // Deliberately supply callbacks: the row itself must not offer
                // an action for an arbitrary mirror/event identifier.
                onReport: () => mirrorReports++,
                onRemove: () => mirrorRemovals++,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byTooltip('Report message'), findsOneWidget);
    expect(find.byTooltip('Remove message'), findsOneWidget);
    await tester.tap(find.byTooltip('Report message'));
    await tester.tap(find.byTooltip('Remove message'));
    expect(canonicalReports, 1);
    expect(canonicalRemovals, 1);
    expect(mirrorReports, 0);
    expect(mirrorRemovals, 0);
    expect(
      () => collaborationCanonicalMessageId('mirror:not-a-message'),
      throwsArgumentError,
    );
  });

  testWidgets('attachment chips invoke real attach/remove handlers', (tester) async {
    var attaches = 0;
    final removed = <int>[];
    await pumpAt(
      tester,
      CollabLivePage(
        data: const V2CollabLivePageData(
          totalMembers: 1,
          creatorPaysStorage: true,
          turnHolderName: '',
          turnTimeLeftLabel: '',
          isMyTurn: true,
          pendingAttachmentNames: ['notes.txt'],
        ),
        onSend: (_) {},
        onAttach: () => attaches++,
        onRemoveAttachment: removed.add,
      ),
    );

    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Attach files'));
    // Material 3 chips use Icons.clear for the delete affordance.
    await tester.tap(find.byIcon(Icons.clear));
    expect(attaches, 1);
    expect(removed, [0]);
  });

  test('Collab UI does not use local provider keys or the legacy report service', () {
    for (final path in [
      'lib/ui/collab_session_screen.dart',
      'lib/ui/v2/app/v2_collab_routes.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('hasKey')));
      expect(source, isNot(contains('requiresApiKey')));
      expect(source, isNot(contains('ContentReportService')));
      expect(source, isNot(contains('showContentReportSheet')));
    }
  });
}
