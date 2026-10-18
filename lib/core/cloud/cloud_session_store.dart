/// `CloudSessionStore` — session reconciliation, the offline READ CACHE and
/// the prompt outbox for the Ovid Cloud thin client (P8 Task 9).
///
/// Spec §12 keeps exactly three offline behaviours: a read-only cache of the
/// last transcript, a prompt queue flushed on reconnect, and the session
/// list. This store owns all three:
///
///  * **Reconciliation** — [refreshSessions] walks the gateway's keyset pages
///    and makes server UUIDv7 sessions first-class `ChatSession` rows in
///    [AppState.sessions]. A local session already mapped to a server id is
///    UPDATED in place (never duplicated); an unmapped local session stays
///    until its first send ([ensureServerSession]).
///  * **Read cache** — [loadTranscript] pages `GET /sessions/:id/messages`
///    (newest-first), reverses to the transcript order and writes the page
///    through [SessionHistoryRepository] (the demoted history store). The
///    cache row also records the replay cursor (the multiplexer's last
///    accepted seq) so a resumed client can seed the projector and subscribe
///    from the cache high-water mark (the T7 review carry).
///  * **Outbox** — [enqueue] persists prompts to `ovid_cloud_outbox` (FIFO,
///    JSON) so process death cannot lose a composed prompt; [flushOutbox]
///    sends them in order with their stored `clientMsgId` (Task 4
///    idempotency: a replay returns the ORIGINAL run and is removed without
///    a second optimistic row).
///
/// [CloudTranscriptSink] is the seam back into `CloudAgentFacade`: the store
/// never imports the facade (which imports this file), so the facade attaches
/// itself as the sink.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection_service.dart';
import '../session_history_store.dart';
import '../state.dart';
import 'cloud_rest.dart';
import 'cloud_ws.dart';
import 'models.dart';

/// Receives cache loads from [CloudSessionStore] so the live projection can
/// be seeded without the store importing `CloudAgentFacade`.
abstract class CloudTranscriptSink {
  /// Replaces the session transcript with [messages] (oldest-first) and
  /// seeds the projector cursor with [cursor] (the cache high-water mark).
  void seedTranscript(
    String serverSessionId,
    List<Message> messages,
    String? cursor,
  );

  /// Prepends an OLDER page to the transcript (keyset paging backwards).
  void prependTranscript(String serverSessionId, List<Message> messages);

  /// Records a user row after a successful send. Implementations MUST dedupe
  /// by `privateSyncId == userMessageId` so a clientMsgId replay never
  /// appends a second optimistic message.
  void appendSentUserMessage(
    String serverSessionId,
    String userMessageId,
    String content,
  );
}

/// One cached transcript row: messages oldest-first + the seq up to which
/// the cache is authoritative.
class _CachedTranscript {
  const _CachedTranscript({required this.messages, required this.cursor});

  final List<Message> messages;
  final String? cursor;
}

/// Session reconciliation + offline cache + prompt outbox (P8 Task 9).
class CloudSessionStore extends ChangeNotifier {
  CloudSessionStore({
    required CloudRestClient rest,
    required SessionHistoryRepository cache,
    SharedPreferences? prefs,
    ConnectionService? connection,
    WsMultiplexer? ws,
  })  : _rest = rest, // ignore: prefer_initializing_formals
        _cache = cache, // ignore: prefer_initializing_formals
        _prefs = prefs, // ignore: prefer_initializing_formals
        _connection = connection ?? ConnectionService.I,
        _ws = ws ?? WsMultiplexer.I {
    _ready = _load();
  }

  // -------------------------------------------------------------------------
  // Persistence keys / namespaces
  // -------------------------------------------------------------------------

  /// Local session id → server UUIDv7 id (JSON object), per the plan.
  static const String idMapKey = 'ovid_cloud_session_ids';

  /// FIFO prompt queue (JSON list of [OutboxEntry]), per the plan.
  static const String outboxKey = 'ovid_cloud_outbox';

  /// `SessionHistoryRepository` namespace holding the offline transcript
  /// cache. One row per server session (`id` = server id), so the repo's
  /// per-message index (and therefore search) works unchanged.
  static const String cacheNamespace = 'ovid_cloud_transcripts';

  /// Server ids this process has seen (from a create or a list page). Kept
  /// so an outbox entry that already names a SERVER id is never mistaken for
  /// a local id and re-created as a duplicate session on flush.
  static const String knownServerIdsKey = 'ovid_cloud_server_ids';

