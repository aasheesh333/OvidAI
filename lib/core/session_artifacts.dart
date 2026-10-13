import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';
import 'html_artifact.dart';
import 'state.dart';

/// Where an artifact came from: a file the user attached to a message, or a
/// file/image/page Ovid produced during a run.
enum ArtifactOrigin { uploaded, generated }

/// Coarse type used for the icon, the preview route and the filters.
enum ArtifactKind { image, html, code, document, other }

/// One entry of the Artifacts screen and of the in-chat artifact cards.
///
/// Artifacts are DERIVED from the persisted transcript — user attachments,
/// generated-image rows, inline HTML artifacts and successful file-writing
/// tool rows — so they survive restarts without a second store that could
/// drift from the chat history.
@immutable
class SessionArtifact {
  const SessionArtifact({
    required this.id,
    required this.name,
    required this.sessionId,
    required this.sessionTitle,
    required this.time,
    required this.origin,
    required this.kind,
    this.path,
    this.size,
    this.html,
    this.toolName,
  });

  /// Stable across rebuilds and restarts (used by "Remove from list").
  final String id;
  final String name;

  /// Absolute host path, or a workspace-relative path for tool-written files.
  /// Null for inline HTML artifacts.
  final String? path;
  final String sessionId;
  final String sessionTitle;
  final DateTime time;
  final ArtifactOrigin origin;
  final ArtifactKind kind;
  final int? size;
  final HtmlArtifact? html;

  /// The tool that produced a generated file (`file_write`, `fs_edit`, …).
  final String? toolName;

  bool get isAbsolute => path != null && path!.startsWith('/');

  @override
  bool operator ==(Object other) =>
      other is SessionArtifact &&
      other.id == id &&
      other.time == time &&
      other.size == size;

  @override
  int get hashCode => Object.hash(id, time, size);
}

const _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'svg'};
const _htmlExt = {'html', 'htm'};
const _codeExt = {
  'dart',
  'js',
  'mjs',
  'cjs',
  'ts',
  'tsx',
  'jsx',
  'py',
  'java',
  'kt',
  'kts',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'rs',
  'go',
  'rb',
  'php',
  'swift',
  'm',
  'sh',
  'bash',
  'zsh',
  'ps1',
  'json',
  'yaml',
  'yml',
  'toml',
  'xml',
  'css',
  'scss',
  'sql',
  'gradle',
  'lua',
  'r',
  'scala',
  'vue',
  'svelte',
  'ini',
  'env',
  'dockerfile',
  'makefile',
  'proto',
};
const _docExt = {
  'md',
  'markdown',
  'txt',
  'pdf',
  'doc',
  'docx',
  'odt',
  'rtf',
  'csv',
  'tsv',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'log',
  'tex',
  'epub',
};

/// Lower-case extension of [name] (`''` when it has none).
String artifactExtension(String name) {
  final base = name.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return base.toLowerCase();
  return base.substring(dot + 1).toLowerCase();
}

ArtifactKind artifactKindFor(String name) {
  final ext = artifactExtension(name);
  if (_imageExt.contains(ext)) return ArtifactKind.image;
  if (_htmlExt.contains(ext)) return ArtifactKind.html;
  if (_codeExt.contains(ext)) return ArtifactKind.code;
  if (_docExt.contains(ext)) return ArtifactKind.document;
  return ArtifactKind.other;
}

/// True for text the preview can show inline (code, markdown, csv, html …).
bool artifactIsText(String name) {
  final ext = artifactExtension(name);
  if (_codeExt.contains(ext) || _htmlExt.contains(ext)) return true;
  return const {
    'md',
    'markdown',
    'txt',
    'csv',
    'tsv',
    'log',
    'tex',
    'svg',
  }.contains(ext);
}

/// Tools whose successful run leaves a file in the workspace.
const fileWritingTools = {
  'file_write',
  'fs_edit',
  'multi_edit',
  'notebook_edit',
};

