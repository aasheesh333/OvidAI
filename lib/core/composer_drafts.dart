import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';

/// Durable per-session composer drafts.
///
/// The chat composer keeps drafts in memory for instant session switching;
/// this store mirrors them to preferences (debounced) so a long prompt
/// survives process death, a phone call, or the OS reclaiming the app.
class ComposerDraftStore {
  ComposerDraftStore._();
  static final ComposerDraftStore I = ComposerDraftStore._();

  static const prefsKey = 'composer_drafts_v1';

  /// Debounce between the last keystroke and the preferences write.
  static Duration debounce = const Duration(milliseconds: 500);

  /// Longest draft persisted per session (protects preferences size).
  static const maxDraftChars = 100000;

  final Map<String, String> _drafts = {};
  Future<Map<String, String>>? _loading;
  Timer? _timer;
  // Serializes writes; created lazily in the caller's zone.
  Future<void>? _write;

  /// Loads persisted drafts once; later calls reuse the same future.
  Future<Map<String, String>> load() => _loading ??= _load();

  Future<Map<String, String>> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key;
            final value = entry.value;
            // Edits made before the load finished win over stale disk text.
            if (key is String && value is String && value.isNotEmpty) {
              _drafts.putIfAbsent(key, () => value);
            }
          }
        }
      }
    } catch (e) {
      Diag.swallow('composer_drafts.load', e);
    }
    return Map.unmodifiable(_drafts);
  }

  /// Persisted draft for [sessionId], or null (only after [load]).
  String? draftFor(String sessionId) => _drafts[sessionId];

  /// Records [text] as [sessionId]'s draft (empty clears it) and schedules a
  /// debounced write.
  void put(String sessionId, String text) {
    final value = text.length > maxDraftChars
        ? text.substring(0, maxDraftChars)
        : text;
    if (value.isEmpty) {
      if (_drafts.remove(sessionId) == null) return;
    } else {
      if (_drafts[sessionId] == value) return;
      _drafts[sessionId] = value;
    }
    _schedule();
  }

  /// Drops [sessionId]'s draft and schedules a write.
  void remove(String sessionId) => put(sessionId, '');

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Writes pending changes now (app pause, tests).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final snapshot = _drafts.isEmpty ? null : jsonEncode(_drafts);
    Future<void> write() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        // No drafts: drop the key, so Delete all data leaves nothing behind.
        if (snapshot == null) {
          await prefs.remove(prefsKey);
        } else {
          await prefs.setString(prefsKey, snapshot);
        }
      } catch (e) {
        Diag.swallow('composer_drafts.write', e);
      }
    }

    final previous = _write;
    return _write = previous == null ? write() : previous.then((_) => write());
  }

  /// Forgets every draft (account switch / delete all data) and persists it.
  Future<void> clearAll() {
    _drafts.clear();
    return flush();
  }

  /// Readback for the verified reset: nothing in memory and nothing persisted.
  Future<bool> isEmpty() async {
    await _write;
    if (_drafts.isNotEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(prefsKey);
    return raw == null || raw.isEmpty || raw == '{}';
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _drafts.clear();
    _loading = null;
    _write = null;
  }
}
