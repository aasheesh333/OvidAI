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
///  * **Outbox** — [enqueue] persists prompts to the account-scoped
///    `ovid_cloud_outbox` key (FIFO, JSON) so process death cannot lose a
///    composed prompt; [flushOutbox] sends them in order with their stored
///    `clientMsgId` (Task 4 idempotency: a replay returns the ORIGINAL run
///    and is removed without a second optimistic row). Entries are stamped
///    with the enqueuing account and only ever delivered to it (P0 privacy:
///    account A's prompts never reach account B, even on a shared device).
///
/// [CloudTranscriptSink] is the seam back into `CloudAgentFacade`: the store
/// never imports the facade (which imports this file), so the facade attaches
/// itself as the sink.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection_service.dart';
import '../session_history_store.dart';
import '../state.dart';
import 'cloud_errors.dart';
import 'cloud_rest.dart';
import 'cloud_ws.dart';
import 'event_projection.dart';
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

  /// Wave 1b (CH-002/CH-003/CH-006): rebuilds the session transcript from a
  /// rich history page — [rows] (oldest-first) interleaved with the page's
  /// settled [events] — and resumes the live stream strictly after
  /// [watermark] (the page's lastEventSeq), never replaying the event log on
  /// top of the snapshot. [activeRunId] is the run the server still has in
  /// flight (null = none).
  void seedRichTranscript(
    String serverSessionId, {
    required List<Message> rows,
    required List<CloudSessionEvent> events,
    required String? watermark,
    required String? activeRunId,
  });

  /// A queued prompt was ACCEPTED by the server (202, including a Task 4
  /// clientMsgId replay). Implementations swap the optimistic pending row
  /// for the confirmed one and MUST dedupe by
  /// `privateSyncId == response.userMessageId`, so a replay never appends a
  /// second user row.
  void outboxDelivered(
    String serverSessionId,
    OutboxEntry entry,
    SendMessageResponse response,
  );

  /// A local session just got its server id (create-on-first-send). Every
  /// per-session surface keyed by the local id (staged files, queue,
  /// optimistic rows, mode) must move to the server id — CH-033.
  void sessionMapped(String localSessionId, String serverSessionId);
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
    this.autoRetry = true,
  })  : _rest = rest, // ignore: prefer_initializing_formals
        _cache = cache, // ignore: prefer_initializing_formals
        _prefs = prefs, // ignore: prefer_initializing_formals
        _connection = connection ?? ConnectionService.I,
        _ws = ws ?? WsMultiplexer.I {
    _ready = _load();
  }

  /// When true (production), a transient delivery failure (network,
  /// timeout, 429, 5xx) schedules its own retry with exponential backoff, so
  /// a prompt never waits for a connectivity flip that may never come
  /// (CH-009). Tests that drive the flush by hand turn it off.
  final bool autoRetry;

  // -------------------------------------------------------------------------
  // Persistence keys / namespaces
  // -------------------------------------------------------------------------

  /// Local session id → server UUIDv7 id (JSON object), per the plan.
  static const String idMapKey = 'ovid_cloud_session_ids';

  /// FIFO prompt queue (JSON list of [OutboxEntry]), per the plan. New
  /// writes go through `AppState.accountScopedPrefKey` so each account owns
  /// its queue on disk; this plain form is the GUEST key and the legacy
  /// pre-scoping key, read once for migration at [_load].
  static const String outboxKey = 'ovid_cloud_outbox';

  /// `SessionHistoryRepository` namespace holding the offline transcript
  /// cache. One row per server session (`id` = server id), so the repo's
  /// per-message index (and therefore search) works unchanged.
  static const String cacheNamespace = 'ovid_cloud_transcripts';

  /// Server ids this process has seen (from a create or a list page). Kept
  /// so an outbox entry that already names a SERVER id is never mistaken for
  /// a local id and re-created as a duplicate session on flush.
  static const String knownServerIdsKey = 'ovid_cloud_server_ids';

  /// Server ids deleted locally whose DELETE has not been confirmed by the
  /// server yet (2xx or 404). [refreshSessions] hides these rows — an
  /// offline delete must not resurrect on the next refresh — and retries
  /// their DELETE; a confirmed delete clears the tombstone.
  static const String tombstonesKey = 'ovid_cloud_deleted_server_ids';

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
  final Set<String> _deletedServerIds = <String>{};
  final List<OutboxEntry> _outbox = <OutboxEntry>[];

  /// Every outbox prefs key this process has read or written (scoped and
  /// legacy forms), so a drained owner's key can be removed instead of
  /// resurrecting stale rows on the next load.
  final Set<String> _outboxKeys = <String>{};

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
    this.autoRetry = false,
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
    _decodeTombstones(prefs.getString(tombstonesKey));
    await _loadOutbox(prefs);
    _loaded = true;
  }

  /// Loads this account's queue, then migrates any pre-scoping rows off the
  /// legacy plain key (P0 privacy).
  ///
  /// The store is only constructed once Firebase reports the signed-in
  /// account (main.dart's `_warmCloud`), so the account-scoped read below
  /// happens with the real owner already current. Rows the old build wrote
  /// under the plain key carry no `account` stamp — single-device reality:
  /// they were enqueued by whoever was signed in — so the CURRENT account
  /// adopts them and the legacy key is retired in the same pass.
  Future<void> _loadOutbox(SharedPreferences prefs) async {
    final account = AppState.I.sessionAccountId;
    final scopedKey = AppState.I.accountScopedPrefKey(outboxKey);
    // Guest's scoped key IS the plain key; reading both would duplicate rows.
    final legacyRaw =
        scopedKey == outboxKey ? null : prefs.getString(outboxKey);
    final hasLegacy = legacyRaw != null && legacyRaw.isNotEmpty;

    _outboxKeys.add(scopedKey);
    _decodeOutbox(prefs.getString(scopedKey));
    if (hasLegacy) _decodeOutbox(legacyRaw);

    var unstamped = false;
    for (var i = 0; i < _outbox.length; i++) {
      if (_outbox[i].account == null) {
        _outbox[i] = _outbox[i].copyWith(account: account);
        unstamped = true;
      }
    }
    if (unstamped || hasLegacy) {
      await _persistOutbox();
      if (hasLegacy) await prefs.remove(outboxKey);
    }
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
    _retryTimer?.cancel();
    _retryTimer = null;
    _transcriptSink = null;
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Reconciliation
  // -------------------------------------------------------------------------

  /// The server session id for a local id (null when unmapped).
  String? serverIdFor(String localSessionId) => _idMap[localSessionId];

  /// The LOCAL row id for a server id (FE-011): a chat created on this device
  /// keeps its local id after the first send, so a push / link carrying the
  /// server UUID must be mapped back. Null when [serverId] is not mapped
  /// (server-native rows are keyed by their server id already).
  String? localIdFor(String serverId) {
    for (final entry in _idMap.entries) {
      if (entry.value == serverId) return entry.key;
    }
    return null;
  }

  /// The AppState row id for a session id that may be local or server.
  String resolveLocalSessionId(String id) => localIdFor(id) ?? id;

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

  /// The server id to address [id] on the wire when the server OWNS the
  /// session: the mapped server UUID for a local id, or [id] itself when it
  /// is a server-native row this process has seen. Null for a purely local
  /// id (never sent, never synced) — unlike [resolveServerSessionId] an
  /// unknown id is never passed through, so a caller can skip the request.
  ///
  /// This is the synchronous form: it sees whatever [ready] has loaded so far.
  String? knownServerIdFor(String id) {
    final mapped = _idMap[id];
    if (mapped != null) return mapped;
    return _knownServerIds.contains(id) ? id : null;
  }

  /// Creates the server session on first send; idempotent across calls,
  /// concurrent callers and process restarts (the map is persisted).
  Future<String> ensureServerSession(
    String localSessionId, {
    String? title,
  }) async {
    if (!_loaded) await _ready;
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
    // CH-013: the placeholder "New chat" is never sent as a real title —
    // the server would echo it back and overwrite the auto-title later.
    final candidate = (title != null && title.trim().isNotEmpty)
        ? title
        : session?.title;
    final dto = await _rest.createSession(
      title: isPlaceholderTitle(candidate) ? null : candidate,
    );
    _idMap[localId] = dto.id;
    _knownServerIds.add(dto.id);
    await _persistIds();
    // Outbox rows composed under the local id now belong to the server id.
    var moved = false;
    for (var i = 0; i < _outbox.length; i++) {
      if (_outbox[i].sessionId == localId) {
        _outbox[i] = _outbox[i].copyWith(sessionId: dto.id);
        moved = true;
      }
    }
    if (moved) await _persistOutbox();
    _transcriptSink?.sessionMapped(localId, dto.id);
    notifyListeners();
    return dto.id;
  }

  /// True for an empty title or the "New chat" placeholder (CH-013).
  static bool isPlaceholderTitle(String? title) {
    final t = title?.trim() ?? '';
    return t.isEmpty || t == 'New chat';
  }

  // -------------------------------------------------------------------------
  // Session delete (tombstones)
  // -------------------------------------------------------------------------

  /// True when [serverId] was deleted locally and the server has not
  /// confirmed the delete yet — [refreshSessions] hides such rows.
  bool isTombstoned(String serverId) => _deletedServerIds.contains(serverId);

  /// Server half of a chat delete ([AppState.deleteSession]): DELETEs the
  /// mapped server session and keeps a local TOMBSTONE so an offline delete
  /// cannot be resurrected by the next [refreshSessions].
  ///
  /// * [localOrServerId] resolves via [knownServerIdFor] — a mapped local id
  ///   OR a server-native row. A purely local chat (never sent, never
  ///   synced) has no server copy: the call is a no-op.
  /// * The tombstone is written BEFORE the DELETE fires and cleared ONLY
  ///   when the server confirms the row is gone (2xx, or 404 = already
  ///   deleted). Any other failure keeps it; [refreshSessions] retries the
  ///   DELETE until it confirms.
  /// * The id map entry is dropped either way, so a locally re-created chat
  ///   with the same id gets a fresh server session on its next send.
  Future<void> deleteServerSession(String localOrServerId) async {
    if (!_loaded) await _ready;
    final serverId = knownServerIdFor(localOrServerId);
    if (serverId == null) return; // never synced: nothing lives on the server
    _deletedServerIds.add(serverId);
    _idMap.removeWhere((_, server) => server == serverId);
    _knownServerIds.remove(serverId);
    await _persistIds();
    await _deleteOnServer(serverId);
    await _persistIds();
    notifyListeners();
  }

  /// Fires the DELETE for [serverId] and clears the tombstone when the
  /// server confirms the row is gone (2xx, or 404). Any other failure keeps
  /// it — the next [refreshSessions] retries. Never throws: a delete that
  /// cannot reach the server is exactly the offline case the tombstone
  /// exists for.
  Future<void> _deleteOnServer(String serverId) async {
    try {
      await _rest.deleteSession(serverId);
      _deletedServerIds.remove(serverId);
    } on CloudApiException catch (e) {
      if (e.status == 404) {
        // Already gone server-side: the tombstone's work is done.
        _deletedServerIds.remove(serverId);
      }
      // Any other 4xx/5xx keeps the tombstone for the next refresh retry.
    } catch (_) {
      // Network failure: keep the tombstone; refreshSessions retries.
    }
  }

  /// Walks `GET /sessions` keyset pages and reconciles [AppState.sessions].
  ///
  /// Server sessions become `ChatSession` rows keyed by their server id.
  /// A server session already mapped from a local id updates THAT local row
  /// (the map is preserved; no duplicate appears). Local sessions without a
  /// server id stay untouched until their first send.
  ///
  /// Concurrent callers share one walk. [syncing], [hasSynced] and
  /// [lastSyncError] describe it for the sidebar (SH-017): loading vs empty
  /// vs failed are different states, not one "No sessions yet".
  Future<void> refreshSessions() {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    _syncing = true;
    notifyListeners();
    late final Future<void> walk;
    walk = _refreshSessions().then(
      (_) {
        _hasSynced = true;
        _lastSyncError = null;
      },
      onError: (Object e, StackTrace st) {
        _lastSyncError = e;
        Error.throwWithStackTrace(e, st);
      },
    ).whenComplete(() {
      if (identical(_refreshing, walk)) _refreshing = null;
      _syncing = false;
      notifyListeners();
    });
    return _refreshing = walk;
  }

  Future<void>? _refreshing;
  bool _syncing = false;
  bool _hasSynced = false;
  Object? _lastSyncError;

  /// A session-list walk is in flight.
  bool get syncing => _syncing;

  /// At least one walk completed in this process (for this account).
  bool get hasSynced => _hasSynced;

  /// The last walk's failure, cleared by the next success.
  Object? get lastSyncError => _lastSyncError;

  /// Account change: the next account has not synced yet, and the previous
  /// account's in-memory transcript cache must not be served to it (a shared
  /// device: account B opening a link that carries account A's session id
  /// would otherwise seed A's cached messages before the server answers).
  /// Only the RAM view is dropped; the on-disk rows stay.
  void resetSyncState() {
    _hasSynced = false;
    _lastSyncError = null;
    _cacheMemory.clear();
    notifyListeners();
  }

  Future<void> _refreshSessions() async {
    if (!_loaded) await _ready;
    // Tombstone retry: deletes that never reached the server (an offline
    // delete, a failed DELETE) are re-fired here; the tombstone clears only
    // when the server confirms the row is gone. Runs before the page walk so
    // a just-confirmed delete cannot re-add the row below.
    for (final serverId in List<String>.of(_deletedServerIds)) {
      await _deleteOnServer(serverId);
    }
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
        // A tombstoned row the DELETE has not killed yet must not
        // resurrect locally (the offline-delete contract).
        if (_deletedServerIds.contains(dto.id)) continue;
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

  /// Wave 1b (branch): makes a session the server just created (e.g. a
  /// branch) a first-class local chat at once, without a full refresh.
  /// Returns its id (the server id — server sessions are keyed by it).
  Future<String> adoptServerSession(SessionDto dto) async {
    if (!_loaded) await _ready;
    _knownServerIds.add(dto.id);
    final existing = AppState.I.sessionById(dto.id);
    if (existing != null) {
      _applyDto(existing, dto);
    } else {
      AppState.I.sessions.add(_sessionFromDto(dto));
    }
    await _persistIds();
    AppState.I.notifyListeners();
    notifyListeners();
    return dto.id;
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
        projectId: dto.projectId,
        createdAt: dto.createdAt,
        updatedAt: dto.updatedAt,
      );

  void _applyDto(ChatSession session, SessionDto dto) {
    final title = dto.title;
    if (!isPlaceholderTitle(title)) {
      session.title = title!;
    } else if (!isPlaceholderTitle(session.title)) {
      // CH-013: the server still holds the placeholder (or nothing) while
      // this device has a real title — keep ours and heal the server copy
      // instead of reverting the sidebar to "New chat".
      final local = session.title;
      unawaited(_rest
          .patchSession(dto.id, title: local)
          .then((_) {}, onError: (Object _) {}));
    }
    session.mode = dto.mode;
    session.projectId = dto.projectId;
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
    if (!_loaded) await _ready;
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
    if (!_loaded) await _ready;

    // The cursor is read BEFORE the page request: everything at or below it
    // is reflected by the REST snapshot, so the replay can safely resume
    // after it (any event committed during the request has a higher seq and
    // is replayed; the projector's messageId guard makes that idempotent).
    final cursor = before == null ? await _ws.cursorFor(serverSessionId) : null;

    // Serve the cache while the link is down, then let the live stream catch
    // up. Keying this on the connectivity probe alone made a cold start issue
    // a REST read before the socket existed, which is slower and, in tests,
    // opened a socket nothing owned.
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
        withEvents: true,
      );
    } catch (_) {
      // A network failure on the newest page still opens the read cache.
      if (before == null) await _seedFromCache(serverSessionId);
      rethrow;
    }

    // The server answered for this id: it is a server session.
    _knownServerIds.add(serverSessionId);

    final fetched = <Message>[
      // The wire is newest-first; the transcript is oldest-first.
      for (final dto in page.items.reversed) _messageFromDto(dto),
    ];

    // Wave 1b: a server that answers the watermark + events gets the rich
    // path — the transcript is rebuilt from rows AND agent activity, and the
    // live stream resumes after the snapshot's watermark (CH-003).
    if (page is MessagePage && page.hasWatermark && page.rawEvents != null) {
      final events = <CloudSessionEvent>[
        for (final raw in page.rawEvents!)
          if (_decodeEvent(raw) case final CloudSessionEvent e) e,
      ];
      final folded = EventTranscriptProjector.foldPage(
        rows: _dedupe(fetched),
        events: events,
      );
      final settled = <Message>[
        for (final m in folded.messages)
          if (m.kind != MsgKind.streaming) m,
      ];
      folded.dispose();
      if (before == null) {
        final entry = _CachedTranscript(
          messages: settled,
          cursor: _settledCursor(events, page.lastEventSeq, page.activeRunId),
        );
        await _writeCache(serverSessionId, entry);
        _cacheMemory[serverSessionId] = entry;
        _transcriptSink?.seedRichTranscript(
          serverSessionId,
          rows: _dedupe(fetched),
          events: events,
          watermark: page.lastEventSeq,
          activeRunId: page.activeRunId,
        );
        notifyListeners();
        return;
      }
      final existing =
          await _readCache(serverSessionId) ?? _cacheMemory[serverSessionId];
      final merged = _dedupe(<Message>[...settled, ...?existing?.messages]);
      final entry =
          _CachedTranscript(messages: merged, cursor: existing?.cursor);
      await _writeCache(serverSessionId, entry);
      _cacheMemory[serverSessionId] = entry;
      _transcriptSink?.prependTranscript(serverSessionId, settled);
      notifyListeners();
      return;
    }

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
        // CH-006: the files sent with this prompt render as chips.
        attachments: <MessageAttachment>[
          for (final a in dto.attachments)
            MessageAttachment(name: a.name, size: a.sizeBytes),
        ],
      );

  static CloudSessionEvent? _decodeEvent(Map<String, dynamic> raw) {
    try {
      return CloudSessionEvent.fromJson(raw);
    } catch (_) {
      return null; // an off-contract event never fails the page
    }
  }

  /// The cache's replay cursor for a rich page: the watermark — unless a
  /// run is still in flight, whose live text the cache does NOT hold; then
  /// the seq just before that run started, so an offline cold start replays
  /// the run from its beginning instead of losing its first tokens.
  static String? _settledCursor(
    List<CloudSessionEvent> events,
    String? watermark,
    String? activeRunId,
  ) {
    if (activeRunId == null) return watermark;
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == 'run_started' && e.payload['runId'] == activeRunId) {
        return i == 0 ? null : events[i - 1].seq;
      }
    }
    return watermark;
  }

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
  /// Accepts a local id or its mapped server id. Only the CURRENT account's
  /// entries are visible (P0 privacy: another account's queued prompt text
  /// is never surfaced, even on a shared device).
  List<OutboxEntry> outboxFor(String sessionId) {
    final target = serverIdFor(sessionId) ?? sessionId;
    return List<OutboxEntry>.unmodifiable(
      _outbox.where(
        (entry) =>
            _ownedByCurrentAccount(entry) &&
            (entry.sessionId == target || entry.sessionId == sessionId),
      ),
    );
  }

  /// Every queued prompt owned by the current account, FIFO. The facade uses
  /// this to upload staged files before the reconnect flush; a foreign
  /// account's retained entries must not trigger session creates or uploads
  /// under the wrong credentials.
  List<OutboxEntry> get outboxEntries =>
      List<OutboxEntry>.unmodifiable(_ownedOutboxView);

  /// True only when [entry] was enqueued by the account that is signed in
  /// NOW. Null never owns (fail-closed): post-migration every in-memory
  /// entry is stamped, so an unstamped row means the migration did not run.
  bool _ownedByCurrentAccount(OutboxEntry entry) =>
      entry.account != null &&
      entry.account == AppState.I.sessionAccountId;

  Iterable<OutboxEntry> get _ownedOutboxView =>
      _outbox.where(_ownedByCurrentAccount);

  /// The last flush failure (surfaced by Task 10), or null.
  ({String code, String message})? get outboxError => _outboxError;

  /// Dismisses the last flush failure without touching the queue. A later
  /// flush failure records a fresh one.
  void clearOutboxError() {
    if (_outboxError == null) return;
    _outboxError = null;
    notifyListeners();
  }

  /// Queues [content] durably and returns the stored entry. [clientMsgId]
  /// is the Task 4 idempotency key minted when the user pressed Send — the
  /// SAME key rides every retry of this prompt, so a timed-out POST that the
  /// gateway did accept can never become a second run (CH-010). The entry is
  /// stamped with the account signed in NOW (P0 privacy: only that account
  /// can ever deliver or see it) and persisted before this future
  /// completes, so a process kill cannot lose it. [maxOutputTokens] (null =
  /// auto), [turn] (model / mode / plan / preset / @-tagged sessions) and
  /// [attachmentFiles] (staged files not uploaded yet) ride the flush.
  Future<OutboxEntry> enqueue(
    String sessionId,
    String content, {
    List<String> attachmentIds = const <String>[],
    int? maxOutputTokens,
    String? clientMsgId,
    CloudTurnOptions turn = CloudTurnOptions.none,
    List<OutboxFile> attachmentFiles = const <OutboxFile>[],
  }) async {
    if (!_loaded) await _ready;
    final target = serverIdFor(sessionId) ?? sessionId;
    final key = (clientMsgId != null && clientMsgId.isNotEmpty)
        ? clientMsgId
        : newClientMsgId();
    final existing = _outbox.indexWhere((e) => e.clientMsgId == key);
    final entry = OutboxEntry(
      clientMsgId: key,
      sessionId: target,
      content: content,
      attachmentIds: attachmentIds,
      createdAt: DateTime.now(),
      maxOutputTokens: maxOutputTokens,
      account: AppState.I.sessionAccountId,
      turn: turn,
      attachmentFiles: attachmentFiles,
    );
    if (existing >= 0) {
      // A retry of the same prompt: keep its queue position.
      _outbox[existing] = entry;
    } else {
      _outbox.add(entry);
    }
    await _persistOutbox();
    notifyListeners();
    return entry;
  }

  /// The queued entry for [clientMsgId] owned by the current account, or
  /// null (delivered, discarded, never queued).
  OutboxEntry? outboxEntry(String clientMsgId) {
    for (final entry in _outbox) {
      if (entry.clientMsgId == clientMsgId && _ownedByCurrentAccount(entry)) {
        return entry;
      }
    }
    return null;
  }

  /// The server's answer for a prompt this process delivered (kept so a
  /// direct send can read its own outcome after the flush).
  SendMessageResponse? deliveredResponse(String clientMsgId) =>
      _delivered[clientMsgId];

  final Map<String, SendMessageResponse> _delivered =
      <String, SendMessageResponse>{};

  /// The user tapped Retry on a "Not sent" prompt: clear the refusal and
  /// deliver again with the SAME clientMsgId.
  Future<void> retryOutboxEntry(String clientMsgId) async {
    if (!_loaded) await _ready;
    final index = _outbox.indexWhere(
        (e) => e.clientMsgId == clientMsgId && _ownedByCurrentAccount(e));
    if (index < 0) return;
    _outbox[index] = _outbox[index].copyWith(clearFailure: true, attempts: 0);
    await _persistOutbox();
    notifyListeners();
    await flushOutbox();
  }

  /// The user discarded a queued or "Not sent" prompt. The only way a
  /// composed prompt ever leaves the outbox without being delivered.
  Future<void> discardOutboxEntry(String clientMsgId) async {
    if (!_loaded) await _ready;
    final before = _outbox.length;
    _outbox.removeWhere(
        (e) => e.clientMsgId == clientMsgId && _ownedByCurrentAccount(e));
    if (_outbox.length == before) return;
    await _persistOutbox();
    if (_ownedOutboxView.every((e) => !e.failed)) _outboxError = null;
    notifyListeners();
  }

  /// Records the ids of files uploaded for an already-queued prompt (the
  /// facade's offline-attachment path, before [flushOutbox]).
  Future<void> setAttachmentIds(
    String clientMsgId,
    List<String> attachmentIds,
  ) async {
    if (!_loaded) await _ready;
    final index =
        _outbox.indexWhere((entry) => entry.clientMsgId == clientMsgId);
    if (index < 0) return;
    _outbox[index] = _outbox[index].copyWith(attachmentIds: attachmentIds);
    await _persistOutbox();
    notifyListeners();
  }

  /// Sends the outbox in FIFO order (per session).
  ///
  /// * success (including a Task 4 `clientMsgId` replay) → remove, continue;
  /// * 409 `run_conflict` → the prompt was already accepted → remove;
  /// * transient (network, timeout, 408/425/429, 5xx) → KEEP it and
  ///   everything behind it, schedule a backoff retry (honouring
  ///   `x-ovid-resets-at` for 429), stop;
  /// * refused (400/401/402/403/404/413, a missing attachment file) → KEEP
  ///   it, marked failed with the reason ("Not sent" + Retry / Discard in the
  ///   chat), and hold that session's later prompts behind it so the order
  ///   never flips. Nothing is ever dropped silently (CH-009).
  ///
  /// A RETAINED foreign entry (another account's prompt left in the queue by
  /// an account switch) is skipped, never sent and never dropped — it stays
  /// under its owner's key until that account signs in again.
  ///
  /// Concurrent calls coalesce: a call that lands while a flush is running
  /// makes that flush run one more pass, and returns when it ends — so an
  /// entry enqueued mid-flush is always attempted before the caller resumes.
  Future<void> flushOutbox() async {
    if (!_loaded) await _ready;
    final pending = _flushFuture;
    if (pending != null) {
      _flushAgain = true;
      return pending;
    }
    final future = _flushLoop();
    _flushFuture = future;
    try {
      await future;
    } finally {
      if (identical(_flushFuture, future)) _flushFuture = null;
    }
  }

  bool _flushAgain = false;
  Timer? _retryTimer;

  Future<void> _flushLoop() async {
    do {
      _flushAgain = false;
      await _flushOutbox();
    } while (_flushAgain && !_connection.offline);
  }

  Future<void> _flushOutbox() async {
    // Delivery is REST, so a down WebSocket must not hold prompts back while
    // HTTP still works (a proxy that blocks WS, a reconnect in progress).
    // Only the connectivity probe — "can we reach Ovid at all?" — can skip;
    // a dead REST link fails fast and the backoff below retries it.
    if (_connection.offline) return;
    final held = <String>{};
    for (final id in [for (final e in _outbox) e.clientMsgId]) {
      // Re-read by key: a session create mid-flush rewrites entries.
      final index = _outbox.indexWhere((e) => e.clientMsgId == id);
      if (index < 0) continue;
      final entry = _outbox[index];
      // P0 privacy: skip-and-RETAIN another account's prompt. Delivering it
      // here would send account A's text under B's credentials; dropping it
      // would lose A's composed prompt. It flushes when its owner returns.
      if (!_ownedByCurrentAccount(entry)) continue;
      if (entry.failed) {
        held.add(entry.sessionId);
        continue;
      }
      if (held.contains(entry.sessionId)) continue;
      final outcome = await _deliver(entry);
      if (outcome == CloudFailureKind.transient) return;
      if (outcome == CloudFailureKind.refused) held.add(entry.sessionId);
    }
    // A fully-delivered queue clears the stale error (Task 10's chip).
    // Foreign retained entries do not hold the chip: they are not this
    // account's.
    if (_ownedOutboxView.every((e) => !e.failed) && _outboxError != null) {
      _outboxError = null;
      notifyListeners();
    }
  }

  /// Delivers one entry: resolve (or create) the server session, upload any
  /// staged files, POST with the entry's own clientMsgId. Null = delivered.
  Future<CloudFailureKind?> _deliver(OutboxEntry original) async {
    var entry = original;
    try {
      final serverId = await ensureServerSession(entry.sessionId);
      entry = _current(entry);
      if (entry.sessionId != serverId) {
        entry = await _replaceEntry(entry, entry.copyWith(sessionId: serverId));
      }
      // Staged files upload to the RESOLVED server session (CH-033): ids are
      // recorded one by one, so a retry never re-uploads a finished file.
      for (final file in List<OutboxFile>.of(entry.attachmentFiles)) {
        final upload = await _rest.createAttachment(
          serverId,
          name: file.name,
          size: file.size,
        );
        final bytes = await File(file.path).readAsBytes();
        await _rest.uploadAttachmentBytes(upload, bytes);
        entry = await _replaceEntry(
          entry,
          entry.copyWith(
            attachmentIds: <String>[...entry.attachmentIds, upload.attachmentId],
            attachmentFiles: <OutboxFile>[
              for (final f in entry.attachmentFiles)
                if (!identical(f, file)) f,
            ],
          ),
        );
      }
      final response = await _rest.sendMessage(
        serverId,
        entry.content,
        attachmentIds: entry.attachmentIds,
        clientMsgId: entry.clientMsgId,
        maxOutputTokens: entry.maxOutputTokens,
        turn: entry.turn,
      );
      _outbox.removeWhere((e) => e.clientMsgId == entry.clientMsgId);
      _delivered[entry.clientMsgId] = response;
      if (_delivered.length > 64) _delivered.remove(_delivered.keys.first);
      await _persistOutbox();
      _transcriptSink?.outboxDelivered(serverId, entry, response);
      notifyListeners();
      return null;
    } catch (e) {
      final kind = classifyCloudFailure(e);
      final code = cloudFailureCode(e);
      final message = e is CloudApiException ? e.message : '$e';
      switch (kind) {
        case CloudFailureKind.alreadyAccepted:
          // Already accepted (Task 4 idempotency): the entry is done.
          _outbox.removeWhere((x) => x.clientMsgId == entry.clientMsgId);
          await _persistOutbox();
          notifyListeners();
          return null;
        case CloudFailureKind.transient:
          // A failed request is first-hand evidence the connection may be
          // gone; re-ask now so the offline banner and the composer notice
          // stop claiming "online" until the next 30 s tick or app resume.
          if (code == 'network' || code == 'timeout') {
            unawaited(_connection.probe());
          }
          final current = _current(entry);
          final attempts = current.attempts + 1;
          await _replaceEntry(current, current.copyWith(attempts: attempts));
          _outboxError = (code: code, message: message);
          _scheduleRetry(
            attempts,
            e is CloudApiException && e.status == 429 ? e.resetsAt : null,
          );
          notifyListeners();
          return kind;
        case CloudFailureKind.refused:
          final current = _current(entry);
          await _replaceEntry(
            current,
            current.copyWith(failedCode: code, failedMessage: message),
          );
          _outboxError = (code: code, message: message);
          _lastFailureResetsAt =
              e is CloudApiException ? e.resetsAt : null;
          notifyListeners();
          return kind;
      }
    }
  }

  DateTime? _lastFailureResetsAt;

  /// `x-ovid-resets-at` of the last refused delivery (402 countdown).
  DateTime? get outboxErrorResetsAt => _lastFailureResetsAt;

  /// The live copy of [entry] (it may have been rewritten mid-delivery).
  OutboxEntry _current(OutboxEntry entry) {
    for (final e in _outbox) {
      if (e.clientMsgId == entry.clientMsgId) return e;
    }
    return entry;
  }

  Future<OutboxEntry> _replaceEntry(OutboxEntry old, OutboxEntry next) async {
    final index = _outbox.indexWhere((e) => e.clientMsgId == old.clientMsgId);
    if (index >= 0) {
      _outbox[index] = next;
      await _persistOutbox();
    }
    return next;
  }

  /// Exponential backoff: 2 s, 4 s, 8 s … capped at 60 s; a 429 with a
  /// reset instant waits until then (capped at 10 min).
  @visibleForTesting
  static Duration retryDelay(int attempts, {DateTime? resetsAt, DateTime? now}) {
    final exp = Duration(seconds: min(60, 2 << (min(max(attempts, 1), 6) - 1)));
    if (resetsAt == null) return exp;
    final wait = resetsAt.difference(now ?? DateTime.now());
    if (wait <= exp) return exp;
    return wait > const Duration(minutes: 10)
        ? const Duration(minutes: 10)
        : wait;
  }

  void _scheduleRetry(int attempts, DateTime? resetsAt) {
    if (!autoRetry) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay(attempts, resetsAt: resetsAt), () {
      _retryTimer = null;
      unawaited(flushOutbox().catchError((Object _) {}));
    });
  }

  /// A fresh 32-hex idempotency key (Task 4). Minted ONCE per user send and
  /// kept across every retry of that prompt (CH-010).
  static String newClientMsgId() => _newClientMsgId();

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

  void _decodeTombstones(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _deletedServerIds.addAll(decoded.whereType<String>());
      }
    } catch (_) {
      // Corrupt list: harmless — the server list would just re-appear.
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
    await prefs.setString(
        tombstonesKey, jsonEncode(_deletedServerIds.toList()));
  }

  /// Writes the queue partitioned by owner: each account's entries go under
  /// THAT account's scoped key (P0 privacy), so one account's writes never
  /// clobber or carry another's prompts. A retained foreign entry survives a
  /// flush/persist by the current account intact, under its owner's key.
  Future<void> _persistOutbox() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final byAccount = <String, List<Map<String, dynamic>>>{};
    for (final entry in _outbox) {
      final owner = entry.account ?? AppState.I.sessionAccountId;
      byAccount.putIfAbsent(owner, () => <Map<String, dynamic>>[]).add(
        entry.toJson(),
      );
    }
    final written = <String>{};
    for (final owner in byAccount.keys) {
      final key = AppState.I.accountScopedPrefKey(outboxKey, owner);
      written.add(key);
      await prefs.setString(key, jsonEncode(byAccount[owner]));
    }
    // A drained owner's key must not resurrect stale rows on the next load.
    for (final key in _outboxKeys.difference(written)) {
      await prefs.remove(key);
    }
    _outboxKeys
      ..clear()
      ..addAll(written);
  }
}
