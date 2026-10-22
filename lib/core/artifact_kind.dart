/// The kind of file an artifact is.
///
/// Kept in its own dependency-free file because the chat transcript needs the
/// enum but must not reach `core/session_artifacts.dart`, which imports
/// `core/state.dart` (sqlite3 → `dart:ffi`) and therefore cannot compile for
/// the web gallery.
enum ArtifactKind { image, html, code, document, other }

/// Whether an artifact's bytes are text (so it can be previewed and copied)
/// rather than a binary blob. Pure, so the chat can call it without pulling in
/// the transcript store.
bool artifactIsText(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  const textExtensions = {
    'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'yaml', 'yml', 'xml',
    'html', 'htm', 'css', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'dart',
    'py', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift', 'c', 'h', 'cpp',
    'hpp', 'cs', 'php', 'sh', 'bash', 'zsh', 'sql', 'toml', 'ini', 'env',
    'log', 'svg', 'gradle', 'properties',
  };
  return textExtensions.contains(name.substring(dot + 1).toLowerCase());
}
