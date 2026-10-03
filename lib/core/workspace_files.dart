import 'dart:io';

/// Resolve a file under an existing workspace. Refuse symlink components,
/// including dangling links and links in not-yet-created parent paths.
/// Returning the canonical root also supports a user-selected root symlink.
String? workspaceFilePath(Directory workspace, String path) {
  if (path.trim().isEmpty) return null;
  String normalize(String value) {
    final parts = <String>[];
    for (final part in value.split('/')) {
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (part.isNotEmpty && part != '.') {
        parts.add(part);
      }
    }
    return '/${parts.join('/')}';
  }
  final root = normalize(workspace.absolute.path);
  final target = normalize(path.startsWith('/') ? path : '$root/$path');
  final prefix = root == '/' ? root : '$root/';
  if (!target.startsWith(prefix) || target == root) return null;
  final canonical = workspace.resolveSymbolicLinksSync();
  var current = canonical;
  for (final segment in target.substring(prefix.length).split('/')) {
    current = '$current/$segment';
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
  }
  return current;
}
