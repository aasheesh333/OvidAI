import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart' as qr;

import '../core/conversation_share_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

Future<void> showConversationShareSheet(
  BuildContext context,
  ChatSession session,
) {
  final service = ConversationShareService.production();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => FractionallySizedBox(
      heightFactor: .92,
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
    final activeShare = _shares.isEmpty ? null : _shares.first;

    return AetherSheet(
      title: 'Share conversation',
      actions: [
        AetherGhostButton(
          label: 'Close',
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (activeShare != null)
                  _ActiveShareCard(
                    share: activeShare,
                    busy: _busy,
                    onCopy: () => _copy(activeShare),
                    onRevoke: () => _revoke(activeShare),
                  )
                else
                  AetherCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Create a read-only link',
                          style: AetherType.title,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Anyone with the link can read this frozen text snapshot. Later chat edits are not included.',
                          style: AetherType.bodyMuted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Only the messages below are shared. Thinking, tools, internal context, detected credentials, attachments and session metadata are excluded. Review the text for personal information.',
                          style: AetherType.caption.copyWith(height: 1.5),
                        ),
                        if (!available) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Sharing is unavailable: deployment is not configured.',
                            style: AetherType.body.copyWith(
                              color: Aether.warnLight,
                            ),
                          ),
                        ],
                        if (_loaded && _shares.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'No active links for this session.',
                              style: AetherType.bodyMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  AetherCard(
                    color: Aether.danger.withValues(alpha: 0.06),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 16,
                              color: Aether.dangerC,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _error!,
                                style: AetherType.body.copyWith(
                                  color: Aether.dangerC,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (!_loaded)
                          AetherGhostButton(
                            label: 'Retry',
                            icon: Icons.refresh,
                            onPressed: available && !_busy ? _refresh : null,
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                AetherCard(
                  title: Text(
                    'Preview · ${_snapshot.messages.length} messages',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final message in _snapshot.messages)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message.role == 'user' ? 'You' : 'Assistant',
                                style: AetherType.label,
                              ),
                              const SizedBox(height: 4),
                              Text(message.content, style: AetherType.body),
                            ],
                          ),
                        ),
                      if (!_snapshot.withinLimits)
                        Text(
                          'No shareable text, or snapshot exceeds the 500-message / 200 KB / 20,000-character-per-message limit.',
                          style: AetherType.caption.copyWith(
                            color: Aether.warnLight,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Existing links', style: AetherType.label),
                    AetherGhostButton(
                      label: 'Refresh',
                      icon: Icons.refresh,
                      onPressed: available && !_busy ? _refresh : null,
                    ),
                  ],
                ),
                if (_loaded && _shares.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No active links for this session.',
                      style: AetherType.bodyMuted,
                    ),
                  ),
                for (final share in _shares.skip(activeShare == null ? 0 : 1))
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _ShareLinkRow(
                      share: share,
                      busy: _busy,
                      onCopy: () => _copy(share),
                      onRevoke: () => _revoke(share),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AetherPrimaryButton(
            label: 'Create link',
            icon: Icons.link,
            onPressed:
                available &&
                    _loaded &&
                    !_busy &&
                    _snapshot.withinLimits &&
                    _shares.isEmpty
                ? _create
                : null,
          ),
        ],
      ),
    );
  }
}

class _ActiveShareCard extends StatelessWidget {
  const _ActiveShareCard({
    required this.share,
    required this.busy,
    required this.onCopy,
    required this.onRevoke,
  });
  final ConversationShare share;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final url = share.url.toString();
    final expires = share.expiresAt.toLocal().toString().split('.').first;
    return AetherCard(
      title: Text('Shareable link', style: AetherType.title),
      trailing: AetherPill(
        label: 'LIVE',
        color: Aether.successLight,
        icon: Icons.check_circle_outline,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AetherRadius.rMd),
                border: Border.all(color: Aether.hairline),
              ),
              child: Semantics(
                image: true,
                label: 'QR code for shared conversation',
                child: _QrCode(data: url, size: 180),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              border: Border.all(color: Aether.hairline),
            ),
            child: SelectableText(
              url,
              style: AetherType.mono.copyWith(color: Aether.text),
            ),
          ),
          const SizedBox(height: 8),
          Text('Expires $expires', style: AetherType.caption),
          const SizedBox(height: 14),
          _ShareActions(
            busy: busy,
            onCopy: onCopy,
            onRevoke: onRevoke,
          ),
        ],
      ),
    );
  }
}

class _ShareLinkRow extends StatelessWidget {
  const _ShareLinkRow({
    required this.share,
    required this.busy,
    required this.onCopy,
    required this.onRevoke,
  });
  final ConversationShare share;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final expires = share.expiresAt.toLocal().toString().split('.').first;
    return AetherCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            share.url.toString(),
            style: AetherType.body,
          ),
          const SizedBox(height: 6),
          Text('Expires $expires', style: AetherType.caption),
          const SizedBox(height: 10),
          _ShareActions(
            busy: busy,
            onCopy: onCopy,
            onRevoke: onRevoke,
          ),
        ],
      ),
    );
  }
}

class _ShareActions extends StatelessWidget {
  const _ShareActions({
    required this.busy,
    required this.onCopy,
    required this.onRevoke,
  });
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final copy = AetherGhostButton(
        label: 'Copy link',
        icon: Icons.copy,
        onPressed: busy ? null : onCopy,
      );
      final revoke = AetherDangerButton(
        label: 'Revoke',
        icon: Icons.link_off,
        onPressed: busy ? null : onRevoke,
      );
      // Each label needs its scaled text, icon, gap and button padding.
      final actionWidth = 360 * MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth < actionWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [copy, const SizedBox(height: 8), revoke],
        );
      }
      return Row(
        children: [
          Expanded(child: copy),
          const SizedBox(width: 10),
          Expanded(child: revoke),
        ],
      );
    },
  );
}

/// Pure-Dart QR renderer. Encodes [data] into a QrCode and paints it to a
/// crisp monochrome bitmap-style grid. Uses the already-vendored `qr`
/// package so no new dependency is introduced.
class _QrCode extends StatelessWidget {
  const _QrCode({required this.data, this.size = 160});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final qr.QrImage image;
    try {
      final code = qr.QrCode(
        payload: qr.QrPayload.fromString(data),
        errorCorrectLevel: qr.QrErrorCorrectLevel.medium,
      );
      image = qr.QrImage(code);
    } catch (_) {
      // An icon alone could be mistaken for a usable QR code.
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            'QR unavailable. Use Copy link.',
            textAlign: TextAlign.center,
            style: AetherType.body.copyWith(color: Colors.black),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final qr.QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    // QR requires a four-module quiet zone even for low-version short URLs.
    final cellSize = size.shortestSide / (image.moduleCount + 8);
    final paint = Paint()..color = const Color(0xFF0F1115);
    for (var x = 0; x < image.moduleCount; x++) {
      for (var y = 0; y < image.moduleCount; y++) {
        if (image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(
              (x + 4) * cellSize,
              (y + 4) * cellSize,
              cellSize,
              cellSize,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => old.image != image;
}
