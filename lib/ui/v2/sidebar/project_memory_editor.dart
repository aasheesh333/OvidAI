import 'dart:convert';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

/// Hard cap for one project memory file.
///
/// Memory is read at the start of every chat that belongs to the project, so a
/// file has to stay small enough to load on every run.
const int v2ProjectMemoryMaxBytes = 8 * 1024;

/// Longest accepted file name.
const int v2ProjectMemoryMaxNameLength = 64;

/// A memory file the user is adding or editing. [id] is null for a new file.
@immutable
class V2ProjectMemoryFileDraft {
  const V2ProjectMemoryFileDraft({
    this.id,
    required this.name,
    required this.content,
  });

  final String? id;

  /// Already normalised: a bare name gets the `.md` extension.
  final String name;
  final String content;

  bool get isNew => id == null;
}

/// Injected state for [ProjectMemoryEditorSheet].
@immutable
class V2ProjectMemoryEditorData {
  const V2ProjectMemoryEditorData({
    this.fileId,
    this.name = '',
    this.content = '',
    this.projectName = '',
    this.maxBytes = v2ProjectMemoryMaxBytes,
    this.takenNames = const <String>[],
    this.saving = false,
    this.errorMessage,
  });

  /// Id of the file being edited. Null for a new file.
  final String? fileId;
  final String name;
  final String content;

  /// Shown in the header and the scope note.
  final String projectName;
  final int maxBytes;

  /// Names of the project's other memory files, for the duplicate-name check.
  final List<String> takenNames;
  final bool saving;

  /// A save failure to show above the actions. The typed text stays put.
  final String? errorMessage;

  bool get isNew => fileId == null;

  String get title => isNew ? 'New memory file' : 'Edit memory file';

  String get subtitle {
    final project = projectName.trim();
    final scope = project.isEmpty ? 'Project memory' : project;
    return isNew ? 'New file · $scope' : 'Saved in $scope';
  }
}

/// Editor for one project memory file: file name, Markdown content, the size
/// cap, the project-only note and a confirmed delete.
///
/// The sheet is presentational. Every change leaves through a callback, so the
/// wiring layer owns the write and can keep the sheet open while it saves.
class ProjectMemoryEditorSheet extends StatefulWidget {
  const ProjectMemoryEditorSheet({
    super.key,
    required this.data,
    this.onSave,
    this.onDelete,
    this.onClose,
    this.onRetry,
  });

  final V2ProjectMemoryEditorData data;
  final ValueChanged<V2ProjectMemoryFileDraft>? onSave;

  /// Called with the file id once the user confirms the delete.
  final ValueChanged<String>? onDelete;
  final VoidCallback? onClose;
  final VoidCallback? onRetry;

  @override
  State<ProjectMemoryEditorSheet> createState() =>
      _ProjectMemoryEditorSheetState();
}

