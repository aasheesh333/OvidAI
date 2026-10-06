import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

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
    if (!listEquals(widget.lines, oldWidget.lines)) _followBottom();
  }

  void _followBottom() {
    // Capture intent before layout grows the scroll extent. A burst can add
    // much more than 48px, including when the capped buffer length is unchanged.
    if (_scroll.hasClients && _scroll.position.extentAfter > 48) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Aether.codeBg,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: Aether.hairline),
      ),
      child: widget.lines.isEmpty
          ? Center(
              child: Text(
                'Waiting for output…',
                style: AetherType.mono.copyWith(color: Aether.textMuted),
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
                  style: AetherType.mono.copyWith(
                    height: 1.4,
                    color: Aether.text,
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
  void didUpdateWidget(PluginInstallProgressSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_onChange);
      widget.progress.addListener(_onChange);
    }
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
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
        child: AetherSheet(
      title: widget.title,
      actions: [
        if (p.done)
          AetherPrimaryButton(
            label: p.ok ? 'Done' : 'Close',
            onPressed: () => Navigator.of(context).pop(),
          )
        else
          SizedBox(
            width: double.infinity,
            child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Aether.textMuted,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: const Text('Close — install continues', textAlign: TextAlign.center),
            onPressed: () => Navigator.of(context).pop(),
            ),
          ),
      ],
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.subtitle != null) ...[
              Text(widget.subtitle!, style: AetherType.bodyMuted),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                if (!p.done)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      valueColor: AlwaysStoppedAnimation<Color>(Aether.accent),
                    ),
                  )
                else
                  Icon(
                    p.ok ? Icons.check_circle : Icons.error,
                    size: 18,
                    color: p.ok ? Aether.successLight : Aether.danger,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.phase,
                    style: AetherType.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(AetherRadius.rPill),
              child: LinearProgressIndicator(
                value: p.done ? (p.progress ?? 0) : p.progress,
                minHeight: 6,
                backgroundColor: Aether.surfaceAlt,
                valueColor: AlwaysStoppedAnimation<Color>(
                  p.done && !p.ok ? Aether.danger : Aether.accent,
                ),
              ),
            ),
            const SizedBox(height: 14),
            ProgressLogView(lines: p.lines),
            if (p.done) ...[
              const SizedBox(height: 12),
              AetherCard(
                color: (p.ok ? Aether.success : Aether.danger).withValues(
                  alpha: 0.06,
                ),
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      p.ok ? Icons.check_circle : Icons.error_outline,
                      size: 16,
                      color: p.ok ? Aether.successLight : Aether.dangerC,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p.summary,
                        style: AetherType.body.copyWith(
                          color: p.ok ? Aether.successLight : Aether.dangerC,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
      ),
        ),
        ),
      ),
    );
  }
}
