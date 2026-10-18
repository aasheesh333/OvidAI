import 'package:flutter/material.dart';

import '../core/cloud/agent_surface.dart';
import '../core/cloud/cloud_agent_facade.dart';
import '../core/diag.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'widgets/aether_confirm.dart';

/// P8 Task 19 — the cloud facade is the only agent implementation.
AgentSurface get _agent => CloudAgentFacade.I;

/// Session-level actions shared by the sidebar row menu and the chat
/// header's overflow menu, so both surfaces rename/delete identically.

/// Rename dialog; empty names are refused inline.
void showRenameSessionDialog(BuildContext context, ChatSession session) {
  showDialog<void>(
    context: context,
    builder: (_) => _RenameSessionDialog(session: session),
  );
}

/// Owns its controller so it is disposed with the dialog's element — after
/// the exit animation. Disposing on the dialog future (the old pattern) ran
/// while the closing route still rebuilt the field and threw "used after
/// being disposed".
class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({required this.session});
  final ChatSession session;

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.session.title,
  );
  String? _errorText;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _save(String value) {
    final title = value.trim();
    if (title.isEmpty) {
      setState(() => _errorText = context.l10n.sessionRenameEmpty);
      return;
    }
    AppState.I.renameSession(widget.session.id, title);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(
        l10n.sessionRenameTitle,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: TextField(
        controller: _c,
        autofocus: true,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(errorText: _errorText),
        // The IME action key used to be a dead end: it showed a return key
        // that did nothing, so the user had to reach for Save.
        textInputAction: TextInputAction.done,
        onSubmitted: _save,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: () => _save(_c.text),
          child: Text(l10n.actionSave, style: TextStyle(color: Aether.accent)),
        ),
      ],
    );
  }
}

/// Delete confirmation that spells out what goes with the chat (child
/// sessions, sandboxes, running work). Returns true when confirmed; the
/// caller performs the deletion (see [deleteSessionWithUndo]).
Future<bool> askDeleteSessionConfirmed(
  BuildContext context,
  ChatSession session,
) async {
  final l10n = context.l10n;
  final app = AppState.I;
  final descendants = app.descendantsOf(session.id);
  final doomed = [session, ...descendants];
  final runningDescendantCount = descendants
      .where((candidate) => _agent.busyFor(candidate.id))
      .length;
  final runningRoot = _agent.busyFor(session.id);
  final sandboxCount = doomed
      .map((candidate) => candidate.sandboxId ?? candidate.id)
      .toSet()
      .length;
  final details = <String>[
    if (descendants.isNotEmpty)
      l10n.sessionDeleteChildSessions(descendants.length),
    if (sandboxCount > 0) l10n.sessionDeleteSandboxes(sandboxCount),
    if (runningRoot) l10n.sessionDeleteStopsRunning,
    if (runningDescendantCount > 0)
      l10n.sessionDeleteStopsDescendants(runningDescendantCount),
  ];
  final impact = details.isEmpty
      ? l10n.sessionDeleteImpactUndo
      : l10n.sessionDeleteImpactDetails(details.join(', '));
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sessionDeleteTitle(session.title)),
      content: Text(impact),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            l10n.actionDelete,
            style: TextStyle(color: Aether.danger),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Optimistic delete: the chat disappears at once, a "Chat deleted · Undo"
/// snack bar runs for 5 s, and only then is the durable (possibly slow,
/// private-sync-backed) deletion awaited. A failure restores the chat and
/// says so instead of leaving an invisible-but-undeleted chat.
void deleteSessionWithUndo(BuildContext context, String sessionId) {
  final app = AppState.I;
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  app.hideSessionPending(sessionId);
  showUndoSnackBar(
    messenger,
    message: l10n.sessionDeleted,
    onUndo: () => app.unhideSession(sessionId),
    onCommit: () async {
      try {
        await app.commitPendingSessionDeletion(sessionId);
      } catch (e) {
        Diag.swallow('sidebar.deleteSession', e);
        if (messenger.mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.sessionDeleteFailed)),
          );
        }
      }
    },
  );
}

/// Confirm, then delete with undo.
Future<void> confirmAndDeleteSession(
  BuildContext context,
  ChatSession session,
) async {
  if (await askDeleteSessionConfirmed(context, session) && context.mounted) {
    deleteSessionWithUndo(context, session.id);
  }
}
