import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/image_studio.dart';
import '../core/native_share.dart';
import '../core/recovered_images.dart';
import '../core/theme.dart';
import 'share_actions.dart';
import 'widgets/aether_primitives.dart';

/// Embeddable account-scoped receipt view. The host supplies current authenticated
/// headers; checking status never advertises or performs a new paid submission.
class ImageReceiptPanel extends StatefulWidget {
  const ImageReceiptPanel({
    super.key,
    required this.studio,
    required this.headers,
    this.sessionTitle,
    this.onOpenSession,
    this.persistRecovered,
    this.saveFile,
    this.shareFile,
  });
  final ImageStudio studio;
  final Future<Map<String, String>> Function() headers;

  /// Title of the chat that requested an image (null when deleted/unknown).
  final String? Function(String sessionId)? sessionTitle;

  /// Opens the originating chat.
  final void Function(String sessionId)? onOpenSession;

  /// Keeps recovered bytes (file + chat attachment). Defaults to
  /// [RecoveredImages.persist].
  final Future<RecoveredImage?> Function(
    ImageRequestRecord record,
    Uint8List bytes,
  )?
  persistRecovered;

  /// Test seams for Save (system "Save as") and Share.
  final Future<bool> Function(String path, String fileName)? saveFile;
  final Future<void> Function(String path)? shareFile;

  @override
  State<ImageReceiptPanel> createState() => _ImageReceiptPanelState();
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatWhen(DateTime value) {
  final d = value.toLocal();
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${_months[d.month - 1]} ${d.day}, $hh:$mm';
}

/// Plain-language state text (the pill carries the short label).
String _stateText(String state) => switch (state) {
  'confirmed' => 'Image completed',
  'failed' => 'Image request failed',
  'pending' => 'Waiting for the result',
  _ => 'Outcome not known yet — check status',
};

Future<bool> _systemSave(String path, String fileName) async {
  const channel = MethodChannel('ovid/native');
  return await channel.invokeMethod<bool>('safExportFile', {
        'sourcePath': path,
        'fileName': fileName,
      }) ==
      true;
}

class _ImageReceiptPanelState extends State<ImageReceiptPanel> {
  final Map<String, String> _notices = {};
  final Map<String, String> _busy = {};
  final Map<String, String> _outcomes = {};
  final Map<String, Uint8List> _images = {};
  final Map<String, RecoveredImage> _files = {};
  final Set<String> _copied = {};
  int _generation = 0;
  late int _accountGeneration;

  @override
  void initState() {
    super.initState();
    widget.studio.addListener(_changed);
    _accountGeneration = widget.studio.accountGeneration;
    // Never rely only on the sign-in load: refresh whenever the screen opens
    // (unless a load is running or its error + Retry is already shown).
    if (!widget.studio.receiptsLoading &&
        widget.studio.receiptLoadError == null) {
      scheduleMicrotask(_reload);
    }
  }

  @override
  void didUpdateWidget(ImageReceiptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studio != widget.studio) {
      oldWidget.studio.removeListener(_changed);
      widget.studio.addListener(_changed);
      _reset();
      _accountGeneration = widget.studio.accountGeneration;
    }
  }

  void _reset() {
    _generation++;
    _notices.clear();
    _busy.clear();
    _outcomes.clear();
    _images.clear();
    _files.clear();
    _copied.clear();
  }

  void _changed() {
    if (!mounted) return;
    if (_accountGeneration != widget.studio.accountGeneration) {
      _accountGeneration = widget.studio.accountGeneration;
      _reset();
    }
    setState(() {});
  }