  final CloudRestClient _rest;
  final SessionHistoryRepository _cache;
  final ConnectionService _connection;
  final WsMultiplexer _ws;
  SharedPreferences? _prefs;

  late final Future<void> _ready;

  /// True once [_load] has populated the in-memory maps (always true for the
  /// test constructor). Lets async callers skip awaiting a future that may
  /// have been created outside the current (widget-test) zone.
  bool _loaded = false;

  final Map<String, String> _idMap = <String, String>{};
  final Set<String> _knownServerIds = <String>{};
  final List<OutboxEntry> _outbox = <OutboxEntry>[];

  /// In-memory view of the cache, populated by [loadTranscript] / reads.
  /// Sync getters ([cachedTranscriptFor], [cachedCursorFor]) serve the
  /// facade's pre-subscribe seeding from here.
  final Map<String, _CachedTranscript> _cacheMemory =
      <String, _CachedTranscript>{};

  /// Concurrent [ensureServerSession] calls share one POST.
  final Map<String, Future<String>> _creating = <String, Future<String>>{};

  Future<void>? _flushFuture;
  ({String code, String message})? _outboxError;

  CloudTranscriptSink? _transcriptSink;

  static CloudSessionStore? _instance;

  /// The process-wide default (Task 10 wires the facade with it).
  static CloudSessionStore get I => _instance ??= CloudSessionStore(
        rest: CloudRestClient.I,
        cache: SessionHistoryRepository.I,
        connection: ConnectionService.I,
      );

  /// Replaces the singleton — test wiring only.
  @visibleForTesting
  static void installForTest(CloudSessionStore store) => _instance = store;

  /// Clears the singleton — test wiring only.
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// A store seeded with an in-memory local→server map, for tests.
  ///
  /// Unlike the production constructor this never touches SharedPreferences
  /// or the network: [ready] is already complete, so the async resolver can be
  /// exercised without mocking platform channels.
  @visibleForTesting
  CloudSessionStore.forTest({
    Map<String, String> idMap = const <String, String>{},
    CloudRestClient? rest,
    SessionHistoryRepository? cache,
    ConnectionService? connection,
    WsMultiplexer? ws,
  })  : _rest = rest ?? CloudRestClient(),
        _cache = cache ?? SessionHistoryRepository.I,
        _prefs = null,
        _connection = connection ?? ConnectionService.I,
        _ws = ws ?? WsMultiplexer.I {
    _idMap.addAll(idMap);
    _knownServerIds.addAll(idMap.values);
    _loaded = true;
    _ready = Future<void>.value();
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> _load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final prefs = _prefs!;
    _decodeIdMap(prefs.getString(idMapKey));
    // Every mapped server id is a server id by definition (protects an
    // outbox flush from re-creating one after a restart).
    _knownServerIds.addAll(_idMap.values);
    _decodeKnownServerIds(prefs.getString(knownServerIdsKey));
    _decodeOutbox(prefs.getString(outboxKey));
    _loaded = true;
  }

  /// Completes once the persisted map/outbox are in memory. Every async API
  /// awaits it; the sync getters serve whatever has loaded.
  Future<void> get ready => _ready;

  /// The sink the facade attaches itself to (see [CloudTranscriptSink]).
  set transcriptSink(CloudTranscriptSink? sink) => _transcriptSink = sink;

  /// The connection whose offline flag contributes to [offline] (the facade
  /// listens to it for the reconnect flush).
  ConnectionService get connection => _connection;

  /// The multiplexer whose [WsLinkState] contributes to [offline].
  WsMultiplexer get ws => _ws;

