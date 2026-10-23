import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// One file staged in the composer.
@immutable
class V2ComposerAttachment {
  const V2ComposerAttachment({
    required this.name,
    required this.path,
    required this.size,
  });

  final String name;

  /// Absolute path handed to `runTask(attachments:)`. Empty when the picker
  /// could not expose a readable path (e.g. a cloud-only provider).
  final String path;
  final int size;

  String get sizeLabel => formatV2AttachmentSize(size);

  bool get isReadable => path.trim().isNotEmpty;

  bool sameFile(V2ComposerAttachment other) =>
      path == other.path && name == other.name && size == other.size;
}

/// Human size for a chip: `820 B`, `14.2 KB`, `3.4 MB`.
String formatV2AttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Picker seam. Returns null when the user cancelled.
typedef V2AttachmentPicker = Future<List<V2ComposerAttachment>?> Function();

/// Image-only picker seam for the composer's Photo row.
typedef V2ImagePicker = Future<List<V2ComposerAttachment>?> Function();

Future<List<V2ComposerAttachment>?> _pick({required FileType type}) async {
  final result = await FilePicker.platform.pickFiles(
    type: type,
    allowMultiple: true,
    withData: false,
  );
  if (result == null) return null;
  return [
    for (final file in result.files)
      V2ComposerAttachment(
        name: file.name,
        path: file.path ?? '',
        size: file.size,
      ),
  ];
}

/// Production picker: any file, multiple selection, no bytes loaded.
///
/// The rules below decide what is accepted so the composer can explain a
/// rejection instead of silently dropping the file.
Future<List<V2ComposerAttachment>?> pickV2AttachmentFiles() =>
    _pick(type: FileType.any);

/// Production image picker used by the composer's Photo action. The system
/// photo picker owns the library permission, so no extra prompt is needed.
Future<List<V2ComposerAttachment>?> pickV2ImageFiles() =>
    _pick(type: FileType.image);

/// Limits for one message.
abstract final class V2AttachmentRules {
  static const int maxFiles = 5;
  static const int maxBytes = 8 * 1024 * 1024;

  /// Documents, code and images the agent can read. Executables and unknown
  /// binaries are rejected with a clear message.
  static const Set<String> allowedExtensions = {
    'pdf',
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'json',
    'jsonl',
    'xml',
    'yaml',
    'yml',
    'toml',
    'ini',
    'log',
    'doc',
    'docx',
    'rtf',
    'odt',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'dart',
    'py',
    'js',
    'jsx',
    'ts',
    'tsx',
    'html',
    'htm',
    'css',
    'scss',
    'sql',
    'sh',
    'bash',
    'zsh',
    'java',
    'kt',
    'kts',
    'swift',
    'c',
    'h',
    'cpp',
    'cc',
    'hpp',
    'cs',
    'go',
    'rs',
    'rb',
    'php',
    'lua',
    'r',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'svg',
    'bmp',
    'heic',
  };

  static String? rejectionFor(V2ComposerAttachment file) {
    if (!file.isReadable) {
      return 'Could not read ${file.name}. Try another file.';
    }
    if (file.size > maxBytes) {
      return '${file.name} is larger than 8 MB.';
    }
    final extension = _extensionOf(file.name);
    if (extension.isEmpty || !allowedExtensions.contains(extension)) {
      return '${file.name}: that file type is not supported.';
    }
    return null;
  }

  /// Applies the limits to a picker result and returns what may be staged.
  static V2AttachmentBatch accept({
    required List<V2ComposerAttachment> existing,
    required List<V2ComposerAttachment> incoming,
  }) {
    final accepted = <V2ComposerAttachment>[];
    final rejected = <String>[];
    final staged = <V2ComposerAttachment>[...existing];
    for (final file in incoming) {
      if (staged.length >= maxFiles) {
        const message = 'You can attach up to 5 files.';
        if (!rejected.contains(message)) rejected.add(message);
        continue;
      }
      if (staged.any((row) => row.sameFile(file))) {
        rejected.add('${file.name} is already attached.');
        continue;
      }
      final rejection = rejectionFor(file);
      if (rejection != null) {
        rejected.add(rejection);
        continue;
      }
      staged.add(file);
      accepted.add(file);
    }
    return V2AttachmentBatch(accepted: accepted, rejected: rejected);
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}

/// Result of applying [V2AttachmentRules.accept].
@immutable
class V2AttachmentBatch {
  const V2AttachmentBatch({required this.accepted, required this.rejected});

