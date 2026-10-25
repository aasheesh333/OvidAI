import 'package:file_picker/file_picker.dart';

import '../core/collaboration/production.dart';

const maxCollaborationAttachmentBytes = 25000000;
const maxCollaborationAttachments = 5;

/// Selects real bytes for the canonical Collab upload pipeline. Paths are not
/// retained or uploaded. The server validates/finalizes the actual object.
Future<List<CollaborationAttachmentInput>?> pickCollaborationAttachments() async {
  final picked = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: true,
  );
  if (picked == null) return null;
  if (picked.files.length > maxCollaborationAttachments) {
    throw StateError('Choose up to $maxCollaborationAttachments files.');
  }
  return [
    for (final file in picked.files)
      CollaborationAttachmentInput(
        name: file.name,
        bytes: _bytes(file),
        contentType: collaborationAttachmentContentType(file.name),
      ),
  ];
}

List<int> _bytes(PlatformFile file) {
  final bytes = file.bytes;
  if (bytes == null) {
    throw StateError('${file.name} could not be read. Choose a local file.');
  }
  if (bytes.isEmpty) {
    throw StateError('${file.name} is empty.');
  }
  if (bytes.length > maxCollaborationAttachmentBytes) {
    throw StateError('${file.name} is larger than 25 MB.');
  }
  return List<int>.unmodifiable(bytes);
}

String collaborationAttachmentContentType(String name) {
  final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (extension) {
    'txt' || 'md' || 'markdown' || 'csv' || 'log' => 'text/plain',
    'json' || 'jsonl' => 'application/json',
    'xml' => 'application/xml',
    'yaml' || 'yml' => 'application/yaml',
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'html' || 'htm' => 'text/html',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}
