import 'dart:convert';

import 'package:flutter/material.dart';
import '../core/format.dart';

import '../core/session_ledger.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Trajectory view (PR19) — the event-ledger tab for one session:
/// every turn / tool / checkpoint / recovery record from the append-only
/// ledger, with per-record detail (tokens, duration, data). The summary
/// strip carries the stats projection (turns, steps, wall time, top tools).
class TrajectoryScreen extends StatefulWidget {
  final String sessionId;
  const TrajectoryScreen({super.key, required this.sessionId});

  @override
  State<TrajectoryScreen> createState() => _TrajectoryScreenState();
}

class _TrajectoryScreenState extends State<TrajectoryScreen> {
  List<Map<String, dynamic>> _events = [];
  SessionProjection? _proj;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final events = await SessionLedger.I.read(widget.sessionId);
      final proj = await SessionLedger.I.projection(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _events = events;
        _proj = proj;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _showDetail(Map<String, dynamic> event) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(_titleFor(event)),
        content: SelectableText(
          const JsonEncoder.withIndent('  ').convert(event),
          style: AetherType.mono,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(String? kind) => switch (kind) {
    'turn_start' => Icons.play_arrow_outlined,
    'turn_end' => Icons.flag_outlined,
    'tool_start' => Icons.build_outlined,
    'tool_end' => Icons.check_circle_outline,
    'subagent_end' => Icons.check_circle_outline,
    'checkpoint' => Icons.save_outlined,
    'note' => Icons.notes_outlined,
    _ => Icons.circle_outlined,
  };

  bool _isFailed(Map<String, dynamic> e) =>
      (e['kind'] == 'tool_end' || e['kind'] == 'subagent_end') &&
      e['ok'] == false;

  IconData _eventIcon(Map<String, dynamic> e) =>
      _isFailed(e) ? Icons.error_outline : _iconFor(e['kind'] as String?);

  Color _colorFor(String? kind, {bool failed = false}) {
    if (failed) return Aether.danger;
    return switch (kind) {
      'turn_start' => Aether.accent,
      'turn_end' => Aether.successLight,
      'tool_start' => Aether.textMuted,
      'tool_end' => Aether.textMuted,
      'subagent_end' => Aether.textMuted,
      'checkpoint' => Aether.warnLight,
      'note' => Aether.danger,
      _ => Aether.textFaint,
    };
  }

  String _titleFor(Map<String, dynamic> e) {
    final kind = e['kind'] as String? ?? '';
    return switch (kind) {
      'turn_start' => 'Turn start (turn ${e['turn'] ?? '?'})',
      'turn_end' => 'Turn end',
      'tool_start' => 'Tool: ${e['tool'] ?? '?'}',
      'tool_end' =>
        'Tool ${e['ok'] == true ? 'succeeded' : 'failed'}: ${e['tool'] ?? '?'}',
      'subagent_end' =>
        'Subagent ${e['ok'] == true ? 'succeeded' : 'failed'}: ${e['agent'] ?? '?'}',
      'checkpoint' => 'Checkpoint (${e['at'] ?? '?'})',
      'note' => 'Note',
      _ => kind,
    };
  }

  String _detailFor(Map<String, dynamic> e) {
    final kind = e['kind'] as String? ?? '';
    return switch (kind) {
      'turn_start' => 'model request · ${e['msgs'] ?? '?'} rows',
      'turn_end' =>
        'steps ${e['steps'] ?? 0} · turns ${e['turns'] ?? 0} · '
         'tool ${(e['toolMs'] as num?)?.toInt() ?? 0}ms · '
         'llm ${(e['llmMs'] as num?)?.toInt() ?? 0}ms',
      'tool_end' =>
          '${(e['ms'] as num?)?.toInt() ?? 0}ms · ${e['ok'] == true ? 'ok' : 'failed'}'
          '${e['error'] != null ? ' · ${e['error']}' : ''}',
      'subagent_end' =>
          '${e['ok'] == true ? 'ok' : 'failed'}'
          '${e['error'] != null ? ' · ${e['error']}' : ''}',
      'note' => '${e['text'] ?? e['message'] ?? ''}',
      _ => '',
    };
  }

  String _accessibilityLabel(Map<String, dynamic> e) {
    final title = _titleFor(e);
    switch (e['kind']) {
      case 'tool_end':
        final ms = (e['ms'] as num?)?.toInt() ?? 0;
        final error = e['error'];
        return '$title. ${ms}ms.${error != null ? ' Error: $error' : ''}';
      case 'subagent_end':
        return '$title.${e['error'] != null ? ' Error: ${e['error']}' : ''}';
      default:
        final detail = _detailFor(e);
        return detail.isEmpty ? title : '$title. ${detail.replaceAll(' · ', '. ')}';
    }
  }

  Widget _stat(String label, String value) => SizedBox(
        width: 92,
        child: Semantics(
          label: '$label: $value',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AetherType.caption),
              const SizedBox(height: 2),
              Text(value, style: AetherType.title.copyWith(fontSize: 14)),
            ],
          ),
        ),
      );

  Widget _stats(SessionProjection p) => Wrap(
        spacing: AetherSpacing.space4,
        runSpacing: AetherSpacing.space3,
        children: [
          _stat('Turns', '${p.turns}'),
          _stat('Tool calls', '${p.steps}'),
          _stat('Wall time', formatCompactDuration(Duration(milliseconds: p.wallMs))),
          _stat('LLM time', formatCompactDuration(Duration(milliseconds: p.llmMs))),
          _stat('Tool time', formatCompactDuration(Duration(milliseconds: p.toolMs))),
        ],
      );

  String _topTools(SessionProjection p) => (p.toolCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)))
      .take(4)
      .map((e) => '${e.key}×${e.value}')
      .join(' · ');

  Widget _ledgerContent(SessionProjection? p) => CustomScrollView(
        slivers: [
          if (p != null && p.turns > 0)
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AetherSpacing.space4,
                AetherSpacing.space3,
                AetherSpacing.space4,
                AetherSpacing.space2,
              ),
              child: AetherCard(
                key: const ValueKey('trajectory-stats'),
                padding: const EdgeInsets.all(AetherSpacing.space4),
                title: const Text('Session stats (ledger projection)'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _stats(p),
                    if (p.toolCounts.isNotEmpty) ...[
                      const SizedBox(height: AetherSpacing.space3),
                      Text(
                        'top: ${_topTools(p)}',
                        style: AetherType.caption,
                      ),
                    ],
                  ],
                ),
              ),
            )),
          if (_error != null && _events.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: AetherEmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not refresh ledger',
                  message: _error,
                  action: AetherSecondaryButton(label: 'Retry', onPressed: _load),
                ),
              ),
            ),
          if (_events.isEmpty)
            const SliverToBoxAdapter(child: AetherEmptyState(
              key: ValueKey('trajectory-empty'),
              icon: Icons.timeline_outlined,
              title: 'No ledger records yet',
              message: 'Events are recorded as you run the agent in this session.',
            ))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
              sliver: SliverList.builder(
                itemCount: _events.length + 1,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return const Padding(
                      padding: EdgeInsets.fromLTRB(2, 4, 2, 10),
                      child: AetherSectionTitle(
                        key: ValueKey('trajectory-events-title'),
                        eyebrow: 'Events',
                      ),
                    );
                  }
                  final e = _events[i - 1];
                  final detail = _detailFor(e);
                  final kind = e['kind'] as String?;
                  final color = _colorFor(kind, failed: _isFailed(e));
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AetherCard(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_eventIcon(e), size: 16, color: color),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('${e['t'] ?? ''}', style: AetherType.mono.copyWith(fontSize: 11, color: Aether.textFaint)),
                                const SizedBox(height: 2),
                                Text('#${e['seq'] ?? i - 1} · ${_titleFor(e)}', style: AetherType.title.copyWith(fontSize: 13)),
                                if (detail.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(detail, style: AetherType.bodyMuted.copyWith(fontSize: 12)),
                                ],
                                Semantics(
                                  label: _accessibilityLabel(e),
                                  button: true,
                                  child: TextButton(
                                    key: ValueKey('trajectory-detail-${e['seq'] ?? i - 1}'),
                                    onPressed: () => _showDetail(e),
                                    child: const Text('View details'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom)),
        ],
      );

  Widget _body() {
    if (_loading && _events.isEmpty && _proj == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 1.6));
    }
    if (_error != null && _events.isEmpty) {
      return SingleChildScrollView(
        child: AetherEmptyState(
          icon: Icons.error_outline,
          title: 'Could not load ledger',
          message: _error,
          action: AetherSecondaryButton(label: 'Retry', onPressed: _load),
        ),
      );
    }
    return Stack(
      children: [
        _ledgerContent(_proj),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.sessionById(widget.sessionId);
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Tooltip(
          message: 'Trajectory · ${s?.title ?? 'session'}',
          child: Text(
            'Trajectory · ${s?.title ?? 'session'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Reload ledger',
            icon: const Icon(Icons.refresh, size: 19),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
       body: _body(),
    );
  }
}