  Future<void> _check(
    ImageRequestRecord record, {
    required bool retrieveImage,
  }) async {
    final requestId = record.requestId;
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
      final bytes = result.bytes;
      if (bytes != null) {
        _images[requestId] = bytes;
        // Keep a copy (Save/Share, chat) without holding the busy state.
        unawaited(_keep(result.record, bytes, generation));
      }
      _outcomes[requestId] = retrieveImage
          ? (bytes != null ? 'Image recovered' : 'Image unavailable')
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

  Future<void> _keep(
    ImageRequestRecord record,
    Uint8List bytes,
    int generation,
  ) async {
    final kept = await _persist(record, bytes);
    if (kept == null || !mounted || generation != _generation) return;
    setState(() {
      _files[record.requestId] = kept;
      if (kept.sessionId != null) {
        _notices[record.requestId] =
            'Image recovered without a new paid job and added back to its chat.';
      }
    });
  }

  Future<RecoveredImage?> _persist(
    ImageRequestRecord record,
    Uint8List bytes,
  ) async {
    try {
      return await (widget.persistRecovered ?? RecoveredImages.persist)(
        record,
        bytes,
      );
    } catch (_) {
      return null; // Preview and full-screen view still work from memory.
    }
  }

  Future<void> _save(RecoveredImage kept) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = kept.file.uri.pathSegments.last;
    String message;
    try {
      final saved = await (widget.saveFile ?? _systemSave)(
        kept.file.path,
        'ovid-$name',
      );
      message = saved ? 'Image saved' : 'Save cancelled';
    } catch (_) {
      message = 'Could not save the image. Try Share instead.';
    }
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(RecoveredImage kept) => showNativeShare(
    context,
    () => (widget.shareFile ?? NativeShare.file)(kept.file.path),
  );

  void _openViewer(Uint8List bytes) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RecoveredImageViewer(bytes: bytes),
      ),
    );
  }

  Future<void> _copyRequestId(String requestId) async {
    await Clipboard.setData(ClipboardData(text: requestId));
    if (!mounted) return;
    setState(() => _copied.add(requestId));
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Request ID copied')));
  }

  Future<void> _reload() async {
    if (!mounted) return;
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

  /// Newest first. Rows written before timestamps existed follow the dated
  /// rows, most recently appended first.
  List<ImageRequestRecord> _sorted() {
    final rows = widget.studio.receipts.toList();
    final order = {for (var i = 0; i < rows.length; i++) rows[i].requestId: i};
    rows.sort((a, b) {
      final at = a.createdAt, bt = b.createdAt;
      if (at != null && bt != null) return bt.compareTo(at);
      if (at != null) return -1;
      if (bt != null) return 1;
      return order[b.requestId]!.compareTo(order[a.requestId]!);
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(child: _buildReceipts());

  Widget _buildReceipts() => Column(
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
      const SizedBox(height: 6),
      Text(
        'Each Ovid Cloud image request keeps a receipt. Recover an image or '
        'check its status here without starting a new paid request.',
        style: AetherType.caption.copyWith(height: 1.5),
      ),
      const SizedBox(height: 12),
      if (widget.studio.receiptLoadError != null) ...[
        Text(widget.studio.receiptLoadError!, style: AetherType.bodyMuted),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
          onPressed: widget.studio.receiptsLoading ? null : _reload,
          child: const Text('Retry loading receipts'),
        ),
      ] else if (widget.studio.receiptsLoading &&
          widget.studio.receipts.isEmpty)
        Text('Loading image receipts…', style: AetherType.bodyMuted)
      else if (widget.studio.receipts.isEmpty)
        AetherCard(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No image receipts yet — images you generate with Ovid Cloud appear here.',
            style: AetherType.bodyMuted,
          ),
        ),
      for (final record in _sorted()) ...[
        _card(record),
        const SizedBox(height: 10),
      ],
    ],
  );

  Widget _card(ImageRequestRecord record) {
    final id = record.requestId;
    final chat = record.sessionId == null
        ? null
        : widget.sessionTitle?.call(record.sessionId!);
    final image = _images[id];
    final kept = _files[id];
    return AetherCard(
      key: ValueKey('receipt-$id'),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            record.createdAt == null
                ? 'Image request'
                : _formatWhen(record.createdAt!),
            key: ValueKey('receipt-title-$id'),
            style: AetherType.h2,
          ),
          if (chat != null && chat.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              'In “${chat.trim()}”',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AetherType.bodyMuted,
            ),
          ],
          const SizedBox(height: 10),
          _sectionLabel('Summary'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AetherPill(
                label: record.state.toUpperCase(),
                color: _stateColor(record.state),
              ),
              Text(_stateText(record.state), style: AetherType.body),
            ],
          ),
          const SizedBox(height: 6),
          // Allowance impact only; the internal decimal is never shown.
          Text(
            imageChargeSummary(record.state, record.receipt?.charged),
            key: ValueKey('receipt-charge-$id'),
            style: AetherType.bodyMuted,
          ),
          const SizedBox(height: 16),
          _sectionLabel('Result'),
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_outcomes[id] != null)
                  Text(
                    _outcomes[id]!,
                    style: AetherType.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (_notices[id] != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(AetherRadius.rSm),
                      border: Border.all(color: Aether.hairline),
                    ),
                    child: Text(_notices[id]!, style: AetherType.body),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (image != null)
            Semantics(
              button: true,
              label: 'Open recovered image full screen',
              child: GestureDetector(
                key: ValueKey('receipt-image-$id'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _openViewer(image),
                child: SizedBox(
                  width: double.infinity,
                  height: 180,
                  child: Image.memory(
                    image,
                    height: 180,
                    fit: BoxFit.contain,
                    semanticLabel: 'Recovered image',
                    gaplessPlayback: false,
                    errorBuilder: (context, error, stackTrace) => _resultFallback(
                      'Image preview failed. Keep the request ID and retry recovery; no replacement job was submitted.',
                    ),
                  ),
                ),
              ),
            )
          else
            _resultFallback(
              'Recover checks the existing request and never submits a replacement paid job.',
            ),
          const SizedBox(height: 6),
          OverflowBar(
            spacing: 8,
            overflowSpacing: 4,
            children: [
              if (kept != null) ...[
                AetherGhostButton(
                  key: ValueKey('receipt-save-$id'),
                  label: 'Save',
                  icon: Icons.download_outlined,
                  onPressed: () => _save(kept),
                ),
                AetherGhostButton(
                  key: ValueKey('receipt-share-$id'),
                  label: 'Share',
                  icon: Icons.share_outlined,
                  onPressed: () => _share(kept),
                ),
                if (kept.sessionId != null && widget.onOpenSession != null)
                  AetherGhostButton(
                    key: ValueKey('receipt-open-chat-$id'),
                    label: 'Open in chat',
                    icon: Icons.chat_bubble_outline,
                    onPressed: () => widget.onOpenSession!(kept.sessionId!),
                  ),
              ] else
                AetherGhostButton(
                  label: _busy[id] == 'recover'
                      ? 'Recovering…'
                      : 'Recover image',
                  icon: _busy[id] == 'recover' ? null : Icons.image_outlined,
                  loading: _busy[id] == 'recover',
                  onPressed: _busy.containsKey(id)
                      ? null
                      : () => _check(record, retrieveImage: true),
                ),
              AetherGhostButton(
                label: _busy[id] == 'status' ? 'Checking…' : 'Check status',
                icon: _busy[id] == 'status' ? null : Icons.sync,
                loading: _busy[id] == 'status',
                onPressed: _busy.containsKey(id)
                    ? null
                    : () => _check(record, retrieveImage: false),
              ),
            ],
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: ValueKey('receipt-details-$id'),
              maintainState: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text('Details', style: AetherType.label),
              children: [
                _sectionLabel('Reference'),
                const SizedBox(height: 6),
                SelectableText(
                  'Request $id',
                  style: AetherType.body.copyWith(
                    fontFamily: Aether.mono,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  onPressed: () => _copyRequestId(id),
                  icon: Icon(
                    _copied.contains(id) ? Icons.check : Icons.copy_outlined,
                  ),
                  label: Text(
                    _copied.contains(id)
                        ? 'Request ID copied'
                        : 'Copy request ID',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) => Text(
    label,
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
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Image result unavailable', style: AetherType.body),
              Text(message, style: AetherType.bodyMuted),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Full-screen, zoomable view of a recovered image.
class _RecoveredImageViewer extends StatelessWidget {
  const _RecoveredImageViewer({required this.bytes});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('Recovered image'),
    ),
    body: InteractiveViewer(
      maxScale: 6,
      child: Center(
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          semanticLabel: 'Recovered image',
        ),
      ),
    ),
  );
}
