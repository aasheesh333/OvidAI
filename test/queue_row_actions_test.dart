import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

/// Regression: the queued-message row used to show five icon buttons
/// (bolt quick-send, fast-forward send-next, inline pencil edit, edit in
/// composer, delete). The row now exposes exactly three actions, and the
/// build reads its icons/tooltips from the same [queueRowActions] spec this
/// test asserts — so the UI cannot drift from the spec.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('queue row actions', () {
    test('exactly three actions, in order: quickSend, editInComposer, delete',
        () {
      expect(queueRowActions, hasLength(3));
      expect(
        queueRowActions.map((a) => a.action).toList(),
        ['quickSend', 'editInComposer', 'delete'],
      );
    });

    test('icons are fast-forward, edit, delete', () {
      expect(
        queueRowActions.map((a) => a.icon).toList(),
        [
          Icons.fast_forward_outlined,
          Icons.edit_outlined,
          Icons.delete_outline,
        ],
      );
    });

    test('tooltips are the quick-send and composer-edit copy', () {
      expect(
        queueRowActions[0].tooltip,
        'Quick send: stop current run and send this now',
      );
      expect(queueRowActions[1].tooltip, 'Edit in composer');
      expect(queueRowActions[2].tooltip, 'Delete');
    });
  });
}
