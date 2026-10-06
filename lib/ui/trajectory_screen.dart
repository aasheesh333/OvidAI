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
///
/// The body is the reusable [TrajectoryEventsView], also embedded by the
/// Activity hub's Events tab; this screen only adds the app bar with the
/// reload action.
class TrajectoryScreen extends StatefulWidget {
  final String sessionId;
  const TrajectoryScreen({super.key, required this.sessionId});

  @override
  State<TrajectoryScreen> createState() => _TrajectoryScreenState();
}

class _TrajectoryScreenState extends State<TrajectoryScreen> {
  final _viewKey = GlobalKey<TrajectoryEventsViewState>();

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
            onPressed: () => _viewKey.currentState?.reload(),
          ),
        ],
      ),
      body: TrajectoryEventsView(
        key: _viewKey,
        sessionId: widget.sessionId,
      ),
    );
  }
}

/// The event-ledger list: stats projection card plus one premium card per
/// record (mono timestamp, `#seq · title`, one-line detail, JSON behind a
/// disclosure dialog). Owns its own load lifecycle — used standalone by
/// [TrajectoryScreen] and embedded by the Activity hub's Events tab.
class TrajectoryEventsView extends StatefulWidget {
  final String sessionId;
  const TrajectoryEventsView({super.key, required this.sessionId});

  @override
  State<TrajectoryEventsView> createState() => TrajectoryEventsViewState();
}

class TrajectoryEventsViewState extends State<TrajectoryEventsView> {
  List<Map<String, dynamic>> _events = [];
  SessionProjection? _proj;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Re-read the ledger from disk (the app-bar reload contract).
  Future<void> reload() => _load();

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
    'tool_end' => Icons.check_circle_outlined,
    'checkpoint' => Icons.save_outlined,
    'note' => Icons.notes_outlined,
    _ => Icons.circle_outlined,
  };

  Color _colorFor(String? kind) => switch (kind) {
    'turn_start' => Aether.accent,
    'turn_end' => Aether.successLight,
    'tool_start' => Aether.textMuted,
    'tool_end' => Aether.textMuted,
    'checkpoint' => Aether.warnLight,
    'note' => Aether.danger,
    _ => Aether.textFaint,
  };

  String _titleFor(Map<String, dynamic> e) {
    final kind = e['kind'] as String? ?? '';
    return switch (kind) {
      'turn_start' => 'Turn start (turn ${e['turn'] ?? '?'})',
      'turn_end' => 'Turn end',
      'tool_start' => 'Tool: ${e['tool'] ?? '?'}',
      'tool_end' => 'Tool done: ${e['tool'] ?? '?'}',
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
      'note' => '${e['text'] ?? e['message'] ?? ''}',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = _proj;
    return _loading
        ? const Center(child: CircularProgressIndicator(strokeWidth: 1.6))
        : _error != null
        ? SingleChildScrollView(
            child: AetherEmptyState(
              icon: Icons.error_outline,
              title: 'Could not load ledger',
              message: _error,
              action: AetherSecondaryButton(label: 'Retry', onPressed: _load),
            ),
          )
        : CustomScrollView(
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
                          Text(
                            '${p.turns} turns · ${p.steps} tool calls · '
                            'wall ${formatCompactDuration(Duration(milliseconds: p.wallMs))} · '
                            'llm ${formatCompactDuration(Duration(milliseconds: p.llmMs))} · '
                            'tools ${formatCompactDuration(Duration(milliseconds: p.toolMs))}',
                            style: AetherType.bodyMuted.copyWith(fontSize: 12),
                          ),
                          if (p.toolCounts.isNotEmpty) ...[
                            const SizedBox(height: AetherSpacing.space2),
                            Text(
                              'top: '
                              '${(p.toolCounts.entries.toList()
                                    ..sort((a, b) => b.value.compareTo(a.value)))
                                    .take(4)
                                    .map((e) => '${e.key}×${e.value}')
                                    .join(' · ')}',
                              style: AetherType.caption,
                            ),
                          ],
                        ],
                      ),
                    ),
                  )),
                if (_events.isEmpty)
                         const SliverToBoxAdapter(child: AetherEmptyState(
                          key: ValueKey('trajectory-empty'),
                          icon: Icons.timeline_outlined,
                          title: 'No ledger records yet',
                          message:
                              'Events are recorded as you run the agent in '
                              'this session.',
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
                            final color = _colorFor(kind);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: AetherCard(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  12,
                                  14,
                                  12,
                                ),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      _iconFor(kind),
                                      size: 16,
                                      color: color,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '${e['t'] ?? ''}',
                                            style: AetherType.mono.copyWith(
                                              fontSize: 11,
                                              color: Aether.textFaint,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '#${e['seq'] ?? i - 1} · '
                                            '${_titleFor(e)}',
                                            style: AetherType.title.copyWith(
                                              fontSize: 13,
                                            ),
                                          ),
                                           if (detail.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              detail,
                                              style:
                                                  AetherType.bodyMuted.copyWith(
                                                fontSize: 12,
                                              ),
                                            ),
                                           ],
                                           TextButton(
                                             key: ValueKey('trajectory-detail-${e['seq'] ?? i - 1}'),
                                             onPressed: () => _showDetail(e),
                                             child: const Text('View details'),
                                           ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        )),
                SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom)),
              ],
            );
  }
}
