import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'state.dart';

/// The state owner must atomically publish the complete staged transcript set
/// and copied attachments, checking new IDs under its stop/write barrier.
/// On failure it must roll back all writes. Staging is deleted after it returns.
typedef SettingsRestorePublisher =
    Future<void> Function(
      StagedSettingsBackup backup,
      Map<String, String> newSessionIds,
    );

class StagedSettingsBackup {
  final Directory directory;
  final List<Map<String, dynamic>> sessions;
  final Map<String, File> attachments;

  /// Allowlisted, bounded preference values from the archive, or empty when the
  /// archive carried no settings section. Never contains credentials, grants,
  /// provider configuration, memory, MCP headers/env or plugin state.
  final Map<String, Object> settings;
  StagedSettingsBackup._(
    this.directory,
    this.sessions,
    this.attachments,
    this.settings,
  );
  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Version 1 is a portable TRANSCRIPT archive with an OPTIONAL allowlisted
/// settings snapshot. Explicit allowlists exclude keys, config, grants,
/// schedules, executable artifacts, tool output, local paths, and live agent
/// state. The settings section carries its own schema version and is limited to
/// bounded primitive preference values. User-written text and attachment
/// content may themselves contain secrets; no redaction claimed.
/// Stored ZIP entries only: bounded input is also a bound on decoded memory.
class SettingsBackupService {
  static const maxArchiveBytes = 64 * 1024 * 1024;
  static const maxAttachmentBytes = 8 * 1024 * 1024;
  static const maxManifestBytes = 8 * 1024 * 1024;
  static const maxAttachments = 256;
  static const maxSessions = 1000;
  static const maxMessages = 20000;

  /// Schema version of the optional `settings` manifest section.
  static const settingsSchemaVersion = 1;
  static const maxSettingsKeys = 64;
  static const maxSettingStringLength = 4096;
  static const maxSettingsBytes = 256 * 1024;

  /// Pure preference keys that may travel in a backup, with the only value
  /// type each key may carry. Deliberately excludes sessions, active/session
  /// bootstrap, provider configs and credentials, permission grants, MCP
  /// headers/env, memories, plugins, presets, usage and any device-local path,
  /// repo, branch or model selection.
  static const Map<String, Type> _settingTypes = {
    'ovid_light_theme': bool,
    'ovid_theme_mode': String,
    'ovid_memory_enabled': bool,
    'ovid_show_reasoning': bool,
    'ovid_github_sync': bool,
    'ovid_workflow_enabled': bool,
    'ovid_browser_desktop_mode': bool,
    'ovid_auto_run_safe': bool,
    'ovid_send_while_busy': String,
    'ovid_conversation_display': String,
    'ovid_notifications_enabled': bool,
    'ovid_keep_alive': bool,
    'ovid_locale': String,
    'ovid_welcome': String,
    'ovid_chat_font_scale': double,
    'ovid_response_timeout_sec': int,
    'ovid_context_window_override': int,
    'ovid_max_output_tokens': int,
    'ovid_sandbox_skipped': bool,
    'ovid_share_session_memory': bool,
    'ovid_share_studio_on_restart': bool,
    'ovid_share_browser_on_restart': bool,
    'ovid_control_disclosure_accepted': bool,
    'ovid_control_battery_prompt_shown': bool,
  };

  /// The allowlisted preference keys, derived from the typed schema.
  static final Set<String> settingsAllowlist = _settingTypes.keys.toSet();

  final List<Directory> attachmentRoots;
  final SettingsRestorePublisher? publisher;
  SettingsBackupService({this.attachmentRoots = const [], this.publisher});
  bool get canRestore => publisher != null;

