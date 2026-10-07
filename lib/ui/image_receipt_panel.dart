import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/image_studio.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Embeddable account-scoped receipt view. The host supplies current authenticated
/// headers; checking status never advertises or performs a new paid submission.
class ImageReceiptPanel extends StatefulWidget {
  const ImageReceiptPanel({
    super.key,
    required this.studio,
    required this.headers,
  });
  final ImageStudio studio;
  final Future<Map<String, String>> Function() headers;

  @override
  State<ImageReceiptPanel> createState() => _ImageReceiptPanelState();
}

class _ImageReceiptPanelState extends State<ImageReceiptPanel> {
  final Map<String, String> _notices = {};
  final Map<String, String> _busy = {};
  final Map<String, String> _outcomes = {};
  final Map<String, Uint8List> _images = {};
  final Set<String> _copied = {};
  int _generation = 0;
  late int _accountGeneration;

  @override
  void initState() {
    super.initState();
    widget.studio.addListener(_changed);
    _accountGeneration = widget.studio.accountGeneration;
  }

  @override
  void didUpdateWidget(ImageReceiptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studio != widget.studio) {
      oldWidget.studio.removeListener(_changed);
      widget.studio.addListener(_changed);
      _generation++;
      _notices.clear();
      _busy.clear();
      _outcomes.clear();
      _images.clear();
      _copied.clear();
      _accountGeneration = widget.studio.accountGeneration;
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_accountGeneration != widget.studio.accountGeneration) {
      _accountGeneration = widget.studio.accountGeneration;
      _generation++;
      _notices.clear();
      _busy.clear();
      _outcomes.clear();
      _images.clear();
      _copied.clear();
    }
    setState(() {});
  }

  Future<void> _check(String requestId, {required bool retrieveImage}) async {
    final generation = _generation;
    final studio = widget.studio;
    final action = retrieveImage ? 'recover' : 'status';
    setState(() {
      _busy[requestId] = action;
      _outcomes.remove(requestId);
    });
    try {
      final headers = await widget.headers();
      if (!mounted || generation != _generation || studio != widget.studio) {
        return;
      }
      final result = await studio.recover(
        requestId: requestId,
        headers: headers,
        retrieveImage: retrieveImage,
      );
      if (!mounted || generation != _generation) return;
      if (result.bytes != null) _images[requestId] = result.bytes!;
      _outcomes[requestId] = retrieveImage
          ? (result.bytes != null ? 'Image recovered' : 'Image unavailable')
          : 'Status checked';
      _notices[requestId] =
          result.notice ??
          (result.imageAvailable
              ? 'Image recovered without a new paid job.'
              : 'Receipt checked.');
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _outcomes[requestId] = retrieveImage
          ? 'Image recovery failed'
          : 'Status check failed';
      _notices[requestId] =
          'Receipt could not be checked. Keep this request ID; do not submit a replacement.';
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy.remove(requestId));
      }
    }
  }

  Future<void> _copyRequestId(String requestId) async {
    await Clipboard.setData(ClipboardData(text: requestId));
    if (!mounted) return;
    setState(() => _copied.add(requestId));
  }

  Future<void> _reload() async {
    try {
      await widget.studio.loadReceipts();
    } catch (_) {
      // The studio publishes a sanitized, account-scoped load error.
    }
  }

  @override
  void dispose() {
    widget.studio.removeListener(_changed);
    super.dispose();
  }

  Color _stateColor(String state) {
    final s = state.toLowerCase();
    if (s.contains('fail') || s.contains('error')) return Aether.dangerC;
    if (s.contains('pending')) return Aether.warnLight;
    if (s.contains('ok') ||
        s.contains('success') ||
        s.contains('ready') ||
        s.contains('confirm')) {
      return Aether.successLight;
    }
    return Aether.textMuted;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Icon(Icons.receipt_long_outlined, size: 18, color: Aether.textMuted),
          const SizedBox(width: 8),
          Expanded(child: Text('Image receipts', style: AetherType.title)),
        ],
      ),
      const SizedBox(height: 12),
      if (widget.studio.receiptLoadError != null) ...[
        Text(widget.studio.receiptLoadError!, style: AetherType.bodyMuted),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
          onPressed: widget.studio.receiptsLoading ? null : _reload,
          child: const Text('Retry loading receipts'),
        ),
      ] else if (widget.studio.receiptsLoading)
        Text('Loading image receipts…', style: AetherType.bodyMuted)
      else if (widget.studio.receipts.isEmpty)
        AetherCard(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No loaded image receipts for this account.',
            style: AetherType.bodyMuted,
          ),
        ),
       for (final record in widget.studio.receipts) ...[
         AetherCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               _sectionLabel('Summary'),
               const SizedBox(height: 8),
               Row(
                 children: [
                   AetherPill(
                     label: record.state.toUpperCase(),
                     color: _stateColor(record.state),
                   ),
                   const SizedBox(width: 8),
                   Expanded(
                     child: Text(
                       record.receipt?.charged == null
                           ? 'Charge not confirmed'
                           : 'Exact charge: ${record.receipt!.charged}',
                       style: AetherType.body.copyWith(fontFamily: Aether.mono),
                     ),
                   ),
                 ],
               ),
               const SizedBox(height: 6),
               Text('Status: ${record.state}', style: AetherType.bodyMuted),
               const SizedBox(height: 16),
               _sectionLabel('Reference'),
               const SizedBox(height: 6),
               SelectableText(
                  'Request ${record.requestId}',
                 style: AetherType.body.copyWith(
                   fontFamily: Aether.mono,
                   fontWeight: FontWeight.w600,
                 ),
               ),
               TextButton.icon(
                 style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                 onPressed: () => _copyRequestId(record.requestId),
                 icon: Icon(
                   _copied.contains(record.requestId)
                       ? Icons.check
                       : Icons.copy_outlined,
                 ),
                 label: Text(
                   _copied.contains(record.requestId)
                       ? 'Request ID copied'
                       : 'Copy request ID',
                 ),
               ),
               const SizedBox(height: 4),
               _sectionLabel('Result'),
               const SizedBox(height: 6),
               if (_outcomes[record.requestId] != null)
                 Text(
                   _outcomes[record.requestId]!,
                   style: AetherType.body.copyWith(fontWeight: FontWeight.w600),
                 ),
               const SizedBox(height: 10),
              if (_notices[record.requestId] != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Aether.surfaceAlt,
                    borderRadius: BorderRadius.circular(AetherRadius.rSm),
                    border: Border.all(color: Aether.hairline),
                  ),
                  child: Text(
                    _notices[record.requestId]!,
                    style: AetherType.body,
                  ),
                )
              else
                Text(
                  'A receipt confirms accounting, not image availability. Recover image checks ownership and retrieves an existing result without a new paid job.',
                  style: AetherType.caption.copyWith(height: 1.5),
                ),
              const SizedBox(height: 10),
               if (_images[record.requestId] != null)
                 Image.memory(
                   _images[record.requestId]!,
                   height: 180,
                   fit: BoxFit.contain,
                   semanticLabel: 'Recovered image for ${record.requestId}',
                   gaplessPlayback: false,
                    errorBuilder: (context, error, stackTrace) => _resultFallback(
                     'Image preview failed. Keep the request ID and retry recovery; no replacement job was submitted.',
                   ),
                 )
               else
                 _resultFallback(
                   'Image result unavailable. Recover checks the existing request and never submits a replacement paid job.',
                 ),
               AetherGhostButton(
                 label: _busy[record.requestId] == 'recover'
                     ? 'Recovering…'
                     : 'Recover image',
                 icon: _busy[record.requestId] == 'recover'
                     ? null
                     : Icons.image_outlined,
                 loading: _busy[record.requestId] == 'recover',
                 onPressed: _busy.containsKey(record.requestId)
                     ? null
                     : () => _check(record.requestId, retrieveImage: true),
               ),
              Align(
                alignment: Alignment.centerLeft,
                child: AetherGhostButton(
                   label: _busy[record.requestId] == 'status'
                       ? 'Checking…'
                       : 'Check status',
                   icon: _busy[record.requestId] == 'status' ? null : Icons.sync,
                   loading: _busy[record.requestId] == 'status',
                   onPressed: _busy.containsKey(record.requestId)
                       ? null
                       : () => _check(record.requestId, retrieveImage: false),
                 ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
    ],
  );

  Widget _sectionLabel(String label) => Text(
    label.toUpperCase(),
    style: AetherType.caption.copyWith(
      color: Aether.textMuted,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
    ),
  );

  Widget _resultFallback(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Aether.surfaceAlt,
      borderRadius: BorderRadius.circular(AetherRadius.rSm),
      border: Border.all(color: Aether.hairline),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.image_not_supported_outlined, color: Aether.textMuted),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: AetherType.bodyMuted)),
      ],
    ),
  );
}
