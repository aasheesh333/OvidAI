import 'dart:typed_data';

import 'package:flutter/material.dart';

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
  final Set<String> _busy = {};
  final Map<String, Uint8List> _images = {};
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
      _images.clear();
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
      _images.clear();
    }
    setState(() {});
  }

  Future<void> _check(String requestId, {bool retrieveImage = false}) async {
    final generation = _generation;
    final studio = widget.studio;
    setState(() => _busy.add(requestId));
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
      _notices[requestId] =
          result.notice ??
          (result.imageAvailable
              ? 'Image recovered without a new paid job.'
              : 'Receipt checked.');
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _notices[requestId] =
          'Receipt could not be checked. Keep this request ID; do not submit a replacement.';
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy.remove(requestId));
      }
    }
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
    if (s.contains('ok') || s.contains('success') || s.contains('ready')) {
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    'Request ${record.requestId}',
                    style: AetherType.body.copyWith(
                      fontFamily: Aether.mono,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AetherPill(
                    label: record.state.toUpperCase(),
                    color: _stateColor(record.state),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('Status: ${record.state}', style: AetherType.bodyMuted),
              const SizedBox(height: 4),
              Text(
                record.receipt?.charged == null
                    ? 'Charge: not confirmed'
                    : 'Exact charge: ${record.receipt!.charged}',
                style: AetherType.body.copyWith(fontFamily: Aether.mono),
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
                ),
              AetherGhostButton(
                label: 'Recover image',
                icon: Icons.image_outlined,
                onPressed: _busy.contains(record.requestId)
                    ? null
                    : () => _check(record.requestId, retrieveImage: true),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: AetherGhostButton(
                  label: _busy.contains(record.requestId)
                      ? 'Checking…'
                      : 'Check status',
                  icon: _busy.contains(record.requestId) ? null : Icons.sync,
                  loading: _busy.contains(record.requestId),
                  onPressed: _busy.contains(record.requestId)
                      ? null
                      : () => _check(record.requestId),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
    ],
  );
}