  /// Picks only allowlisted, correctly typed, in-bounds values out of a raw
  /// preference map. Non-allowlisted keys are dropped rather than rejected so
  /// callers can safely pass a full preference snapshot; an allowlisted key
  /// with an invalid value still fails closed.
  static Map<String, Object> captureSettings(Map<String, Object?> source) {
    final picked = <String, Object?>{};
    for (final key in settingsAllowlist) {
      final value = source[key];
      if (value != null) picked[key] = value;
    }
    return Map.unmodifiable(_validatedSettings(picked));
  }

  /// Applies a staged [snapshot] through [write] and restores every touched key
  /// to its [previous] value if any write fails. A null write value removes the
  /// key. The owner must invoke this inside its stop/write barrier so the
  /// settings commit shares the transcript publication's rollback boundary.
  static Future<void> applySettingsAtomically({
    required Map<String, Object?> snapshot,
    required Map<String, Object?> previous,
    required Future<void> Function(String key, Object? value) write,
  }) async {
    final desired = _validatedSettings(snapshot);
    for (final key in previous.keys) {
      if (!settingsAllowlist.contains(key)) {
        throw const FormatException('Previous setting key is not allowlisted.');
      }
    }
    final keys = <String>{...desired.keys, ...previous.keys};
    try {
      for (final key in keys) {
        await write(key, desired[key]);
      }
    } catch (error) {
      Object? rollbackError;
      for (final key in keys) {
        try {
          await write(key, previous[key]);
        } catch (failure) {
          rollbackError ??= failure;
        }
      }
      if (rollbackError != null) {
        throw StateError(
          'Settings restore failed: $error. Rollback failed: $rollbackError',
        );
      }
      rethrow;
    }
  }

  static Object _settingValue(String key, Object? value) {
    final expected = _settingTypes[key];
    if (expected == bool && value is bool) return value;
    if (expected == int && value is int) return value;
    if (expected == double && value is num) {
      final number = value.toDouble();
      if (!number.isFinite) {
        throw const FormatException('Invalid numeric setting.');
      }
      return number;
    }
    if (expected == String && value is String) {
      if (value.length > maxSettingStringLength) {
        throw const FormatException('Setting string exceeds limit.');
      }
      return value;
    }
    throw const FormatException('Unsupported setting value type.');
  }

  static Map<String, Object> _validatedSettings(Map<String, Object?> values) {
    if (values.length > maxSettingsKeys) {
      throw const FormatException('Too many settings.');
    }
    final result = <String, Object>{};
    var bytes = 0;
    for (final entry in values.entries) {
      if (!settingsAllowlist.contains(entry.key)) {
        throw const FormatException('Setting key is not allowlisted.');
      }
      final value = _settingValue(entry.key, entry.value);
      result[entry.key] = value;
      bytes += utf8.encode(entry.key).length + jsonEncode(value).length;
      if (bytes > maxSettingsBytes) {
        throw const FormatException('Settings snapshot exceeds limit.');
      }
    }
    return result;
  }

