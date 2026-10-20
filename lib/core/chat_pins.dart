import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';
import 'state.dart';

/// W9 pinned-chat store.
///
/// The chat header's ⋮ menu offers "Pin Session". W1 owns projects (and may
/// later own pinning too); until a server-side pin exists this is a
/// per-account, locally persisted set. The pin is VISIBLE in the chat header
/// (a pin glyph beside the model) and reorders nothing on its own — the
/// sidebar's pinned section is the shell/W1 surface that reads [pinned].
///
/// Account scoping uses the same owner-suffixed preferences key as the
/// composer drafts, so switching accounts never leaks another account's pins.
class ChatPinsStore extends ChangeNotifier {
  ChatPinsStore._();
  static final ChatPinsStore I = ChatPinsStore._();

  static const prefsKey = 'chat_pins_v1';

  String _account = 'guest';
  final Set<String> _pinned = <String>{};
  Future<void>? _loading;
  Future<void>? _write;

  String get _prefsKey => _account == 'guest'
      ? prefsKey
      : '${prefsKey}_owner_${Uri.encodeComponent(_account)}';

  /// Pinned local session ids (this account).
  Set<String> get pinned => Set.unmodifiable(_pinned);

  bool isPinned(String sessionId) => _pinned.contains(sessionId);

  /// Fences in-memory state when account ownership changes.
  Future<void> bindAccount(String account) {
    if (_account == account) return _loading ?? Future<void>.value();
    _account = account;
    _pinned.clear();
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

  /// Pins or unpins [sessionId] and persists. Returns the new state.
  Future<bool> setPinned(String sessionId, bool pinned) async {
    await load();
    final changed = pinned ? _pinned.add(sessionId) : _pinned.remove(sessionId);
    if (changed) {
      notifyListeners();
      _persist();
    }
    return pinned;
  }

  Future<bool> toggle(String sessionId) async =>
      setPinned(sessionId, !_pinned.contains(sessionId));

  void _persist() {
    _write = (_write ?? Future<void>.value()).then((_) async {
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
    _loading = null;
  }

  /// The account id the store scopes to (tests assert the fence).
  @visibleForTesting
  String get accountForTest => _account;

  /// Binds the current AppState account; safe to call on every boot.
  Future<void> bindCurrentAccount() =>
      bindAccount(AppState.I.sessionAccountId);
}
