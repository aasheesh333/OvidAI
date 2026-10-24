import 'package:flutter/material.dart';

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/trajectory_client.dart';
import '../core/cloud/trajectory_projection.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Trajectory view (PR19) — the durable event timeline for one session.
///
/// P8 Task 20 re-pointed this screen from the deleted local JSONL ledger to
/// the gateway's event mirror:
///
///   `GET /sessions/:id/events?tail=1&limit=N` — newest page (ascending)
///   `GET /sessions/:id/events?before=<seq>&limit=N` — older page
///
/// The screen is opened with a LOCAL `ChatSession.id`; it resolves the server
/// UUID through [CloudSessionStore] before the first request. A bare request
/// without a cursor returns from the BEGINNING on the server, so the tail is
/// always explicit.
class TrajectoryScreen extends StatefulWidget {
  final String sessionId;
  final TrajectoryApi? api;
  const TrajectoryScreen({super.key, required this.sessionId, this.api});

  /// Events decoded per page. The mirror is paged newest-first on open and
  /// older pages are loaded on request.
  static const pageSize = 200;

  @override
  State<TrajectoryScreen> createState() => _TrajectoryScreenState();
}

class _TrajectoryScreenState extends State<TrajectoryScreen> {
  late final TrajectoryApi _api;
  List<Map<String, dynamic>> _events = [];