  Future<Uint8List> export(
    List<ChatSession> sessions, {
    Map<String, Object?> settings = const {},
  }) async {
    if (sessions.length > maxSessions) {
      throw const FormatException('Too many sessions.');
    }
    final validatedSettings = _validatedSettings(settings);
    var messageCount = 0;
    var textBytes = 0;
    for (final session in sessions) {
      for (final message in session.messages) {
        if (message.thinking ||
            ![
              MsgKind.text,
              MsgKind.reasoning,
              MsgKind.compact,
            ].contains(message.kind)) {
          continue;
        }
        if (++messageCount > maxMessages) {
          throw const FormatException('Too many messages.');
        }
        if (message.content.length > 1024 * 1024) {
          throw const FormatException('Message exceeds 1 MiB character limit.');
        }
        textBytes += utf8.encode(message.content).length;
        if (textBytes > maxManifestBytes) {
          throw const FormatException('Transcript text exceeds 8 MiB.');
        }
      }
    }
    // Capture allowlisted values before the first await, independent of later
    // streaming mutations. Never serialize AppState or ChatSession.toJson here.
    final snapshot = [
      for (final s in sessions)
        <String, dynamic>{
          'id': s.id,
          'title': s.title,
          'createdAt': s.createdAt.toIso8601String(),
          'messages': [
            for (final m in s.messages)
              if (!m.thinking &&
                  (m.kind == MsgKind.text ||
                      m.kind == MsgKind.reasoning ||
                      m.kind == MsgKind.compact))
                <String, dynamic>{
                  'role': m.role,
                  'content': m.content,
                  'time': m.time.toIso8601String(),
                  'kind': m.kind.name,
                  'attachments': [
                    for (final a in m.attachments)
                      <String, dynamic>{
                        'name': a.name,
                        'size': a.size,
                        'source': a.path,
                      },
                  ],
                },
          ],
        },
    ];
    final archive = Archive();
    final blobs = <Map<String, dynamic>>[];
    var total = 0;
    var attachmentCount = 0;
    for (final session in snapshot) {
      for (final message in session['messages'] as List) {
        for (final a in message['attachments'] as List) {
          if (++attachmentCount > maxAttachments) {
            throw const FormatException('Too many attachments.');
          }
          final source = a.remove('source') as String?;
          a['status'] = 'unavailable';
          if (source == null) continue;
          final file = File(source);
          try {
            if (await FileSystemEntity.type(source, followLinks: false) !=
                FileSystemEntityType.file) {
              continue;
            }
            final canonical = await file.resolveSymbolicLinks();
            var allowed = false;
            for (final root in attachmentRoots) {
              final base = await root.resolveSymbolicLinks();
              if (canonical.startsWith('$base${Platform.pathSeparator}')) {
                allowed = true;
              }
            }
            if (!allowed) continue;
            final size = await file.length();
            if (size > maxAttachmentBytes) {
              a['status'] = 'tooLarge';
              continue;
            }
            if (total + size >
                maxArchiveBytes - maxManifestBytes - 1024 * 1024) {
              throw const FormatException(
                'Attachment total exceeds archive limit.',
              );
            }
            // Bounded stream handles a file growing after length() as well.
            final builder = BytesBuilder(copy: false);
            await for (final chunk in file.openRead(
              0,
              maxAttachmentBytes + 1,
            )) {
              builder.add(chunk);
            }
            final bytes = builder.takeBytes();
            if (bytes.length > maxAttachmentBytes) {
              a['status'] = 'tooLarge';
              continue;
            }
            final path = 'attachments/${blobs.length}';
            blobs.add({
              'path': path,
              'size': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
            });
            archive.add(ArchiveFile.noCompress(path, bytes.length, bytes));
            total += bytes.length;
            a['status'] = 'included';
            a['size'] = bytes.length;
            a['blob'] = path;
          } on FileSystemException {
            // Missing/unreadable attachments remain explicitly unavailable.
          }
        }
      }
    }
    final manifest = <String, dynamic>{
      'format': 'ovid-transcripts',
      'version': 1,
      'sessions': snapshot,
      'attachments': blobs,
      if (validatedSettings.isNotEmpty)
        'settings': {
          'version': settingsSchemaVersion,
          'values': validatedSettings,
        },
    };
    _validate(manifest, {for (final f in archive) f.name: f.content});
    final json = utf8.encode(jsonEncode(manifest));
    if (json.length > maxManifestBytes) {
      throw const FormatException('Transcript manifest exceeds 8 MiB.');
    }
    archive.add(ArchiveFile.noCompress('manifest.json', json.length, json));
    final result = ZipEncoder().encode(archive);
    if (result.length > maxArchiveBytes) {
      throw const FormatException('Archive exceeds 64 MiB.');
    }
    return Uint8List.fromList(result);
  }

