import 'package:flutter/material.dart';

import '../core/collaboration/production.dart';
import '../core/content_report_service.dart';

/// Canonical `/chat/:token/reports` flow. The server derives the excerpt and
/// target authority; the client supplies only kind, target ID, reason/details.
Future<bool> showCollaborationReportSheet(
  BuildContext context,
  CollaborationProduction controller, {
  required String kind,
  required String targetId,
}) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CollaborationReportForm(
      controller: controller,
      kind: kind,
      targetId: targetId,
    ),
  );
  if (accepted == true && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Thanks. Your report was sent.')),
    );
  }
  return accepted == true;
}

class _CollaborationReportForm extends StatefulWidget {
  const _CollaborationReportForm({
    required this.controller,
    required this.kind,
    required this.targetId,
  });

  final CollaborationProduction controller;
  final String kind;
  final String targetId;

  @override
  State<_CollaborationReportForm> createState() =>
      _CollaborationReportFormState();
}

class _CollaborationReportFormState extends State<_CollaborationReportForm> {
  ContentReportReason? _reason;
  final _details = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.controller.report(
        kind: widget.kind,
        targetId: widget.targetId,
        reason: reason.wire,
        details: _details.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _error = collaborationErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            key: const ValueKey('collab-report-form'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.kind == 'collab_message'
                    ? 'Report message'
                    : 'Report participant',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose a reason. The server attaches the authorized content; no excerpt is uploaded from this device.',
              ),
              RadioGroup<ContentReportReason>(
                groupValue: _reason,
                onChanged: (value) => setState(() => _reason = value),
                child: Column(
                  children: [
                    for (final reason in ContentReportReason.values)
                      RadioListTile<ContentReportReason>(
                        key: ValueKey('collab-report-reason-${reason.wire}'),
                        value: reason,
                        contentPadding: EdgeInsets.zero,
                        title: Text(reason.label),
                      ),
                  ],
                ),
              ),
              TextField(
                key: const ValueKey('collab-report-details'),
                controller: _details,
                maxLength: 1000,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Details (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('collab-report-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              FilledButton(
                key: const ValueKey('collab-report-submit'),
                onPressed: _reason == null || _sending ? null : _submit,
                child: Text(_sending ? 'Sending…' : 'Send report'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool collaborationIsCanonicalMessageSource(String eventId) =>
    eventId.startsWith('message:') && eventId.length > 'message:'.length;

String collaborationCanonicalMessageId(String eventId) {
  if (!collaborationIsCanonicalMessageSource(eventId)) {
    throw ArgumentError('Not a canonical collaboration message source');
  }
  return eventId.substring('message:'.length);
}