/// The `path` recorded in a tool row's compact input JSON, if any.
String? toolInputPath(String? toolInput) {
  final raw = toolInput?.trim();
  if (raw == null || raw.isEmpty || !raw.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    for (final key in const ['path', 'file']) {
      final v = decoded[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
  } catch (e) {
    Diag.swallow('session_artifacts.toolInputPath', e);
  }
  return null;
}

String _base(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// The file a successful file-writing tool row produced, or null.
SessionArtifact? generatedFileArtifactOf(
  Message m, {
  required String sessionId,
  required String sessionTitle,
}) {
  if (m.kind != MsgKind.tool || m.toolState != 'ok') return null;
  if (!fileWritingTools.contains(m.toolName)) return null;
  final path = toolInputPath(m.toolInput);
  if (path == null) return null;
  return SessionArtifact(
    id: '$sessionId:gen:$path',
    name: _base(path),
    path: path,
    sessionId: sessionId,
    sessionTitle: sessionTitle,
    time: m.time,
    origin: ArtifactOrigin.generated,
    kind: artifactKindFor(path),
    toolName: m.toolName,
  );
}

/// Every artifact in [sessions], newest first.
///
/// A file written several times in one session appears once (its latest
/// write), so a long edit loop does not flood the list.
List<SessionArtifact> collectSessionArtifacts(Iterable<ChatSession> sessions) {
  final out = <SessionArtifact>[];
  for (final s in sessions) {
    final generated = <String, SessionArtifact>{};
    final msgs = s.messages;
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.role == 'user') {
        for (var a = 0; a < m.attachments.length; a++) {
          final att = m.attachments[a];
          out.add(
            SessionArtifact(
              id: '${s.id}:up:${m.privateSyncId}:$a',
              name: att.name,
              path: att.path,
              size: att.size,
              sessionId: s.id,
              sessionTitle: s.title,
              time: m.time,
              origin: ArtifactOrigin.uploaded,
              kind: artifactKindFor(att.name),
            ),
          );
        }
        continue;
      }
      switch (m.kind) {
        case MsgKind.imageGen when (m.imagePath ?? '').isNotEmpty:
          out.add(
            SessionArtifact(
              id: '${s.id}:img:${m.privateSyncId}',
              name: _base(m.imagePath!),
              path: m.imagePath,
              sessionId: s.id,
              sessionTitle: s.title,
              time: m.time,
              origin: ArtifactOrigin.generated,
              kind: ArtifactKind.image,
            ),
          );
        case MsgKind.htmlArtifact when m.htmlArtifact != null:
          final h = m.htmlArtifact!;
          out.add(
            SessionArtifact(
              id: '${s.id}:html:${h.id}',
              name: h.title,
              sessionId: s.id,
              sessionTitle: s.title,
              time: m.time,
              origin: ArtifactOrigin.generated,
              kind: ArtifactKind.html,
              html: h,
            ),
          );
        case MsgKind.tool:
          final g = generatedFileArtifactOf(
            m,
            sessionId: s.id,
            sessionTitle: s.title,
          );
          if (g != null) generated[g.id] = g;
        default:
          break;
      }
    }
    out.addAll(generated.values);
  }
  out.sort((a, b) => b.time.compareTo(a.time));
  return out;
}

/// Artifacts the user removed from the Artifacts list. Removing only hides
/// the entry; the file and the chat message stay untouched.
class ArtifactListPrefs {
  ArtifactListPrefs._();
  static final ArtifactListPrefs I = ArtifactListPrefs._();

  static const _key = 'artifacts.hidden.v1';

  /// Bounded so a heavy user cannot grow the preference without limit.
  static const _max = 2000;

  final ValueNotifier<Set<String>> hidden = ValueNotifier(const {});
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      hidden.value = {...?prefs.getStringList(_key)};
    } catch (e) {
      Diag.swallow('artifacts.prefs.load', e);
    }
  }

  Future<void> hide(String id) => _write({...hidden.value, id});

  Future<void> unhide(String id) => _write({...hidden.value}..remove(id));

  Future<void> _write(Set<String> next) async {
    final trimmed = next.length > _max
        ? next.skip(next.length - _max).toSet()
        : next;
    hidden.value = trimmed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, trimmed.toList());
    } catch (e) {
      Diag.swallow('artifacts.prefs.write', e);
    }
  }

  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    hidden.value = const {};
  }
}
