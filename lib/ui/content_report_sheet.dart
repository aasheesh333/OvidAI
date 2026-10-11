import 'package:flutter/material.dart';

import '../core/content_report_service.dart';
import '../core/state.dart';

/// Test seam: replaces the production report service.
ContentReportService? contentReportServiceOverrideForTest;

/// Assistant output a user can flag: final text, generated images and HTML
/// artifacts (not tool rows, reasoning or in-flight streams).
bool isReportableAiMessage(Message m) =>
    m.role != 'user' &&
    !m.thinking &&
    (m.kind == MsgKind.text ||
        m.kind == MsgKind.imageGen ||
        m.kind == MsgKind.htmlArtifact);

/// Reports one assistant message from the user's own chat.
Future<bool> reportAiMessage(BuildContext context, Message m, {String? model}) =>
    showContentReportSheet(
      context,
      kind: ContentReportKind.aiOutput,
      excerpt: m.content,
      model: model,
    );

/// In-app "Report" flow for AI output and user-generated content.
///
/// Play's AI-Generated Content policy requires users to be able to report or
/// flag offensive content "without needing to exit the app"; the UGC policy
/// requires in-app reporting of objectionable content and users. Returns true
/// when the report was accepted by the safety queue.
Future<bool> showContentReportSheet(
  BuildContext context, {
  required ContentReportKind kind,
  String excerpt = '',
  String? targetId,
  String? model,
}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ContentReportForm(
      kind: kind,
      excerpt: excerpt,
      targetId: targetId,
      model: model,
      service:
          contentReportServiceOverrideForTest ??
          ContentReportService.production(),
    ),
  );
  if (sent == true && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Thanks. Your report was sent to the Ovid safety team.'),
      ),
    );
  }
  return sent == true;
}

class ContentReportForm extends StatefulWidget {
  const ContentReportForm({
    super.key,
    required this.kind,
    required this.service,
    this.excerpt = '',
    this.targetId,
    this.model,
  });

  final ContentReportKind kind;
  final ContentReportService service;
  final String excerpt;
  final String? targetId;
  final String? model;

  @override
  State<ContentReportForm> createState() => _ContentReportFormState();
}

class _ContentReportFormState extends State<ContentReportForm> {
  ContentReportReason? _reason;
  final _details = TextEditingController();
  bool _sending = false;
  String? _error;
  // Kept across retries so a lost response cannot file the report twice.
  final _requestId = ContentReport.newRequestId();

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  String get _title => switch (widget.kind) {
    ContentReportKind.aiOutput => 'Report AI response',
    ContentReportKind.sharedConversation => 'Report shared conversation',
    ContentReportKind.collabMessage => 'Report message',
    ContentReportKind.collabParticipant => 'Report participant',
  };

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.service.submit(
        ContentReport(
          kind: widget.kind,
          reason: reason,
          details: _details.text,
          excerpt: widget.excerpt,
          targetId: widget.targetId,
          model: widget.model,
          requestId: _requestId,
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ContentReportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            key: const ValueKey('content-report-form'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                'Tell us what is wrong. The reported content (up to 4,000 '
                'characters) and your note are sent to the Ovid safety team '
                'for review.',
              ),
              const SizedBox(height: 8),
              RadioGroup<ContentReportReason>(
                groupValue: _reason,
                onChanged: (value) => setState(() => _reason = value),
                child: Column(
                  children: [
                    for (final reason in ContentReportReason.values)
                      RadioListTile<ContentReportReason>(
                        key: ValueKey('report-reason-${reason.wire}'),
                        value: reason,
                        contentPadding: EdgeInsets.zero,
                        title: Text(reason.label),
                      ),
                  ],
                ),
              ),
              TextField(
                key: const ValueKey('report-details'),
                controller: _details,
                maxLength: ContentReport.maxDetails,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Details (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('report-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('report-submit'),
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
