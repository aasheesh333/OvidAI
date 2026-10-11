import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'aether_primitives.dart';

/// Shared confirmation dialog for destructive or wide-scope actions.
///
/// Every destructive action in the app confirms through this dialog (or
/// offers Undo through [showUndoSnackBar]) so the consequence is always
/// stated in plain words before anything is lost. When [typeToConfirm] is
/// set the confirm button stays disabled until the user types that word.
class AetherConfirmDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final String? typeToConfirm;

  /// Extra content (an export reminder, a list of what is lost, ...).
  final Widget? extra;

  const AetherConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.destructive = true,
    this.typeToConfirm,
    this.extra,
  });

  @override
  State<AetherConfirmDialog> createState() => _AetherConfirmDialogState();
}

class _AetherConfirmDialogState extends State<AetherConfirmDialog> {
  final _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  bool get _armed {
    final word = widget.typeToConfirm;
    return word == null || _typed.text.trim() == word;
  }

  @override
  Widget build(BuildContext context) {
    final word = widget.typeToConfirm;
    final onConfirm = _armed ? () => Navigator.pop(context, true) : null;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            if (widget.extra != null) ...[
              const SizedBox(height: 12),
              widget.extra!,
            ],
            if (word != null) ...[
              const SizedBox(height: 16),
              Text('Type $word to confirm.', style: AetherType.caption),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('aether-confirm-type'),
                controller: _typed,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(hintText: word),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(widget.cancelLabel),
        ),
        if (widget.destructive)
          AetherDangerButton(label: widget.confirmLabel, onPressed: onConfirm)
        else
          FilledButton(onPressed: onConfirm, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// Shows an [AetherConfirmDialog]; resolves true only on explicit confirm.
Future<bool> showAetherConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = true,
  String? typeToConfirm,
  Widget? extra,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AetherConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
      typeToConfirm: typeToConfirm,
      extra: extra,
    ),
  );
  return result == true;
}

/// Shows "[message] · Undo" for [duration].
///
/// Exactly one of [onUndo] / [onCommit] runs: [onUndo] when the user taps
/// Undo, otherwise [onCommit] once the snack bar is gone (timeout, swipe,
/// replaced, or the messenger disposed). Callers that soft-delete do the
/// durable work in [onCommit]. A fallback timer guarantees the commit even
/// when the messenger is torn down before the snack bar closes.
void showUndoSnackBar(
  ScaffoldMessengerState messenger, {
  required String message,
  required VoidCallback onUndo,
  FutureOr<void> Function()? onCommit,
  Duration duration = const Duration(seconds: 5),
}) {
  var settled = false;
  Timer? fallback;
  void undo() {
    if (settled) return;
    settled = true;
    fallback?.cancel();
    onUndo();
  }

  void commit() {
    if (settled) return;
    settled = true;
    fallback?.cancel();
    if (onCommit != null) unawaited(Future.sync(onCommit));
  }

  // Settle anything already showing or queued first so this bar is visible
  // immediately and its Undo window is not spent waiting in the queue.
  messenger.clearSnackBars();
  final controller = messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      // A SnackBar with an action persists by default; Undo must expire.
      persist: false,
      action: SnackBarAction(
        label: 'Undo',
        textColor: Aether.accent,
        onPressed: undo,
      ),
    ),
  );
  fallback = Timer(duration + const Duration(seconds: 2), () {
    commit();
    try {
      controller.close();
    } catch (_) {
      // The messenger is already gone; nothing left to hide.
    }
  });
  controller.closed.then((reason) {
    if (reason == SnackBarClosedReason.action) {
      undo();
    } else {
      commit();
    }
  });
}
