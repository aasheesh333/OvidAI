import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';
import 'state.dart';

/// Thrown by the server-backed pin writer when the chat has no server row
/// yet (it has never been sent). Pinning then stays local until the first
/// send maps the chat to a server id.
class PinNotOnServer implements Exception {
  const PinNotOnServer();
}

/// Writes a pin to the server and returns the authoritative `pinnedAt`
/// (null when the server says not pinned).
typedef PinRemoteWriter =
    Future<DateTime?> Function(String sessionId, bool pinned);

/// W9 pinned-chat store.
///
/// The chat header's ⋮ menu offers "Pin Session". The SERVER is the source of
/// truth (`PATCH /sessions/:id {pinned}` → `SessionDto.pinnedAt`), so a pin
/// made on Android is visible on Web and survives a reinstall. This store
/// keeps a per-account local cache so the UI has an offline answer, but a
/// server value — including an explicit "not pinned" (`pinnedAt: null`) —
/// always wins once it is known.
///
/// Account scoping uses the same owner-suffixed preferences key as the
/// composer drafts, so switching accounts never leaks another account's pins.
class ChatPinsStore extends ChangeNotifier {
  ChatPinsStore._();
  static final ChatPinsStore I = ChatPinsStore._();

  static const prefsKey = 'chat_pins_v1';

  String _account = 'guest';
  final Set<String> _pinned = <String>{};

  /// Server-known pins for this account, keyed by the UI's session id (local
  /// id for a mapped chat, server id otherwise). A present key means the
  /// server has answered; its value is `pinnedAt` (null = not pinned).
  final Map<String, DateTime?> _serverPins = <String, DateTime?>{};

  PinRemoteWriter? _remoteWriter;
  Future<void>? _loading;
  Future<void>? _write;
  bool _persistQueued = false;

  String get _prefsKey => _account == 'guest'
      ? prefsKey
      : '${prefsKey}_owner_${Uri.encodeComponent(_account)}';

  /// Pinned session ids (this account): the server value where known, the
  /// local cache otherwise. [applyServerPin] keeps the cache in step, so this
  /// single set is enough.
  Set<String> get pinned => Set.unmodifiable(<String>{
    for (final id in _pinned)
      if (isPinned(id)) id,
  });

  bool isPinned(String sessionId) {
    if (_serverPins.containsKey(sessionId)) {
      return _serverPins[sessionId] != null;
    }
    return _pinned.contains(sessionId);
  }

  /// The server pin instant when known (null for unknown OR not pinned —
  /// check [serverPinnedKnown] to tell them apart).
  DateTime? pinnedAtFor(String sessionId) => _serverPins[sessionId];

  /// True once a gateway has answered for this session.
  bool serverPinnedKnown(String sessionId) =>
      _serverPins.containsKey(sessionId);

  /// Installs the server-backed writer. [CloudSessionStore] owns the REST
  /// client and the local→server id map, so it installs this once.
  void attachServer(PinRemoteWriter write) {
    _remoteWriter = write;
  }

  /// Adopts the server's answer for [sessionId]. Called for every session DTO
  /// a refresh applies — including an explicit null, which unpins.
  void applyServerPin(String sessionId, DateTime? pinnedAt) {
    if (_serverPins.containsKey(sessionId) &&
        _serverPins[sessionId] == pinnedAt) {
      return;
    }
    _serverPins[sessionId] = pinnedAt;
    // Keep the offline cache aligned so a later cold start shows the same
    // state before the first refresh.
    if (pinnedAt != null) {
      _pinned.add(sessionId);
    } else {
      _pinned.remove(sessionId);
    }
    _persist();
    notifyListeners();
  }

  /// Drops server knowledge (account change / sign-out). The local cache is
  /// cleared by [bindAccount] at the same time.
  void clearServerPins() {
    if (_serverPins.isEmpty) return;
    _serverPins.clear();
    notifyListeners();
  }

  /// Fences in-memory state when account ownership changes.
  Future<void> bindAccount(String account) {
    if (_account == account) return _loading ?? Future<void>.value();
    _account = account;
    _pinned.clear();
    _serverPins.clear();
    _loading = null;
    return load();
  }

  /// Loads the account's pins once.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final id in decoded) {
          if (id is String && id.isNotEmpty) _pinned.add(id);
        }
      }
    } catch (e) {
      Diag.swallow('chat_pins.load', e);
    }
    notifyListeners();
  }

  /// Pins or unpins [sessionId]. For a server-backed chat this PATCHes the
  /// gateway first and adopts its `pinnedAt`; a failure propagates so the UI
  /// can revert instead of pretending the pin stuck. A chat with no server
  /// row yet falls back to the local cache.
  Future<bool> setPinned(String sessionId, bool pinned) async {
    await load();
    final write = _remoteWriter;
    if (write != null) {
      try {
        final pinnedAt = await write(sessionId, pinned);
        _serverPins[sessionId] = pinnedAt;
        if (pinnedAt != null) {
          _pinned.add(sessionId);
        } else {
          _pinned.remove(sessionId);
        }
        _persist();
        notifyListeners();
        return pinnedAt != null;
      } on PinNotOnServer {
        // No server row yet: keep the local fallback below.
      }
    }
    final changed = pinned ? _pinned.add(sessionId) : _pinned.remove(sessionId);
    if (changed) {
      notifyListeners();
      _persist();
    }
    return pinned;
  }

  Future<bool> toggle(String sessionId) async =>
      setPinned(sessionId, !isPinned(sessionId));

  /// Persists the cache. Coalesced: a list refresh applies every session's
  /// server pin in one loop, and each row must not queue its own prefs write.
  void _persist() {
    if (_persistQueued) return;
    _persistQueued = true;
    _write = (_write ?? Future<void>.value()).then((_) async {
      _persistQueued = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode(_pinned.toList()));
      } catch (e) {
        Diag.swallow('chat_pins.persist', e);
      }
    });
  }

  @visibleForTesting
  void clearForTest() {
    _pinned.clear();
    _serverPins.clear();
    _remoteWriter = null;
    _loading = null;
    _persistQueued = false;
  }

  /// Seeds ONLY the local cache (the offline path), without a server write.
  @visibleForTesting
  void seedLocalPinForTest(String sessionId, bool pinned) {
    if (pinned) {
      _pinned.add(sessionId);
    } else {
      _pinned.remove(sessionId);
    }
    notifyListeners();
  }

  /// The account id the store scopes to (tests assert the fence).
  @visibleForTesting
  String get accountForTest => _account;

  /// Binds the current AppState account; safe to call on every boot.
  Future<void> bindCurrentAccount() => bindAccount(AppState.I.sessionAccountId);
}