  @override
  void dispose() {
    _transcriptSink = null;
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Reconciliation
  // -------------------------------------------------------------------------

  /// The server session id for a local id (null when unmapped).
  String? serverIdFor(String localSessionId) => _idMap[localSessionId];

  /// The id to put on the wire for [id]: the mapped server UUID when one
  /// exists, otherwise [id] unchanged.
  ///
  /// `ChatSession.id` is LOCAL (`DateTime.now().microsecondsSinceEpoch`), and
  /// the server routes require a UUID. Feature clients that build a path or a
  /// WS frame from a session id must resolve it here at the REST/WS boundary;
  /// UI state keys stay local. Unmapped ids (already-server rows, or a chat
  /// that has not had its first send yet) pass through untouched.
  ///
  /// This is the synchronous form: it sees whatever [ready] has loaded so far.
  /// Async callers must use [resolveServerSessionIdAsync] so the persisted map
  /// is in memory first.
  String resolveServerSessionId(String id) => serverIdFor(id) ?? id;

  /// [resolveServerSessionId] after [ready], for async call sites.
  Future<String> resolveServerSessionIdAsync(String id) async {
    if (!_loaded) await _ready;
    return resolveServerSessionId(id);
  }

  /// Creates the server session on first send; idempotent across calls,
  /// concurrent callers and process restarts (the map is persisted).
  Future<String> ensureServerSession(
    String localSessionId, {
    String? title,
  }) async {
    await _ready;
    final mapped = _idMap[localSessionId];
    if (mapped != null) return mapped;
    // An id we already know to be a SERVER id must never be created again
    // (the outbox can carry a server id when the user was on a synced chat).
    if (_knownServerIds.contains(localSessionId)) return localSessionId;

    final pending = _creating[localSessionId];
    if (pending != null) return pending;

    final future = _createServerSession(localSessionId, title);
    _creating[localSessionId] = future;
    try {
      return await future;
    } finally {
      _creating.remove(localSessionId);
    }
  }

  Future<String> _createServerSession(String localId, String? title) async {
    final session = AppState.I.sessionById(localId);
    final dto = await _rest.createSession(
      title: (title != null && title.trim().isNotEmpty)
          ? title
          : session?.title,
    );
    _idMap[localId] = dto.id;
    _knownServerIds.add(dto.id);
    await _persistIds();
    notifyListeners();
    return dto.id;
  }

  /// Walks `GET /sessions` keyset pages and reconciles [AppState.sessions].
  ///
  /// Server sessions become `ChatSession` rows keyed by their server id.
  /// A server session already mapped from a local id updates THAT local row
  /// (the map is preserved; no duplicate appears). Local sessions without a
  /// server id stay untouched until their first send.
  Future<void> refreshSessions() async {
    await _ready;
    final localByServer = <String, String>{
      for (final entry in _idMap.entries) entry.value: entry.key,
    };
    final seen = <String>{};
    String? cursor;
    var pages = 0;
    while (true) {
      final page = await _rest.listSessions(limit: 50, cursor: cursor);
      for (final dto in page.items) {
        if (!seen.add(dto.id)) continue;
        _knownServerIds.add(dto.id);
        final localId = localByServer[dto.id];
        if (localId != null) {
          final local = AppState.I.sessionById(localId);
          if (local != null) _applyDto(local, dto);
          continue;
        }
        final existing = AppState.I.sessionById(dto.id);
        if (existing != null) {
          _applyDto(existing, dto);
        } else {
          AppState.I.sessions.add(_sessionFromDto(dto));
        }
      }
      cursor = page.nextCursor;
      // Defensive bound: a broken server cursor must never spin forever.
      if (cursor == null || cursor.isEmpty || ++pages >= 100) break;
    }
    await _persistIds();
    AppState.I.notifyListeners();
    notifyListeners();
  }

  ChatSession _sessionFromDto(SessionDto dto) => ChatSession(
        id: dto.id,
        title: (dto.title == null || dto.title!.isEmpty)
            ? 'New chat'
            : dto.title!,
        // Cloud runs choose their model server-side; keep a sane local value
        // for the kept UI (the provider picker is hidden on the thin client).
        model: AppState.I.lastSelectedModel.isNotEmpty
            ? AppState.I.lastSelectedModel
            : 'Select a provider',
        mode: dto.mode,
        createdAt: dto.createdAt,
        updatedAt: dto.updatedAt,
      );

  void _applyDto(ChatSession session, SessionDto dto) {
    final title = dto.title;
    if (title != null && title.isNotEmpty) session.title = title;
    session.mode = dto.mode;
    session.updatedAt = dto.updatedAt;
  }

  // -------------------------------------------------------------------------
  // Offline transcript cache
  // -------------------------------------------------------------------------

  /// The cached transcript for [serverSessionId], oldest-first (null until a
  /// load/paging call has populated it in this process).
  List<Message>? cachedTranscriptFor(String serverSessionId) {
    final entry = _cacheMemory[serverSessionId];
    return entry == null ? null : List<Message>.unmodifiable(entry.messages);
  }

  /// The cache high-water mark (the replay cursor recorded with the page).
  String? cachedCursorFor(String serverSessionId) =>
      _cacheMemory[serverSessionId]?.cursor;

  /// Writes [messages] into the offline READ cache for [serverSessionId]
  /// (P8 Task 10 — the terminal-event cache write). Live deltas are not
  /// persisted per-delta; the facade calls this when a run terminalizes so a
  /// cold offline start still shows the latest turn. The [cursor] stays the
  /// cache's recorded high-water mark (the multiplexer owns the live replay
  /// cursor separately) and the messageId replay guard keeps a re-subscribe
  /// exactly-once.
  Future<void> persistTranscript(
    String serverSessionId,
    List<Message> messages,
    String? cursor,
  ) async {
    await _ready;
    final entry = _CachedTranscript(
      messages: _dedupe(messages),
      cursor: cursor,
    );
    _cacheMemory[serverSessionId] = entry;
    await _writeCache(serverSessionId, entry);
  }

  /// Pages the session transcript (newest-first wire → oldest-first model),
  /// writes the offline cache and seeds the projection.
  ///
  /// `before == null` loads the NEWEST page and records the replay cursor as
  /// the cache high-water mark. A non-null [before] loads an OLDER page and
  /// prepends it (the cursor and newer rows are untouched).
  Future<void> loadTranscript(
    String serverSessionId, {
    String? before,
    int limit = 50,
  }) async {
    await _ready;

    // The cursor is read BEFORE the page request: everything at or below it
    // is reflected by the REST snapshot, so the replay can safely resume
    // after it (any event committed during the request has a higher seq and
    // is replayed; the projector's messageId guard makes that idempotent).
    final cursor = before == null ? await _ws.cursorFor(serverSessionId) : null;

    if (before == null && offline) {
      await _seedFromCache(serverSessionId);
      return;
    }

    CloudPage<MessageDto> page;
    try {
      page = await _rest.pageMessages(
        serverSessionId,
        limit: limit,
        before: before,
      );
    } catch (_) {
      // A network failure on the newest page still opens the read cache.
      if (before == null) await _seedFromCache(serverSessionId);
      rethrow;
    }

    final fetched = <Message>[
      // The wire is newest-first; the transcript is oldest-first.
      for (final dto in page.items.reversed) _messageFromDto(dto),
    ];

    if (before == null) {
      final messages = _dedupe(fetched);
      final entry = _CachedTranscript(messages: messages, cursor: cursor);
      await _writeCache(serverSessionId, entry);
      _cacheMemory[serverSessionId] = entry;
      _transcriptSink?.seedTranscript(serverSessionId, messages, cursor);
      notifyListeners();
      return;
    }

    final older = _dedupe(fetched);
    final existing =
        await _readCache(serverSessionId) ?? _cacheMemory[serverSessionId];
    final merged = _dedupe(<Message>[
      ...older,
      ...?existing?.messages,
    ]);
    final entry = _CachedTranscript(
      messages: merged,
      cursor: existing?.cursor,
    );
    await _writeCache(serverSessionId, entry);
    _cacheMemory[serverSessionId] = entry;
    _transcriptSink?.prependTranscript(serverSessionId, older);
    notifyListeners();
  }

  Future<void> _seedFromCache(String serverSessionId) async {
    final cached = await _readCache(serverSessionId);
    if (cached == null) return;
    _cacheMemory[serverSessionId] = cached;
    _transcriptSink?.seedTranscript(
      serverSessionId,
      cached.messages,
      cached.cursor,
    );
    notifyListeners();
  }

  Message _messageFromDto(MessageDto dto) => Message(
        role: dto.role,
        kind: MsgKind.text,
        content: dto.content,
        // The server message id is the stable identity used for paging and
        // replay dedupe (Task 4's userMessageId equals it).
        privateSyncId: dto.id,
        time: dto.createdAt,
      );

  static List<Message> _dedupe(List<Message> messages) {
    final seen = <String>{};
    return <Message>[
      for (final message in messages)
        if (seen.add(message.privateSyncId)) message,
    ];
  }

  Future<_CachedTranscript?> _readCache(String serverSessionId) async {
    final prefs = _prefs;
    if (prefs == null) return null;
    final rows =
        await _cache.readRows(prefs, cacheNamespace) ?? const <String>[];
    for (final raw in rows) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic> ||
            decoded['id'] != serverSessionId) {
          continue;
        }
        final messages = <Message>[
          for (final m in (decoded['messages'] as List? ?? const <dynamic>[]))
            if (m is Map<String, dynamic>) Message.fromJson(m),
        ];
        return _CachedTranscript(
          messages: messages,
          cursor: decoded['cursor'] as String?,
        );
      } catch (_) {
        // Opaque/corrupt cache row: skip it, never fail the load.
      }
    }
    return null;
  }

  Future<void> _writeCache(
    String serverSessionId,
    _CachedTranscript entry,
  ) async {
    final prefs = _prefs;
    if (prefs == null) return;
    // Read first: SessionHistoryRepository refuses to overwrite a SQLite
    // namespace it has not seen this process.
    final rows =
        await _cache.readRows(prefs, cacheNamespace) ?? const <String>[];
    final out = <String>[];
    var replaced = false;
    for (final raw in rows) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic> &&
            decoded['id'] == serverSessionId) {
          if (!replaced) {
            out.add(jsonEncode(_cacheRow(serverSessionId, entry)));
            replaced = true;
          }
          continue;
        }
      } catch (_) {
        // Keep opaque rows byte-for-byte.
      }
      out.add(raw);
    }
    if (!replaced) out.add(jsonEncode(_cacheRow(serverSessionId, entry)));
    await _cache.writeRows(prefs, cacheNamespace, out);
  }

  Map<String, dynamic> _cacheRow(
    String serverSessionId,
    _CachedTranscript entry,
  ) {
    final session = AppState.I.sessionById(serverSessionId);
    final now = DateTime.now().toUtc().toIso8601String();
    return <String, dynamic>{
      'id': serverSessionId,
      if (session?.title != null) 'title': session!.title,
      if (session?.model != null) 'model': session!.model,
      'createdAt':
          (session?.createdAt ?? DateTime.now()).toUtc().toIso8601String(),
      'updatedAt':
          (session?.updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'cursor': entry.cursor,
      'messages': <Map<String, dynamic>>[
        for (final message in entry.messages) message.toJson(),
      ],
      'cachedAt': now,
    };
  }

  // -------------------------------------------------------------------------
  // Offline flag
  // -------------------------------------------------------------------------

  /// True when the prompt must be queued instead of sent: the connectivity
  /// probe says offline, or the multiplexed socket is not online.
  bool get offline =>
      _connection.offline || _ws.linkState != WsLinkState.online;

  // -------------------------------------------------------------------------
  // Prompt outbox
  // -------------------------------------------------------------------------

  /// Queued prompts for [sessionId] in FIFO order (the composer queue chip).
  /// Accepts a local id or its mapped server id.
  List<OutboxEntry> outboxFor(String sessionId) {
    final target = serverIdFor(sessionId) ?? sessionId;
    return List<OutboxEntry>.unmodifiable(
      _outbox.where(
        (entry) =>
            entry.sessionId == target || entry.sessionId == sessionId,
      ),
    );
  }

  /// Every queued prompt, FIFO. The facade uses this to upload staged files
  /// before the reconnect flush.
  List<OutboxEntry> get outboxEntries => List<OutboxEntry>.unmodifiable(_outbox);

  /// The last flush failure (surfaced by Task 10), or null.
  ({String code, String message})? get outboxError => _outboxError;

  /// Dismisses the last flush failure without touching the queue. A later
  /// flush failure records a fresh one.
  void clearOutboxError() {
    if (_outboxError == null) return;
    _outboxError = null;
    notifyListeners();
  }

  /// Queues [content] durably. The entry gets a fresh 32-hex `clientMsgId`
  /// (Task 4 idempotency) and is persisted before this future completes, so
  /// a process kill cannot lose it.
  Future<void> enqueue(
    String sessionId,
    String content, {
    List<String> attachmentIds = const <String>[],
  }) async {
    await _ready;
    final target = serverIdFor(sessionId) ?? sessionId;
    _outbox.add(OutboxEntry(
      clientMsgId: _newClientMsgId(),
      sessionId: target,
      content: content,
      attachmentIds: attachmentIds,
      createdAt: DateTime.now(),
    ));
    await _persistOutbox();
    notifyListeners();
  }

  /// Records the ids of files uploaded for an already-queued prompt (the
  /// facade's offline-attachment path, before [flushOutbox]).
  Future<void> setAttachmentIds(
    String clientMsgId,
    List<String> attachmentIds,
  ) async {
    await _ready;
    final index =
        _outbox.indexWhere((entry) => entry.clientMsgId == clientMsgId);
    if (index < 0) return;
    _outbox[index] = _outbox[index].copyWith(attachmentIds: attachmentIds);
    await _persistOutbox();
    notifyListeners();
  }

  /// Sends the outbox in FIFO order.
  ///
  /// * success (including a Task 4 `clientMsgId` replay) → remove, continue;
  /// * 402 `daily_limit_reached` → keep the remainder, surface, stop (retry
  ///   after the allowance resets / the next connectivity flip);
  /// * 409 `run_conflict` → the prompt was already accepted → remove;
  /// * any other 4xx → remove + surface (the entry can never succeed);
  /// * 5xx / network → stop, keep the remainder, retry on the next flip.
  Future<void> flushOutbox() async {
    await _ready;
    final pending = _flushFuture;
    if (pending != null) return pending;
    final future = _flushOutbox();
    _flushFuture = future;
    try {
      await future;
    } finally {
      if (identical(_flushFuture, future)) _flushFuture = null;
    }
  }

  Future<void> _flushOutbox() async {
    if (offline) return;
    for (final entry in List<OutboxEntry>.of(_outbox)) {
      if (!_outbox.contains(entry)) continue;
      String serverId;
      try {
        serverId = await ensureServerSession(entry.sessionId);
      } catch (e) {
        _outboxError = (
          code: e is CloudApiException ? e.code : 'network',
          message: e is CloudApiException ? e.message : '$e',
        );
        notifyListeners();
        return; // keep the prompt; retry later
      }
      try {
        final response = await _rest.sendMessage(
          serverId,
          entry.content,
          attachmentIds: entry.attachmentIds,
          clientMsgId: entry.clientMsgId,
        );
        _transcriptSink?.appendSentUserMessage(
          serverId,
          response.userMessageId,
          entry.content,
        );
        _outbox.remove(entry);
        await _persistOutbox();
        notifyListeners();
      } on CloudApiException catch (e) {
        if (e.status >= 500 || e.status == 402) {
          // Transient / allowance: keep the entry and everything behind it.
          _outboxError = (code: e.code, message: e.message);
          notifyListeners();
          return;
        }
        if (e.status == 409 && e.code == 'run_conflict') {
          // Already accepted (Task 4 idempotency): the entry is done.
          _outbox.remove(entry);
          await _persistOutbox();
          notifyListeners();
          continue;
        }
        // Other 4xx: this prompt can never succeed — drop it, surface why.
        _outboxError = (code: e.code, message: e.message);
        _outbox.remove(entry);
        await _persistOutbox();
        notifyListeners();
      } catch (e) {
        _outboxError = (code: 'network', message: '$e');
        notifyListeners();
        return; // keep the remainder
      }
    }
    // A fully-drained queue clears the stale error (Task 10's chip).
    if (_outbox.isEmpty && _outboxError != null) {
      _outboxError = null;
      notifyListeners();
    }
  }

  static String _newClientMsgId() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  // -------------------------------------------------------------------------
  // Persistence plumbing
  // -------------------------------------------------------------------------

  void _decodeIdMap(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final local = entry.key;
          final server = entry.value;
          if (local is String && server is String && server.isNotEmpty) {
            _idMap[local] = server;
          }
        }
      }
    } catch (_) {
      // Corrupt map: start empty; the server list reconciles it again.
    }
  }

  void _decodeKnownServerIds(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _knownServerIds.addAll(decoded.whereType<String>());
      }
    } catch (_) {
      // Corrupt list: harmless (a flush may re-create an unmapped id).
    }
  }

  void _decodeOutbox(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final entry = OutboxEntry.fromJson(item);
            if (entry.clientMsgId.isNotEmpty && entry.sessionId.isNotEmpty) {
              _outbox.add(entry);
            }
          } else if (item is Map) {
            final entry =
                OutboxEntry.fromJson(Map<String, dynamic>.from(item));
            if (entry.clientMsgId.isNotEmpty && entry.sessionId.isNotEmpty) {
              _outbox.add(entry);
            }
          }
        }
      }
    } catch (_) {
      // Corrupt queue: an empty outbox is safer than a crash loop.
    }
  }

  Future<void> _persistIds() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(idMapKey, jsonEncode(_idMap));
    await prefs.setString(
        knownServerIdsKey, jsonEncode(_knownServerIds.toList()));
  }

  Future<void> _persistOutbox() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      outboxKey,
      jsonEncode(<Map<String, dynamic>>[
        for (final entry in _outbox) entry.toJson(),
      ]),
    );
  }
}