  /// Validation precedes all filesystem writes. The private staging directory
  /// has only generated filenames; archive paths never become filesystem paths.
  Future<StagedSettingsBackup> stage(
    List<int> bytes,
    Directory stagingParent,
  ) async {
    final entries = _readArchive(bytes);
    final manifestBytes = entries.remove('manifest.json');
    if (manifestBytes == null || manifestBytes.length > maxManifestBytes) {
      throw const FormatException('Missing/oversized manifest.');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes));
    } catch (_) {
      throw const FormatException('Invalid manifest JSON.');
    }
    final manifest = _map(decoded);
    _validate(manifest, entries);
    final staging = await stagingParent.createTemp('ovid-restore-');
    try {
      final files = <String, File>{};
      var i = 0;
      for (final entry in entries.entries) {
        final file = File('${staging.path}/${i++}.blob');
        await file.writeAsBytes(entry.value, flush: true);
        files[entry.key] = file;
      }
      final settings = manifest.containsKey('settings')
          ? Map<String, Object>.unmodifiable(
              _validatedSettings(
                _map((manifest['settings'] as Map)['values']),
              ),
            )
          : const <String, Object>{};
      return StagedSettingsBackup._(
        staging,
        (manifest['sessions'] as List).map((s) => _map(s)).toList(),
        files,
        settings,
      );
    } catch (_) {
      await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> restore(List<int> bytes, Directory stagingParent) async {
    final publish = publisher;
    if (publish == null) {
      throw UnsupportedError(
        'Restore unavailable: atomic state publisher is not connected. No data changed.',
      );
    }
    final staged = await stage(bytes, stagingParent);
    try {
      final random = Random.secure();
      final ids = <String, String>{};
      for (final s in staged.sessions) {
        ids[s['id'] as String] =
            'restored-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      }
      await publish(staged, Map.unmodifiable(ids));
    } finally {
      await staged.dispose();
    }
  }

  static Map<String, Uint8List> _readArchive(List<int> bytes) {
    if (bytes.length > maxArchiveBytes || bytes.length < 22) {
      throw const FormatException('Invalid/oversized archive.');
    }
    try {
      final directory = ZipDirectory()..read(InputMemoryStream(bytes));
      if (directory.filePosition < 0 ||
          directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0 ||
          directory.fileHeaders.length !=
              directory.totalCentralDirectoryEntries ||
          directory.fileHeaders.length > maxAttachments + 1) {
        throw const FormatException('Invalid ZIP directory.');
      }
      final result = <String, Uint8List>{};
      var total = 0;
      for (final h in directory.fileHeaders) {
        final f = h.file;
        final name = h.filename;
        final type = (h.externalFileAttributes >> 16) & 0xf000;
        if (f == null ||
            f.filename != name ||
            (name != 'manifest.json' &&
                !RegExp(r'^attachments/[0-9]+$').hasMatch(name)) ||
            result.containsKey(name) ||
            (type != 0 && type != 0x8000) ||
            h.compressionMethod != 0 ||
            f.compressionMethod != CompressionType.none ||
            h.generalPurposeBitFlag & 1 != 0 ||
            f.flags & 1 != 0 ||
            h.compressedSize != h.uncompressedSize ||
            h.uncompressedSize > maxAttachmentBytes ||
            h.diskNumberStart != 0) {
          throw const FormatException(
            'Unsupported or unsafe ZIP entry. Only stored regular files are accepted.',
          );
        }
        total += h.uncompressedSize;
        if (total > maxArchiveBytes) {
          throw const FormatException('Archive content too large.');
        }
        final data = f.getStream().toUint8List();
        if (data.length != h.uncompressedSize || getCrc32(data) != h.crc32) {
          throw const FormatException('Corrupt ZIP entry.');
        }
        result[name] = data;
      }
      return result;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid ZIP archive.');
    }
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected object.');
    }
    return value;
  }

  static void _keys(Map<String, dynamic> value, Set<String> keys) {
    if (value.keys.any((k) => !keys.contains(k))) {
      throw const FormatException('Unknown schema field.');
    }
  }

  static String _string(dynamic value, [int max = 1024 * 1024]) {
    if (value is! String || value.length > max) {
      throw const FormatException('Invalid string.');
    }
    return value;
  }

  static List _list(dynamic value, int max) {
    if (value is! List || value.length > max) {
      throw const FormatException('Invalid list/limit exceeded.');
    }
    return value;
  }

  static void _date(dynamic value) {
    if (DateTime.tryParse(_string(value, 64)) == null) {
      throw const FormatException('Invalid timestamp.');
    }
  }

  static void _validate(Map<String, dynamic> m, Map<String, List<int>> files) {
    _keys(m, {'format', 'version', 'sessions', 'attachments', 'settings'});
    if (m['format'] != 'ovid-transcripts' || m['version'] != 1) {
      throw const FormatException(
        'Unsupported backup format/version. Legacy JSON is export-only.',
      );
    }
    if (m.containsKey('settings')) {
      final settings = _map(m['settings']);
      _keys(settings, {'version', 'values'});
      if (settings['version'] != settingsSchemaVersion) {
        throw const FormatException('Unsupported settings schema version.');
      }
      _validatedSettings(_map(settings['values']));
    }
    final blobs = <String, int>{};
    for (final value in _list(m['attachments'], maxAttachments)) {
      final a = _map(value);
      _keys(a, {'path', 'size', 'sha256'});
      final path = _string(a['path'], 100);
      final data = files[path];
      if (!RegExp(r'^attachments/[0-9]+$').hasMatch(path) ||
          blobs.containsKey(path) ||
          a['size'] is! int ||
          data == null ||
          data.length != a['size'] ||
          data.length > maxAttachmentBytes ||
          sha256.convert(data).toString() != a['sha256']) {
        throw const FormatException('Missing/corrupt/duplicate attachment.');
      }
      blobs[path] = data.length;
    }
    if (files.length != blobs.length) {
      throw const FormatException('Unlisted archive entries.');
    }
    final ids = <String>{};
    final usedBlobs = <String>{};
    var messageCount = 0;
    var attachmentCount = 0;
    for (final value in _list(m['sessions'], maxSessions)) {
      final s = _map(value);
      _keys(s, {'id', 'title', 'createdAt', 'messages'});
      final id = _string(s['id'], 256);
      if (id.isEmpty || !ids.add(id)) {
        throw const FormatException('Empty/duplicate session ID.');
      }
      _string(s['title'], 4096);
      _date(s['createdAt']);
      for (final value in _list(s['messages'], maxMessages)) {
        if (++messageCount > maxMessages) {
          throw const FormatException('Too many messages.');
        }
        final msg = _map(value);
        _keys(msg, {'role', 'kind', 'content', 'time', 'attachments'});
        if (!['user', 'assistant'].contains(msg['role']) ||
            !['text', 'reasoning', 'compact'].contains(msg['kind'])) {
          throw const FormatException('Unsupported message type.');
        }
        _string(msg['content']);
        _date(msg['time']);
        for (final value in _list(msg['attachments'], maxAttachments)) {
          if (++attachmentCount > maxAttachments) {
            throw const FormatException('Too many attachments.');
          }
          final a = _map(value);
          _keys(a, {'name', 'size', 'status', 'blob'});
          _string(a['name'], 1024);
          if (a['size'] is! int || (a['size'] as int) < 0) {
            throw const FormatException('Invalid attachment size.');
          }
          if (a['status'] == 'included') {
            if (a['blob'] is! String || blobs[a['blob']] != a['size']) {
              throw const FormatException('Missing attachment reference.');
            }
            usedBlobs.add(a['blob'] as String);
          } else if (!['unavailable', 'tooLarge'].contains(a['status']) ||
              a.containsKey('blob')) {
            throw const FormatException('Invalid attachment status.');
          }
        }
      }
    }
    if (usedBlobs.length != blobs.length) {
      throw const FormatException('Unreferenced attachment.');
    }
  }
}
