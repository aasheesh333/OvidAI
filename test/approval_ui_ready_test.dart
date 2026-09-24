import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/agent_service.dart';

/// Approval-UI readiness is a MOUNT COUNT, not a flag (2026-09-24).
///
/// `AgentService.approvalUiReady` used to be a single static bool set `true` in
/// `ChatScreen.initState` and `false` in `dispose`. During any navigation
/// overlap the outgoing screen's `dispose` runs AFTER the incoming one's
/// `initState`, clearing the flag while a fully visible approval UI was mounted.
/// `_askUser` then treated every pending approval as unanswerable and
/// **auto-denied it after 5 s instead of 120 s** — so the user watched a
/// permission card they could still tap get refused underneath them. It was also
/// process-global, so one hidden chat pane shortened the grace for every
/// session's run.
void main() {
  setUp(AgentService.resetApprovalUiCountForTest);
  tearDown(AgentService.resetApprovalUiCountForTest);

  group('readiness follows mounted UIs', () {
    test('starts false — nobody can answer', () {
      expect(AgentService.approvalUiCountForTest, 0);
      expect(AgentService.approvalUiReady, isFalse);
    });

    test('one mounted UI makes approvals answerable', () {
      AgentService.markApprovalUiMounted();
      expect(AgentService.approvalUiReady, isTrue);
      AgentService.markApprovalUiDisposed();
      expect(AgentService.approvalUiReady, isFalse);
    });

    test('a navigation overlap does NOT clear readiness', () {
      // The regression: outgoing.dispose() lands after incoming.initState().
      AgentService.markApprovalUiMounted(); // outgoing chat screen
      AgentService.markApprovalUiMounted(); // incoming chat screen
      AgentService.markApprovalUiDisposed(); // outgoing disposes last

      expect(
        AgentService.approvalUiReady,
        isTrue,
        reason: 'a visible approval UI is still mounted; approvals must get '
            'the full 120s grace, not the 5s fail-closed window',
      );
      expect(AgentService.approvalUiCountForTest, 1);

      AgentService.markApprovalUiDisposed();
      expect(AgentService.approvalUiReady, isFalse);
    });

    test('unbalanced disposes can never drive the count negative', () {
      AgentService.markApprovalUiDisposed();
      AgentService.markApprovalUiDisposed();
      expect(AgentService.approvalUiCountForTest, 0);
      expect(AgentService.approvalUiReady, isFalse);

      // A later real mount must still work.
      AgentService.markApprovalUiMounted();
      expect(AgentService.approvalUiReady, isTrue);
    });

    test('the legacy assignment form still works', () {
      // ignore: unnecessary_statements
      AgentService.approvalUiReady = true;
      expect(AgentService.approvalUiReady, isTrue);
      // ignore: unnecessary_statements
      AgentService.approvalUiReady = false;
      expect(AgentService.approvalUiReady, isFalse);
    });
  });

  group('the chat screen uses the counted API', () {
    test('initState mounts and dispose disposes', () {
      final src = File('lib/ui/chat_screen.dart').readAsStringSync();
      expect(src, contains('AgentService.markApprovalUiMounted();'));
      expect(src, contains('AgentService.markApprovalUiDisposed();'));
      // The bare-flag form is gone: it is what made the overlap unsafe.
      expect(src, isNot(contains('AgentService.approvalUiReady = true;')));
      expect(src, isNot(contains('AgentService.approvalUiReady = false;')));
    });
  });
}
