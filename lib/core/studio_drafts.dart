import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'diag.dart';

// ── Studio draft safety (screen review 06 §1, §4) ───────────────────────────
// Unsaved editor buffers and uncommitted API-mode edits used to live only in
// memory: Android process death (common while the user is in the browser for
// GitHub sign-in or in the file picker) silently threw them away. This store
// keeps them in an app-private directory so they come back on the next open.

/// Above this many characters a file opens in the read-only viewer first:
/// a single `TextField` lays the whole text out as one paragraph.
const int kStudioViewerThreshold = 256 * 1024;

/// Hard cap for editing on device. Larger files are never loaded into the
/// editor ("Too large — open in terminal").
const int kStudioEditHardCap = 1024 * 1024;

/// Size above which UTF-8 decoding moves off the UI isolate.
const int kStudioDecodeInIsolate = 200 * 1024;

const int _sniffWindow = 8 * 1024;

/// True when [bytes] look like a binary file: a NUL byte in the first 8 KB.
bool looksBinaryBytes(List<int> bytes) {
  final end = bytes.length < _sniffWindow ? bytes.length : _sniffWindow;
  for (var i = 0; i < end; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// True when decoded [text] came from a binary file: a NUL character in the
/// first 8 KB, or more than 10 % U+FFFD replacement characters (the trace an
/// `allowMalformed` decode leaves on non-UTF-8 bytes).
bool looksBinaryText(String text) {
  final end = text.length < _sniffWindow ? text.length : _sniffWindow;
  if (end == 0) return false;
  var replaced = 0;
  for (var i = 0; i < end; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0) return true;
    if (unit == 0xFFFD) replaced++;
  }
  return replaced * 10 > end;
}

/// What [StudioDraftStore.schedule] writes for one record at flush time:
/// `null` leaves the file alone, a null `data` deletes it.
typedef StudioDraftSnapshot = ({Map<String, Object?>? data})?;

/// Debounced, app-private persistence for Studio drafts.
///
/// Disabled until [enable] is called (production does it in `main`), so unit
/// and widget tests never touch `path_provider` or leave debounce timers
/// behind unless they opt in.
class StudioDraftStore {
  StudioDraftStore._();
  static final StudioDraftStore I = StudioDraftStore._();

  Future<Directory> Function()? _root;
  Directory? _dir;

  /// Delay between the last change and the write.
  Duration debounce = const Duration(seconds: 2);

  final Map<String, StudioDraftSnapshot Function()> _pending = {};
  Timer? _timer;
  Future<void> _chain = Future<void>.value();

  bool get enabled => _root != null;

  /// Turns persistence on. [root] defaults to the app support directory.
  void enable({Future<Directory> Function()? root}) {
    _root = root ?? getApplicationSupportDirectory;
    _dir = null;
  }

  @visibleForTesting
  void disableForTest() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _root = null;
    _dir = null;
    debounce = const Duration(seconds: 2);
  }

  /// Stable, filesystem-safe record name for an arbitrary binding key.
  static String recordName(String prefix, String key) =>
      '${prefix}_${sha1.convert(utf8.encode(key))}';

  /// Queue [name] for the next debounced write. [snapshot] runs at flush
  /// time, so the newest state is written once however many edits arrived.
  void schedule(String name, StudioDraftSnapshot Function() snapshot) {
    if (!enabled) return;
    _pending[name] = snapshot;
    _timer ??= Timer(debounce, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Write every queued record now (app paused, Studio closed).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (!enabled || _pending.isEmpty) return _chain;
    final jobs = <String, StudioDraftSnapshot>{};
    for (final entry in _pending.entries) {
      try {
        jobs[entry.key] = entry.value();
      } catch (error, stack) {
        Diag.swallow('studio_drafts.snapshot', error, stack);
      }
    }
    _pending.clear();
    return _chain = _chain.then((_) async {
      for (final job in jobs.entries) {
        final snapshot = job.value;
        if (snapshot == null) continue;
        await _write(job.key, snapshot.data);
      }
    });
  }

  /// Drop a record immediately (explicit discard).
  Future<void> delete(String name) {
    _pending.remove(name);
    if (!enabled) return _chain;
    return _chain = _chain.then((_) => _write(name, null));
  }

  /// Drop every record whose name starts with [prefix].
  Future<void> deleteAll(String prefix) {
    _pending.removeWhere((name, _) => name.startsWith(prefix));
    if (!enabled) return _chain;
    return _chain = _chain.then((_) async {
      try {
        await for (final entry in (await _directory()).list()) {
          final name = entry.uri.pathSegments.last;
          if (entry is File && name.startsWith(prefix)) await entry.delete();
        }
      } catch (error, stack) {
        Diag.swallow('studio_drafts.deleteAll', error, stack);
      }
    });
  }

  Future<Map<String, Object?>?> read(String name) async {
    if (!enabled) return null;
    await _chain;
    try {
      final file = File('${(await _directory()).path}/$name.json');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (error, stack) {
      Diag.swallow('studio_drafts.read', error, stack);
      return null;
    }
  }

  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final root = await _root!();
    final dir = Directory('${root.path}/studio_drafts');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<void> _write(String name, Map<String, Object?>? data) async {
    try {
      final dir = await _directory();
      final file = File('${dir.path}/$name.json');
      if (data == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      // Write-then-rename: a crash mid-write never leaves a torn draft.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(file.path);
    } catch (error, stack) {
      Diag.swallow('studio_drafts.write', error, stack);
    }
  }
}

/// Why a Studio tab shows a placeholder instead of an editable buffer.
enum StudioFileGuardKind { binary, tooLarge }

/// A Studio tab that must never be edited or saved (F-075, F-076).
@immutable
class StudioFileGuard {
  const StudioFileGuard.binary({this.bytes = 0}) : kind = StudioFileGuardKind.binary;
  const StudioFileGuard.tooLarge(this.bytes) : kind = StudioFileGuardKind.tooLarge;

  final StudioFileGuardKind kind;

  /// File size on disk, when known.
  final int bytes;

  bool get binary => kind == StudioFileGuardKind.binary;
}
