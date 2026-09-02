import 'package:flutter/material.dart';

import '../core/session_ledger.dart';
import '../core/state.dart';
import '../core/theme.dart';

/// DSH Trajectory view (PR19) — the event-ledger tab for one session:
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await SessionLedger.I.read(widget.sessionId);
    final proj = await SessionLedger.I.projection(widget.sessionId);
    if (!mounted) return;
    setState(() {
      _events = events;
      _proj = proj;
      _loading = false;
    });
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
    'turn_end' => Aether.success,
    'tool_start' => Aether.textMuted,
    'tool_end' => Aether.textMuted,
    'checkpoint' => Aether.warn,
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
        'tool ${((e['toolMs'] as num?) ?? 0) as int}ms · '
        'llm ${((e['llmMs'] as num?) ?? 0) as int}ms',
      'tool_end' =>
        '${((e['ms'] as num?) ?? 0) as int}ms · ${e['ok'] == true ? 'ok' : 'failed'}'
        '${e['error'] != null ? ' · ${e['error']}' : ''}',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = AppState.I.sessionById(widget.sessionId);
    final p = _proj;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text('Trajectory · ${s?.title ?? 'session'}',
            style: const TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            tooltip: 'Reload ledger',
            icon: const Icon(Icons.refresh, size: 19),
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 1.6))
          : Column(
              children: [
                if (p != null && p.turns > 0)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Aether.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Aether.hairline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Session stats (ledger projection)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Aether.text,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${p.turns} turns · ${p.steps} tool calls · '
                          'wall ${(p.wallMs / 1000).toStringAsFixed(1)}s · '
                          'llm ${(p.llmMs / 1000).toStringAsFixed(1)}s · '
                          'tools ${(p.toolMs / 1000).toStringAsFixed(1)}s',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Aether.textMuted,
                          ),
                        ),
                        if (p.toolCounts.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'top: '
                            '${(p.toolCounts.entries.toList()
                                  ..sort((a, b) => b.value.compareTo(a.value)))
                                  .take(4)
                                  .map((e) => '${e.key}×${e.value}')
                                  .join(' · ')}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Aether.textFaint,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                Expanded(
                  child: _events.isEmpty
                      ? Center(
                          child: Text(
                            'No ledger records yet.\nEvents are recorded as '
                            'you run the agent in this session.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Aether.textMuted,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemCount: _events.length,
                          itemBuilder: (_, i) {
                            final e = _events[i];
                            final detail = _detailFor(e);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: Aether.surface,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Aether.hairline),
                              ),
                              child: ListTile(
                                dense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                leading: Icon(
                                  _iconFor(e['kind'] as String?),
                                  size: 17,
                                  color: _colorFor(e['kind'] as String?),
                                ),
                                title: Text(
                                  '#${e['seq'] ?? i} · ${_titleFor(e)}',
                                  style: const TextStyle(fontSize: 12.5),
                                ),
                                subtitle: Text(
                                  '${e['t'] ?? ''}'
                                  '${detail.isEmpty ? '' : '\n$detail'}',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: Aether.textFaint,
                                  ),
                                ),
                                isThreeLine: detail.isNotEmpty,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