  final List<V2ComposerAttachment> accepted;

  /// Human-readable reasons, in picker order.
  final List<String> rejected;

  bool get hasRejections => rejected.isNotEmpty;

  /// One line for the composer notice.
  String? get message {
    if (rejected.isEmpty) return null;
    if (rejected.length == 1) return rejected.first;
    return '${rejected.length} files were skipped. ${rejected.first}';
  }
}

/// Staged files above the composer row: one line each, name, size, ✕.
class V2AttachmentChips extends StatelessWidget {
  const V2AttachmentChips({
    super.key,
    required this.attachments,
    required this.onRemove,
    this.enabled = true,
  });

  final List<V2ComposerAttachment> attachments;
  final ValueChanged<V2ComposerAttachment> onRemove;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < attachments.length; i++) ...[
            if (i > 0) const SizedBox(height: OSpace.xs),
            _AttachmentRow(
              key: ValueKey(
                'attachment-${attachments[i].path}-${attachments[i].name}',
              ),
              attachment: attachments[i],
              enabled: enabled,
              onRemove: () => onRemove(attachments[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    super.key,
    required this.attachment,
    required this.enabled,
    required this.onRemove,
  });

  final V2ComposerAttachment attachment;
  final bool enabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      label: 'Attachment ${attachment.name}, ${attachment.sizeLabel}',
      child: Container(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.hairline),
        ),
        child: Row(
          children: [
            const SizedBox(width: OSpace.m),
            Icon(Icons.attach_file_rounded, size: 18, color: c.accent),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                attachment.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.label.copyWith(color: c.text),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Text(
              attachment.sizeLabel,
              maxLines: 1,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
            IconButton(
              onPressed: enabled ? onRemove : null,
              tooltip: 'Remove ${attachment.name}',
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: OSpace.touch,
                minHeight: OSpace.touch,
              ),
              icon: Icon(Icons.close_rounded, color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline composer error with a live-region announcement.
/// The Studio folder gate (spec Screen 2): a required, tappable row above the
/// composer.
///
/// It is a real control, not a dead label — tapping it opens the repo picker.
/// When the host cannot route to Studio the row still explains the block, so a
/// disabled send button is never unexplained.
class V2StudioFolderGate extends StatelessWidget {
  const V2StudioFolderGate({
    super.key,
    required this.onTap,
    this.hasHandler = true,
  });

  final VoidCallback? onTap;

  /// False when the host has no Studio route: the row stays explanatory.
  final bool hasHandler;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xs),
      child: Semantics(
        button: hasHandler,
        container: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('composer-studio-folder'),
            onTap: hasHandler ? onTap : null,
            borderRadius: BorderRadius.circular(ORadius.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ORadius.pill),
                border: Border.all(color: c.hairline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_outlined, size: 16, color: c.textMuted),
                  const SizedBox(width: OSpace.xs),
                  Flexible(
                    child: Text(
                      'Select repo / folder to use Studio',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class V2ComposerNotice extends StatelessWidget {
  const V2ComposerNotice({
    super.key,
    required this.message,
    this.icon = Icons.error_outline_rounded,
    this.danger = true,
  });

  final String message;
  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final tone = danger ? c.danger : c.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xs),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: message,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: tone),
            const SizedBox(width: OSpace.xs),
            Expanded(
              child: Text(message, style: OType.caption.copyWith(color: tone)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single message's staged files plus the ids the draft references.
@immutable
class V2ComposerSubmission {
  const V2ComposerSubmission({
    required this.text,
    this.attachments = const [],
    this.sessionRefs = const [],
    this.projectRefs = const [],
  });

  final String text;
  final List<V2ComposerAttachment> attachments;
  final List<String> sessionRefs;
  final List<String> projectRefs;

  bool get isEmpty => text.trim().isEmpty && attachments.isEmpty;

  /// Shape expected by `CloudAgentFacade.runTask(attachments:)`.
  List<({String name, String path, int size})> get runTaskAttachments => [
    for (final file in attachments)
      (name: file.name, path: file.path, size: file.size),
  ];
}
