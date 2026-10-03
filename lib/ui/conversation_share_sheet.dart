import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/conversation_share_service.dart';
import '../core/state.dart';

Future<void> showConversationShareSheet(
  BuildContext context,
  ChatSession session,
) {
  final service = ConversationShareService.production();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: .88,
      child: ConversationShareSheet(session: session, service: service),
    ),
  );
}

class ConversationShareSheet extends StatefulWidget {
  const ConversationShareSheet({
    super.key,
    required this.session,
    required this.service,
  });
  final ChatSession session;
  final ConversationShareService service;

  @override
  State<ConversationShareSheet> createState() => _ConversationShareSheetState();
}

class _ConversationShareSheetState extends State<ConversationShareSheet> {
  // The identity binding and frozen preview share the same lifetime.
  late final _service = widget.service;
  late final _snapshot = ConversationSnapshot.fromSession(widget.session);
  String _requestId = ConversationShareService.newRequestId();
  List<ConversationShare> _shares = [];
  bool _busy = false;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Freeze the exact preview before any asynchronous server work.
    _snapshot;
    if (_service.available) _refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is ConversationShareException
              ? error.message
              : 'Could not complete sharing. Please retry.';
          if (!_service.ownerIsCurrent) _shares = [];
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run(() async {
    final shares = await _service.list(_snapshot.sessionId);
    if (mounted) {
      setState(() {
        _shares = shares;
        // A matching owner-only receipt conclusively resolves a lost response.
        if (shares.any((share) => share.requestId == _requestId)) {
          _requestId = ConversationShareService.newRequestId();
        }
        _loaded = true;
      });
    }
  });

  Future<void> _create() => _run(() async {
    final share = await _service.create(_snapshot, requestId: _requestId);
    if (mounted) {
      setState(() {
        _shares = [share, ..._shares.where((s) => s.id != share.id)];
        // Only advance the request ID after confirmed success.
        _requestId = ConversationShareService.newRequestId();
      });
    }
  });

  Future<void> _revoke(ConversationShare share) => _run(() async {
    await _service.revoke(share.id);
    if (mounted) setState(() => _shares.removeWhere((s) => s.id == share.id));
  });

  Future<void> _copy(ConversationShare share) => _run(() async {
    // Revalidate ownership and revocation before copying a displayed receipt.
    final current = await _service.list(_snapshot.sessionId);
    if (!mounted) return;
    setState(() => _shares = current);
    if (!current.any((s) => s.id == share.id)) {
      throw const ConversationShareException(
        'This link is no longer available.',
      );
    }
    await Clipboard.setData(ClipboardData(text: share.url.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Link copied')));
    }
  });

  @override
  Widget build(BuildContext context) {
    final available = _service.available;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Share conversation',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                children: [
                  const Text(
                    'Anyone with the link can read this frozen text snapshot. Later chat edits are not included.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Only the messages below are shared. Thinking, tools, internal context, detected credentials, attachments and session metadata are excluded. Review the text for personal information.',
                  ),
                  if (!available) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Sharing is unavailable: deployment is not configured.',
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Preview · ${_snapshot.messages.length} messages',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  for (final message in _snapshot.messages)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.role == 'user' ? 'You' : 'Assistant',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(message.content),
                        ],
                      ),
                    ),
                  if (!_snapshot.withinLimits)
                    const Text(
                      'No shareable text, or snapshot exceeds the 500-message / 200 KB / 20,000-character-per-message limit.',
                    ),
                  const Divider(),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Existing links',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton(
                        onPressed: available && !_busy ? _refresh : null,
                        child: const Text('Refresh'),
                      ),
                    ],
                  ),
                  if (_loaded && _shares.isEmpty)
                    const Text('No active links for this session.'),
                  for (final share in _shares)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            share.url.toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Expires ${share.expiresAt.toLocal().toString().split('.').first}',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: _busy ? null : () => _copy(share),
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('Copy link'),
                              ),
                              TextButton(
                                onPressed: _busy ? null : () => _revoke(share),
                                child: const Text('Revoke'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed:
                  available &&
                      _loaded &&
                      !_busy &&
                      _snapshot.withinLimits &&
                      _shares.isEmpty
                  ? _create
                  : null,
              icon: const Icon(Icons.link),
              label: const Text('Create link'),
            ),
          ],
        ),
      ),
    );
  }
}