class _ProjectMemoryEditorSheetState extends State<ProjectMemoryEditorSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.data.name,
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.data.content,
  );

  /// Name errors stay quiet until the field has been edited, so a new file
  /// does not open already shouting at the user.
  bool _nameTouched = false;

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  int get _bytes => utf8.encode(_content.text).length;

  int get _maxBytes =>
      widget.data.maxBytes > 0 ? widget.data.maxBytes : v2ProjectMemoryMaxBytes;

  bool get _overCap => _bytes > _maxBytes;

  String? get _nameError => _validateName(_name.text);

  bool get _canSave =>
      _nameError == null && _content.text.trim().isNotEmpty && !_overCap;

  String? _validateName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return 'Add a file name.';
    if (name.length > v2ProjectMemoryMaxNameLength) {
      return 'Keep the name under $v2ProjectMemoryMaxNameLength characters.';
    }
    if (name.contains('/') || name.contains('\\')) {
      return 'File names cannot contain a slash.';
    }
    final effective = _normaliseName(name).toLowerCase();
    final taken = widget.data.takenNames
        .map((other) => other.trim().toLowerCase())
        .toSet();
    if (taken.contains(effective)) {
      return 'This project already has a file with that name.';
    }
    return null;
  }

  /// A name without an extension becomes a Markdown file, which is the only
  /// kind of memory file the project keeps.
  static String _normaliseName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return '';
    final lastDot = name.lastIndexOf('.');
    final lastSlash = name.lastIndexOf('/');
    return lastDot > lastSlash + 1 ? name : '$name.md';
  }

  /// Why the save action is unavailable, in plain words. Also used as the
  /// disabled button's semantic label so the reason is announced.
  String? get _blockedReason {
    if (_nameError != null) {
      return _name.text.trim().isEmpty
          ? 'Add a file name to save.'
          : _nameError;
    }
    if (_content.text.trim().isEmpty) {
      return 'Add something for Ovid to remember.';
    }
    if (_overCap) {
      return 'Trim the file below the ${_formatSize(_maxBytes)} cap.';
    }
    return null;
  }

  void _save() {
    if (!_canSave || widget.onSave == null) return;
    widget.onSave!(
      V2ProjectMemoryFileDraft(
        id: widget.data.fileId,
        name: _normaliseName(_name.text),
        content: _content.text,
      ),
    );
    Navigator.maybePop(context);
  }

  void _close() {
    widget.onClose?.call();
    Navigator.maybePop(context);
  }

  Future<void> _confirmDelete() async {
    final id = widget.data.fileId;
    final delete = widget.onDelete;
    if (id == null || delete == null) return;
    final project = widget.data.projectName.trim();
    final scope = project.isEmpty ? 'this project' : project;
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Delete memory file?',
      builder: (sheetContext) => _DeleteConfirm(
        fileName: widget.data.name.isEmpty
            ? _normaliseName(_name.text)
            : widget.data.name,
        scope: scope,
        onConfirm: () => Navigator.pop<bool>(sheetContext, true),
        onCancel: () => Navigator.pop<bool>(sheetContext, false),
      ),
    );
    if (!mounted || confirmed != true) return;
    delete(id);
    if (mounted) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final saving = data.saving;
    final canSave = _canSave && !saving && widget.onSave != null;
    final normalised = _normaliseName(_name.text);
    final showSavedAs =
        _name.text.trim().isNotEmpty && normalised != _name.text.trim();
    final saveLabel = saving
        ? 'Saving memory file'
        : canSave
        ? 'Save memory file'
        : 'Save memory file, unavailable. '
              '${_blockedReason ?? 'Editing is disabled.'}';
    return Material(
      key: const Key('v2-memory-editor-sheet'),
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.m,
                  OSpace.l,
                  OSpace.l,
                ),
                child: OFadeSlide(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Header(data: data, onClose: _close),
                      const SizedBox(height: OSpace.l),
                      TextField(
                        key: const Key('v2-memory-editor-name'),
                        controller: _name,
                        enabled: !saving,
                        autofocus: data.isNew,
                        maxLength: v2ProjectMemoryMaxNameLength,
                        textCapitalization: TextCapitalization.none,
                        textInputAction: TextInputAction.next,
                        style: OType.bodySm.copyWith(color: c.text),
                        onChanged: (_) => setState(() => _nameTouched = true),
                        decoration: InputDecoration(
                          labelText: 'File name',
                          hintText: 'e.g. brand-voice.md',
                          errorText: _nameTouched ? _nameError : null,
                          helperText: showSavedAs
                              ? 'Saved as $normalised'
                              : null,
                        ),
                      ),
                      const SizedBox(height: OSpace.m),
                      TextField(
                        key: const Key('v2-memory-editor-content'),
                        controller: _content,
                        enabled: !saving,
                        minLines: 8,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        style: OType.mono.copyWith(color: c.text, height: 1.5),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Content',
                          hintText:
                              'Facts, rules and preferences Ovid should keep.',
                          hintStyle: OType.mono.copyWith(color: c.textFaint),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: OSpace.m),
                      const _ScopeNote(),
                      const SizedBox(height: OSpace.m),
                      _SizeNote(used: _bytes, max: _maxBytes, over: _overCap),
                      if (data.errorMessage != null) ...[
                        const SizedBox(height: OSpace.m),
                        _ErrorBanner(
                          message: data.errorMessage!,
                          onRetry: widget.onRetry,
                        ),
                      ],
                      const SizedBox(height: OSpace.l),
                      OButton(
                        key: const Key('v2-memory-editor-save'),
                        label: saving
                            ? 'Saving…'
                            : data.isNew
                            ? 'Save memory file'
                            : 'Save changes',
                        icon: Icons.check_rounded,
                        expand: true,
                        loading: saving,
                        semanticLabel: saveLabel,
                        onPressed: canSave ? _save : null,
                      ),
                      if (!saving &&
                          _blockedReason != null &&
                          !(_nameTouched && _nameError != null)) ...[
                        const SizedBox(height: OSpace.s),
                        Text(
                          _blockedReason!,
                          key: const Key('v2-memory-editor-save-hint'),
                          textAlign: TextAlign.center,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                      if (!data.isNew && widget.onDelete != null) ...[
                        const SizedBox(height: OSpace.l),
                        Divider(color: c.hairline, height: 1),
                        const SizedBox(height: OSpace.l),
                        OButton(
                          key: const Key('v2-memory-editor-delete'),
                          label: 'Delete memory file',
                          icon: Icons.delete_outline_rounded,
                          variant: OButtonVariant.danger,
                          expand: true,
                          onPressed: saving ? null : _confirmDelete,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.data, required this.onClose});

  final V2ProjectMemoryEditorData data;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(data.title, style: OType.h2.copyWith(color: c.text)),
              const SizedBox(height: 2),
              Text(
                data.subtitle,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(width: OSpace.s),
        OIconButton(
          icon: Icons.close_rounded,
          semanticLabel: 'Close memory editor',
          onPressed: onClose,
        ),
      ],
    );
  }
}

