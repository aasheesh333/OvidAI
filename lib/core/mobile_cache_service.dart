import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'state.dart';

/// Measured cache bytes. Null means enumeration/length measurement was not
/// complete; it never means zero.
class CacheClearReport {
  const CacheClearReport({
    required this.beforeBytes,
    required this.afterBytes,
    required this.residualBytes,
  });

  final int? beforeBytes;
  final int? afterBytes;
  final int? residualBytes;

  bool get measurementComplete =>
      beforeBytes != null && afterBytes != null && residualBytes != null;

  int? get freedBytes {
    final before = beforeBytes;
    final after = afterBytes;
    if (before == null || after == null || residualBytes == null) return null;
    final freed = before - after;
    return freed > 0 ? freed : 0;
  }
}

class _CacheMeasurement {
  const _CacheMeasurement(this.bytes, this.complete);

  final int bytes;
  final bool complete;

  int? get reportedBytes => complete ? bytes : null;
}

/// Clears known cache-only entries without treating the whole app sandbox as
/// disposable. Unknown files remain and are reported as residual. The account/
/// reset token is checked at every asynchronous deletion boundary.
class MobileCacheService {
  MobileCacheService({
    Future<Directory> Function()? rootDirectory,
    Object Function()? resetFenceToken,
    bool Function()? resetWritesAllowed,
    Future<void> Function(FileSystemEntity entity)? deleteEntity,
  }) : _rootDirectory = rootDirectory ?? getTemporaryDirectory,
       _resetFenceToken =
           resetFenceToken ?? (() => AppState.I.sessionAccountToken),
       _resetWritesAllowed =
           resetWritesAllowed ?? (() => AppState.I.sessionAccountReady),
       _deleteEntity = deleteEntity ?? _delete;

  final Future<Directory> Function() _rootDirectory;
  final Object Function() _resetFenceToken;
  final bool Function() _resetWritesAllowed;
  final Future<void> Function(FileSystemEntity entity) _deleteEntity;

  static Future<void> _delete(FileSystemEntity entity) async {
    await entity.delete(recursive: true);
  }

  Future<CacheClearReport> measure() async {
    final measured = await _measureRoot();
    final bytes = measured.reportedBytes;
    return CacheClearReport(
      beforeBytes: bytes,
      afterBytes: bytes,
      residualBytes: bytes,
    );
  }

  Future<CacheClearReport> clear() async {
    final root = await _rootDirectory();
    final before = (await _measureRoot(root)).reportedBytes;
    final token = _resetFenceToken();
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        if (!_owns(token)) break;
        if (_isCacheRoot(entity)) await _clearEntity(entity, token);
      }
    }
    final after = (await _measureRoot(root)).reportedBytes;
    return CacheClearReport(
      beforeBytes: before,
      afterBytes: after,
      residualBytes: after,
    );
  }

  bool _owns(Object token) =>
      _resetWritesAllowed() && identical(_resetFenceToken(), token);

  Future<_CacheMeasurement> _measureRoot([Directory? root]) async {
    final directory = root ?? await _rootDirectory();
    try {
      if (!await directory.exists()) {
        return const _CacheMeasurement(0, true);
      }
    } catch (_) {
      return const _CacheMeasurement(0, false);
    }
    var bytes = 0;
    var complete = true;
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (!_isCacheRoot(entity)) continue;
        final measured = await _measureEntity(entity);
        bytes += measured.bytes;
        complete = complete && measured.complete;
      }
    } catch (_) {
      complete = false;
    }
    return _CacheMeasurement(bytes, complete);
  }

  Future<_CacheMeasurement> _measureEntity(FileSystemEntity entity) async {
    if (_isProtected(entity)) return const _CacheMeasurement(0, true);
    if (entity is File) {
      try {
        return _CacheMeasurement(await entity.length(), true);
      } catch (_) {
        return const _CacheMeasurement(0, false);
      }
    }
    if (entity is! Directory) {
      // Links and special files have no safe byte measurement. They remain in
      // place, and their residual size is unknown rather than zero.
      return const _CacheMeasurement(0, false);
    }
    var bytes = 0;
    var complete = true;
    try {
      await for (final child in entity.list(followLinks: false)) {
        final measured = await _measureEntity(child);
        bytes += measured.bytes;
        complete = complete && measured.complete;
      }
    } catch (_) {
      complete = false;
    }
    return _CacheMeasurement(bytes, complete);
  }

  Future<void> _clearEntity(FileSystemEntity entity, Object token) async {
    if (!_owns(token) || _isProtected(entity)) return;
    if (entity is Directory) {
      try {
        await for (final child in entity.list(followLinks: false)) {
          if (!_owns(token)) return;
          await _clearEntity(child, token);
        }
        if (!_owns(token)) return;
        // Never recursively delete a parent: it may still contain an unknown,
        // protected, or undeletable child deliberately skipped above.
        await entity.delete(recursive: false);
      } catch (_) {
        // A non-empty or unavailable directory remains as residual data.
      }
      return;
    }
    if (entity is! File || !_isKnownCacheArtifact(entity) || !_owns(token)) {
      return;
    }
    try {
      await _deleteEntity(entity);
    } catch (_) {
      // The post-clear measurement reports this entry as residual bytes.
    }
  }

  bool _isCacheRoot(FileSystemEntity entity) {
    final name = _name(entity);
    return name == 'cache' ||
        name == 'caches' ||
        name == 'image_cache' ||
        name == 'voice-cache' ||
        name.startsWith('cache-') ||
        name.startsWith('cache_') ||
        name.startsWith('ovid-cache-') ||
        name.endsWith('.cache');
  }

  /// Deletion is allowlist-based, never a heuristic denylist. A file type not
  /// proven to be a disposable media/temp artifact stays on disk and counts as
  /// residual, including id_rsa, key.pem, logs, documents, and archives.
  bool _isKnownCacheArtifact(File file) {
    final name = _name(file);
    const extensions = {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.bmp',
      '.tmp',
      '.temp',
      '.part',
      '.download',
      '.cache',
      '.m4a',
      '.aac',
      '.mp3',
      '.wav',
      '.ogg',
      '.opus',
      '.mp4',
      '.webm',
      '.mov',
    };
    return extensions.any(name.endsWith);
  }

  bool _isProtected(FileSystemEntity entity) {
    final name = _name(entity);
    const accountWords = [
      'credential',
      'secret',
      'setting',
      'preference',
      'server',
      'session',
      'chat',
      'token',
      'auth',
      'profile',
      'account',
    ];
    if (accountWords.any(name.contains)) return true;
    const serverTextExtensions = [
      '.json',
      '.md',
      '.txt',
      '.csv',
      '.xml',
      '.html',
      '.db',
      '.sqlite',
    ];
    return serverTextExtensions.any(name.endsWith);
  }

  String _name(FileSystemEntity entity) =>
      entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .lastOrNull
          ?.toLowerCase() ??
      '';
}