  /// True while older events may exist (`before=<oldest seq>`).
  bool _hasEarlier = false;
  bool _loadingEarlier = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TrajectoryApi();
    _load();
  }

  /// Resolve the local session id to the server UUID the gateway routes on.
  Future<String> _serverSessionId() async {
    final store = CloudSessionStore.I;
    await store.ready;
    return store.serverIdFor(widget.sessionId) ?? widget.sessionId;
  }

  Future<Map<String, dynamic>> _fetch(Map<String, String> query) async {
    final serverId = await _serverSessionId();
    return CloudRestClient.I.getJson(
      '/sessions/$serverId/events',
      query: query,
    );
  }

  static List<Map<String, dynamic>> _decodeEvents(Map<String, dynamic> body) {
    final raw = body['events'];
    if (raw is! List) return const [];
    return [
      for (final event in raw)
        if (event is Map) Map<String, dynamic>.from(event),
    ];
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final body = await _fetch({
        'tail': '1',
        'limit': '${TrajectoryScreen.pageSize}',
      });
      final events = _decodeEvents(body);
      if (!mounted) return;
      setState(() {
        _events = events;
        _hasEarlier = events.length >= TrajectoryScreen.pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _errorMessage(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadEarlier() async {
    if (_loadingEarlier || !_hasEarlier || _events.isEmpty) return;
    final oldest = _events.first['seq'];
    if (oldest == null) return;
    setState(() => _loadingEarlier = true);
    try {
      final body = await _fetch({
        'before': '$oldest',
        'limit': '${TrajectoryScreen.pageSize}',
      });
      final earlier = _decodeEvents(body);
      if (!mounted) return;
      setState(() {
        _loadingEarlier = false;
        if (earlier.isEmpty) {
          _hasEarlier = false;
          return;
        }
        _events = [...earlier, ..._events];
        _hasEarlier = earlier.length >= TrajectoryScreen.pageSize;
      });
      if (earlier.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't load earlier events.")),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingEarlier = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorMessage(e))));
    }
  }

  /// A real, user-readable failure — a 404 (unknown/not-owned session), an
  /// offline transport error, or any other gateway envelope. Never an
  /// endless spinner.
  String _errorMessage(Object error) {
    if (error is CloudApiException) {
      if (error.status == 404) {
        return 'This session was not found on Ovid Cloud.';
      }
      return error.message;
    }
    return 'Could not reach Ovid Cloud. Check your connection and retry.';
  }

  String _typeOf(Map<String, dynamic> e) => e['type'] as String? ?? '';

  Map<String, dynamic> _payloadOf(Map<String, dynamic> e) {
    final payload = e['payload'];
    return payload is Map ? Map<String, dynamic>.from(payload) : const {};
  }

  void _showRaw() {
    showDialog<void>(
      context: context,
      builder: (_) => _TrajectoryRawDialog(
        load: (after) async =>
            _api.showRaw(await _serverSessionId(), after: after),
      ),
    );
  }

  IconData _iconFor(String type) => switch (type) {
    'run_started' => Icons.play_arrow_outlined,
    'run_started_retry' => Icons.refresh,
    'run_completed' => Icons.flag_outlined,
    'run_failed' => Icons.error_outline,
    'run_cancelled' => Icons.cancel_outlined,
    'tool_started' => Icons.build_outlined,
    'tool_completed' => Icons.check_circle_outline,
    'subagent_started' => Icons.hub_outlined,
    'subagent_completed' => Icons.check_circle_outline,
    'artifact_created' => Icons.save_outlined,
    'workspace_hibernated' => Icons.cloud_off_outlined,
    'workspace_hydrated' => Icons.cloud_done_outlined,
    'approval_requested' => Icons.verified_user_outlined,
    'approval_resolved' => Icons.verified_user,
    'todo_updated' => Icons.checklist_outlined,
    'goal_updated' => Icons.flag_outlined,
    'plan_mode_changed' => Icons.account_tree_outlined,
    'compaction_completed' => Icons.compress,
    'subagent_compacted' => Icons.compress,
    'system_note' => Icons.notes_outlined,
    'message_completed' => Icons.chat_bubble_outline,
    _ => Icons.circle_outlined,
  };

  bool _isFailed(Map<String, dynamic> e) {
    final type = _typeOf(e);
    if (type == 'run_failed' || type == 'run_cancelled') return true;
    if (type == 'tool_completed') {
      final p = _payloadOf(e);
      return p['isError'] == true || p['ok'] == false;
    }
    if (type == 'subagent_completed') {
      final p = _payloadOf(e);
      return p['ok'] == false || p['isError'] == true;
    }
    return false;
  }

  IconData _eventIcon(Map<String, dynamic> e) =>
      _isFailed(e) ? Icons.error_outline : _iconFor(_typeOf(e));

  /// Outcome-accurate label for terminal tool/subagent events, or null for
  /// event types that carry no outcome.
  String? _outcomeLabel(Map<String, dynamic> e) {
    final p = _payloadOf(e);
    final ok = !(p['isError'] == true || p['ok'] == false);
    return switch (_typeOf(e)) {
      'tool_completed' =>
        'Tool ${ok ? 'succeeded' : 'failed'}: ${p['name'] ?? '?'}',
      'subagent_completed' =>
        'Subagent ${ok ? 'succeeded' : 'failed'}: '
            '${p['agent'] ?? p['name'] ?? '?'}',
      _ => null,
    };
  }

  Color _colorFor(String type, {bool failed = false}) {
    if (failed) return Aether.danger;
    return switch (type) {
      'run_started' => Aether.accent,
      'run_completed' => Aether.success,
      'tool_started' => Aether.textMuted,
      'tool_completed' => Aether.textMuted,
      'subagent_completed' => Aether.textMuted,
      'artifact_created' => Aether.warn,
      'system_note' => Aether.danger,
      _ => Aether.textFaint,
    };
  }

  String _titleFor(Map<String, dynamic> e) {
    final p = _payloadOf(e);
    return switch (_typeOf(e)) {
      'run_started' => 'Run started',
      'run_started_retry' => 'Run retry (attempt ${p['attempt'] ?? '?'})',
      'run_completed' => 'Run completed',
      'run_failed' => 'Run failed',
      'run_cancelled' => 'Run cancelled',
      'message_delta' => 'Message delta',
      'message_completed' => 'Message completed',
      'system_note' => 'Note',
      'tool_started' => 'Tool: ${p['name'] ?? '?'}',
      'tool_completed' => 'Tool done: ${p['name'] ?? '?'}',
      'artifact_created' => 'Artifact created',
      'workspace_hibernated' => 'Workspace hibernated',
      'workspace_hydrated' => 'Workspace hydrated',
      'approval_requested' => 'Approval requested',
      'approval_resolved' => 'Approval resolved',
      'todo_updated' => 'Todo updated',
      'goal_updated' => 'Goal updated',
      'plan_mode_changed' => 'Plan mode changed',
      'subagent_started' =>
        'Subagent started: ${p['agent'] ?? p['name'] ?? '?'}',
      'subagent_completed' =>
        'Subagent done: ${p['agent'] ?? p['name'] ?? '?'}',
      'compaction_completed' => 'Compaction completed',
      'subagent_compacted' => 'Worker compacted: ${p['workerId'] ?? '—'}',
      final type => type.isEmpty ? 'Event' : type,
    };
  }

  String _detailFor(Map<String, dynamic> e) {
    final p = _payloadOf(e);
    final type = _typeOf(e);
    return switch (type) {
      'run_failed' || 'run_cancelled' =>
        '${p['code'] ?? 'failed'}'
            '${p['message'] != null ? ' · ${p['message']}' : ''}',
      'tool_completed' =>
        '${p['isError'] == true || p['ok'] == false ? 'failed' : 'ok'}'
            '${p['truncated'] == true ? ' · truncated' : ''}',
      'subagent_completed' =>
        '${p['ok'] == false ? 'failed' : 'ok'}'
            '${p['error'] != null ? ' · ${p['error']}' : ''}',
      'system_note' => '${p['message'] ?? p['code'] ?? ''}',
      'message_delta' => _preview(p['content'] ?? p['text']),
      'subagent_compacted' =>
        '${p['beforeTokens'] ?? '—'} → ${p['afterTokens'] ?? '—'} tokens · '
            '${p['model'] ?? '—'} · limit ${p['contextLimit'] ?? '—'} · '
            'checkpoint ${p['checkpointId'] ?? '—'} · '
            'compaction ${p['compactionId'] ?? '—'} · '
            '${p['continuation'] ?? '—'}',
      _ => '',
    };
  }

  static String _preview(Object? value) {
    final text = value?.toString() ?? '';
    if (text.length <= 160) return text;
    return '${text.substring(0, 160)}…';
  }

  String _accessibilityLabel(Map<String, dynamic> e) {
    final title = _titleFor(e);
    final detail = _detailFor(e);
    return detail.isEmpty ? title : '$title. ${detail.replaceAll(' · ', '. ')}';
  }

  Widget _eventsContent() {
    // Main compaction is diagnostics-only. Worker compaction remains visible
    // as operational metadata, never as private thoughts or an ordinary main
    // step. The full main diagnostic is available only through Show raw.
    final visibleEvents = <Map<String, dynamic>>[
      for (final event in _events)
        if (_typeOf(event) != 'compaction_completed') event,
    ];
    return CustomScrollView(
      slivers: [
        if (_error != null && visibleEvents.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: AetherEmptyState(
                icon: Icons.error_outline,
                title: 'Could not refresh events',
                message: _error,
                action: AetherSecondaryButton(label: 'Retry', onPressed: _load),
              ),
            ),
          ),
        if (visibleEvents.isEmpty)
          const SliverToBoxAdapter(
            child: AetherEmptyState(
              key: ValueKey('trajectory-empty'),
              icon: Icons.timeline_outlined,
              title: 'No events yet',
              message: 'Events appear here as the agent runs in this session.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
            sliver: SliverList.builder(
              itemCount: visibleEvents.length + (_hasEarlier ? 2 : 1),
              itemBuilder: (_, row) {
                if (row == 0) {
                  return const Padding(
                    padding: EdgeInsets.fromLTRB(2, 4, 2, 10),
                    child: AetherSectionTitle(
                      key: ValueKey('trajectory-events-title'),
                      eyebrow: 'Events',
                    ),
                  );
                }
                if (_hasEarlier && row == 1) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AetherSecondaryButton(
                      key: const ValueKey('trajectory-load-earlier'),
                      label: _loadingEarlier
                          ? 'Loading…'
                          : 'Load earlier events',
                      onPressed: _loadingEarlier ? null : _loadEarlier,
                    ),
                  );
                }
                final index = row - (_hasEarlier ? 2 : 1);
                final e = visibleEvents[index];
                final detail = _detailFor(e);
                final type = _typeOf(e);
                final color = _colorFor(type, failed: _isFailed(e));
                final outcome = _outcomeLabel(e);
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
                              Text(
                                '${e['ts'] ?? ''}',
                                style: AetherType.mono.copyWith(
                                  fontSize: 12,
                                  color: Aether.textFaint,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '#${e['seq'] ?? index + 1} · ${_titleFor(e)}',
                                style: AetherType.title.copyWith(fontSize: 13),
                              ),
                              if (outcome != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  outcome,
                                  style: AetherType.caption.copyWith(
                                    color: _isFailed(e)
                                        ? Aether.danger
                                        : Aether.success,
                                  ),
                                ),
                              ],
                              if (detail.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  detail,
                                  style: AetherType.bodyMuted.copyWith(
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              Semantics(
                                container: true,
                                label: _accessibilityLabel(e),
                                button: true,
                                child: TextButton(
                                  key: ValueKey(
                                    'trajectory-detail-${e['seq'] ?? index + 1}',
                                  ),
                                  onPressed: _showRaw,
                                  child: const Text('Show raw'),
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
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  Widget _body() {
    if (_loading && _events.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 1.6));
    }
    if (_error != null && _events.isEmpty) {
      return SingleChildScrollView(
        child: AetherEmptyState(
          icon: Icons.error_outline,
          title: 'Could not load events',
          message: _error,
          action: AetherSecondaryButton(label: 'Retry', onPressed: _load),
        ),
      );
    }
    return Stack(
      children: [
        _eventsContent(),
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
          TextButton(onPressed: _showRaw, child: const Text('Show raw')),
          IconButton(
            tooltip: 'Reload events',
            icon: const Icon(Icons.refresh, size: 19),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(),
    );
  }
}

class _TrajectoryRawDialog extends StatefulWidget {
  const _TrajectoryRawDialog({required this.load});

  final Future<RawTrajectoryPage> Function(String? after) load;

  @override
  State<_TrajectoryRawDialog> createState() => _TrajectoryRawDialogState();
}

class _TrajectoryRawDialogState extends State<_TrajectoryRawDialog> {
  final List<RawTrajectoryEntry> _entries = <RawTrajectoryEntry>[];
  String? _nextCursor;
  String? _error;
  bool _loading = false;
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  Future<void> _load(String? after) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.load(after);
      if (!mounted) return;
      setState(() {
        final ids = _entries.map((entry) => entry.dedupeKey).toSet();
        _entries.addAll(
          page.entries.where((entry) => ids.add(entry.dedupeKey)),
        );
        _nextCursor = page.nextCursor;
        _truncated = page.truncated;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'We could not load raw trajectory history.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = RawTrajectoryPage(
      entries: _entries,
      nextCursor: _nextCursor,
      truncated: _truncated,
    );
    return AlertDialog(
      title: const Text('Raw trajectory'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_entries.isEmpty && _loading)
                const Center(child: CircularProgressIndicator())
              else
                SelectableText(
                  page.displayText,
                  key: const ValueKey<String>('trajectory-raw-content'),
                  style: AetherType.mono,
                ),
              if (_truncated) const Text('Truncated by server'),
              if (_error != null) Text(_error!),
              if (_loading && _entries.isNotEmpty)
                const LinearProgressIndicator(minHeight: 2),
              if (_nextCursor != null)
                TextButton(
                  onPressed: _loading ? null : () => _load(_nextCursor),
                  child: const Text('Load more raw'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