/// Reminds the user that facts in this file do not travel to other projects.
class _ScopeNote extends StatelessWidget {
  const _ScopeNote();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.accent),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              'This memory is used only in this project. Chats in other '
              'projects cannot read it.',
              key: const Key('v2-memory-editor-scope-note'),
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live size readout plus the cap. Turns into an actionable warning once the
/// file is too big to save.
class _SizeNote extends StatelessWidget {
  const _SizeNote({required this.used, required this.max, required this.over});

  final int used;
  final int max;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fraction = max <= 0 ? 1.0 : (used / max).clamp(0.0, 1.0);
    final tone = over ? c.danger : c.textMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.data_usage_rounded, size: 16, color: tone),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                '${_formatSize(used)} of ${_formatSize(max)} used',
                style: OType.caption.copyWith(color: tone),
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.xs),
        Semantics(
          label: 'File size ${_formatSize(used)} of ${_formatSize(max)}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: c.surfaceRaised,
              color: over ? c.danger : c.accentFill,
            ),
          ),
        ),
        const SizedBox(height: OSpace.xs),
        Text(
          over
              ? '${_formatSize(used - max)} over the ${_formatSize(max)} cap. '
                    'Trim the file to save it.'
              : 'Memory files are capped at ${_formatSize(max)} so every chat '
                    'in the project can read them.',
          key: const Key('v2-memory-editor-size-note'),
          style: OType.caption.copyWith(color: over ? c.danger : c.textFaint),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const Key('v2-memory-editor-error'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.danger),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: OType.caption.copyWith(color: c.text)),
                if (onRetry != null) ...[
                  const SizedBox(height: OSpace.xs),
                  OButton(
                    label: 'Try again',
                    variant: OButtonVariant.ghost,
                    size: OButtonSize.compact,
                    onPressed: onRetry,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Second step of a delete: names the file, the project and the consequence.
class _DeleteConfirm extends StatelessWidget {
  const _DeleteConfirm({
    required this.fileName,
    required this.scope,
    required this.onConfirm,
    required this.onCancel,
  });

  final String fileName;
  final String scope;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '"$fileName" will be removed from $scope memory. Other projects '
            'keep their own memory. This cannot be undone.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            key: const Key('v2-memory-editor-delete-confirm'),
            label: 'Delete file',
            icon: Icons.delete_outline_rounded,
            variant: OButtonVariant.dangerFill,
            expand: true,
            onPressed: onConfirm,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            key: const Key('v2-memory-editor-delete-cancel'),
            label: 'Keep file',
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Formats bytes for the size note: `640 bytes`, `3.2 KB`, `8 KB`.
String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes ${bytes == 1 ? 'byte' : 'bytes'}';
  final kb = bytes / 1024;
  final rounded = kb == kb.roundToDouble()
      ? kb.toStringAsFixed(0)
      : kb.toStringAsFixed(1);
  return '$rounded KB';
}

/// Opens [ProjectMemoryEditorSheet] in the shared bottom sheet container.
Future<void> showProjectMemoryEditor(
  BuildContext context, {
  required V2ProjectMemoryEditorData data,
  ValueChanged<V2ProjectMemoryFileDraft>? onSave,
  ValueChanged<String>? onDelete,
  VoidCallback? onClose,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (_) => ProjectMemoryEditorSheet(
      data: data,
      onSave: onSave,
      onDelete: onDelete,
      onClose: onClose,
      onRetry: onRetry,
    ),
  );
}
