import 'package:flutter/material.dart';

import '../core/theme.dart';

/// WS2: live progress for plugin installs (and MCP runtime installs).
///
/// The install flow pushes phase changes, determinate progress, and
/// terminal-style log lines into [PluginInstallProgress]; the sheet
/// renders them with follow-mode auto-scroll, so the latest output and
/// real errors are always visible. The follow threshold (48px) is copied
/// from the studio terminal: scrolled-up reading is never yanked back
/// down by new output.

/// Controller driving [PluginInstallProgressSheet]: the install flow
/// pushes phase/progress/log lines; the sheet renders them.
class PluginInstallProgress extends ChangeNotifier {
  /// Max buffered log lines — a chatty package manager must not grow
  /// the buffer without bound.
  static const int maxLines = 300;

  /// Max length of a single buffered line.
  static const int maxLineLength = 2000;

  String _phase = 'Starting…';
  double? _progress; // null = indeterminate
  final List<String> _lines = [];
  bool _done = false;
  bool _ok = false;
  String _summary = '';

  String get phase => _phase;
  double? get progress => _progress;
  List<String> get lines => List.unmodifiable(_lines);
  bool get done => _done;
  bool get ok => _ok;
  String get summary => _summary;

  /// Sets the phase label and optional determinate progress (0.0–1.0,
  /// null for indeterminate). Rapid byte-progress updates are coalesced:
  /// no notification fires unless the label or whole-percent progress
  /// actually changed.
  void setPhase(String phase, [double? progress]) {
    final p = progress == null
        ? null
        : (progress.clamp(0.0, 1.0) * 100).round() / 100;
    if (_phase == phase && _progress == p) return;
    _phase = phase;
    _progress = p;
    notifyListeners();
  }

  /// Appends one terminal-style log line (capped in count and length).
  void line(String raw) {
    var l = raw;
    if (l.length > maxLineLength) l = '${l.substring(0, maxLineLength)}…';
    _lines.add(l);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    notifyListeners();
  }

  /// Marks the install finished; the sheet shows [summary] with a Done /
  /// Close button.
  void finish({required bool ok, required String summary}) {
    _done = true;
    _ok = ok;
    _summary = summary;
    if (ok) _progress = 1.0;
    notifyListeners();
  }
}

/// Wraps the source resolver's raw byte progress into a readable label:
/// `Fetching <sourceId>: 42%` when the total is known, otherwise
/// `Fetching <sourceId>: 1.2 MB`. The completed file count is logged as
/// its own line by the install flow (`Fetched <sourceId>: N files`).
String fetchProgressLabel(String sourceId, int received, int? total) {
  if (total != null && total > 0) {
    final pct = ((received / total).clamp(0.0, 1.0) * 100).round();
    return 'Fetching $sourceId: $pct%';
  }
  return 'Fetching $sourceId: ${_formatBytes(received)} received';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Terminal-style scrolling log with follow-mode auto-scroll: new lines
/// only pull the view to the bottom when the user is already within 48px
/// of it (studio terminal pattern).
class ProgressLogView extends StatefulWidget {
  final List<String> lines;
  final double height;

  const ProgressLogView({super.key, required this.lines, this.height = 220});

  @override
  State<ProgressLogView> createState() => _ProgressLogViewState();
}

class _ProgressLogViewState extends State<ProgressLogView> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ProgressLogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length != oldWidget.lines.length) _followBottom();
  }

  void _followBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      // Follow-mode: only auto-scroll when the user is already near the
      // bottom — scrolling up to read earlier output must not be yanked
      // back down by every new line.
      if (pos.maxScrollExtent - pos.pixels > 48) return;
      _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: widget.lines.isEmpty
          ? Text(
              'Waiting for output…',
              style: TextStyle(
                fontSize: 11,
                fontFamily: Aether.mono,
                color: Aether.textMuted,
              ),
            )
          : Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: ListView.builder(
                controller: _scroll,
                itemCount: widget.lines.length,
                itemBuilder: (context, i) => Text(
                  widget.lines[i],
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: Aether.mono,
                    height: 1.35,
                  ),
                ),
              ),
            ),
    );
  }
}

/// Bottom-sheet dialog: determinate/indeterminate progress bar + phase
/// label + streaming terminal-style log. Pinned so the latest output is
/// always visible; dismissible mid-install (the install keeps running and
/// the result is also reported via SnackBar).
class PluginInstallProgressSheet extends StatefulWidget {
  final PluginInstallProgress progress;
  final String title;
  final String? subtitle;

  const PluginInstallProgressSheet({
    super.key,
    required this.progress,
    required this.title,
    this.subtitle,
  });

  @override
  State<PluginInstallProgressSheet> createState() =>
      _PluginInstallProgressSheetState();
}

class _PluginInstallProgressSheetState
    extends State<PluginInstallProgressSheet> {
  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.progress;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          10,
          18,
          18 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Aether.textMuted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              widget.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                widget.subtitle!,
                style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.phase,
                    style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!p.done) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                ] else
                  Icon(
                    p.ok ? Icons.check_circle : Icons.error,
                    size: 16,
                    color: p.ok ? Aether.successLight : Aether.danger,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (p.progress == null)
              const LinearProgressIndicator()
            else
              LinearProgressIndicator(value: p.progress),
            const SizedBox(height: 10),
            ProgressLogView(lines: p.lines),
            if (p.done) ...[
              const SizedBox(height: 10),
              Text(
                p.summary,
                style: TextStyle(
                  fontSize: 12.5,
                  color: p.ok ? Aether.successLight : Aether.danger,
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (p.done)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: p.ok ? Aether.accent : Aether.surfaceRaised,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  p.ok ? 'Done' : 'Close',
                  style: const TextStyle(fontSize: 13.5),
                ),
              )
            else
              Text(
                'You can close this sheet — the install keeps running.',
                style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}
