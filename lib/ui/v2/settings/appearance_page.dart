import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

const List<String> _voiceLanguageIds = <String>[
  'en',
  'hi',
  'hinglish',
  'pa',
  'ta',
];

const Map<String, String> _voiceLanguageLabels = <String, String>{
  'en': 'English',
  'hi': 'हिन्दी',
  'hinglish': 'Hinglish',
  'pa': 'ਪੰਜਾਬੀ',
  'ta': 'தமிழ்',
};

/// A tiny chat used by the live preview card.
@immutable
class V2AppearancePreview {
  const V2AppearancePreview({
    required this.sessionLabel,
    required this.statusLabel,
    required this.userMessage,
    required this.assistantMessage,
    this.composerHint = 'Ask a follow-up question…',
  });

  final String sessionLabel;
  final String statusLabel;
  final String userMessage;
  final String assistantMessage;
  final String composerHint;
}

/// Injected state for the Appearance screen.
///
/// One page owns how Ovid looks (theme, text size, voice), what it remembers
/// and how much it shows. Accent, density and code-font controls were removed:
/// they had no persisted state.
@immutable
class V2AppearancePageData {
  const V2AppearancePageData({
    this.themeMode = ThemeMode.system,
    this.textScale = 1,
    this.reduceMotion = false,
    this.reduceMotionFollowsSystem = true,
    this.highContrast = false,
    this.voiceLanguageId = 'en',
    this.memoryEnabled = true,
    this.shareSessionMemory = false,
    this.showReasoning = true,
    this.preview,
    this.loading = false,
    this.errorMessage,
    this.onThemeModeChanged,
    this.onTextScaleChanged,
    this.onReduceMotionChanged,
    this.onReduceMotionFollowsSystemChanged,
    this.onHighContrastChanged,
    this.onVoiceLanguageChanged,
    this.onMemoryEnabledChanged,
    this.onShareSessionMemoryChanged,
    this.onShowReasoningChanged,
    this.onMemoryFilesTap,
    this.onPreviewSend,
    this.onRefreshPreview,
    this.onRetry,
  });

  final ThemeMode themeMode;
  final double textScale;
  final bool reduceMotion;
  final bool reduceMotionFollowsSystem;
  final bool highContrast;

  /// Voice input language id (`en`, `hi`, `hinglish`, `pa`, `ta`).
  final String voiceLanguageId;

  /// Whether Ovid keeps facts between chats. On by default.
  final bool memoryEnabled;

  /// Whether this chat's memory may be reused by projects and shared chats.
  /// Off by default: a new chat is private until the user opts in.
  final bool shareSessionMemory;

  /// Whether thinking steps are shown above answers. On by default.
  final bool showReasoning;

  final V2AppearancePreview? preview;
  final bool loading;
  final String? errorMessage;

  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final ValueChanged<double>? onTextScaleChanged;
  final ValueChanged<bool>? onReduceMotionChanged;
  final ValueChanged<bool>? onReduceMotionFollowsSystemChanged;
  final ValueChanged<bool>? onHighContrastChanged;
  final ValueChanged<String>? onVoiceLanguageChanged;
  final ValueChanged<bool>? onMemoryEnabledChanged;
  final ValueChanged<bool>? onShareSessionMemoryChanged;
  final ValueChanged<bool>? onShowReasoningChanged;

  /// Opens the Memory files screen, where each file can be edited.
  final VoidCallback? onMemoryFilesTap;
  final VoidCallback? onPreviewSend;
  final VoidCallback? onRefreshPreview;
  final VoidCallback? onRetry;

  double get resolvedTextScale => textScale.clamp(0.75, 1.8).toDouble();

  String get resolvedVoiceLanguageId =>
      _voiceLanguageIds.contains(voiceLanguageId) ? voiceLanguageId : 'en';

  String get voiceLanguageLabel =>
      _voiceLanguageLabels[resolvedVoiceLanguageId] ?? 'English';
}

/// Theme, text size, voice, memory and motion: one line per choice.
///
/// The page owns a local copy of every choice so the control changes on the
/// same frame it is tapped. The injected callback still performs the real
/// persistence (`AppState.setThemeMode`, `AppState.setMemoryEnabled`, …); the
/// local copy is re-synced whenever the parent supplies new data.
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key, required this.data});

  final V2AppearancePageData data;

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  late ThemeMode _theme = widget.data.themeMode;
  late double _textScale = widget.data.resolvedTextScale;
  late bool _reduceMotion = widget.data.reduceMotion;
  late bool _followsSystem = widget.data.reduceMotionFollowsSystem;
  late bool _highContrast = widget.data.highContrast;
  late String _voiceLanguageId = widget.data.resolvedVoiceLanguageId;
  late bool _memoryEnabled = widget.data.memoryEnabled;
  late bool _shareSessionMemory = widget.data.shareSessionMemory;
  late bool _showReasoning = widget.data.showReasoning;

  V2AppearancePageData get data => widget.data;

  @override
  void didUpdateWidget(AppearancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data == widget.data) return;
    _theme = widget.data.themeMode;
    _textScale = widget.data.resolvedTextScale;
    _reduceMotion = widget.data.reduceMotion;
    _followsSystem = widget.data.reduceMotionFollowsSystem;
    _highContrast = widget.data.highContrast;
    _voiceLanguageId = widget.data.resolvedVoiceLanguageId;
    _memoryEnabled = widget.data.memoryEnabled;
    _shareSessionMemory = widget.data.shareSessionMemory;
    _showReasoning = widget.data.showReasoning;
  }

  void _setThemeMode(ThemeMode mode) {
    final changed = data.onThemeModeChanged;
    if (changed == null || mode == _theme) return;
    setState(() => _theme = mode);
    changed(mode);
  }

  void _setTextScale(double value) {
    final changed = data.onTextScaleChanged;
    if (changed == null) return;
    setState(() => _textScale = value.clamp(0.75, 1.8).toDouble());
    changed(value);
  }

  void _setVoiceLanguage(String id) {
    final changed = data.onVoiceLanguageChanged;
    if (changed == null || id == _voiceLanguageId) return;
    setState(() => _voiceLanguageId = id);
    changed(id);
  }

  void _setMemoryEnabled(bool value) {
    final changed = data.onMemoryEnabledChanged;
    if (changed == null) return;
    setState(() => _memoryEnabled = value);
    changed(value);
  }

  void _setShareSessionMemory(bool value) {
    final changed = data.onShareSessionMemoryChanged;
    if (changed == null) return;
    setState(() => _shareSessionMemory = value);
    changed(value);
  }

  void _setShowReasoning(bool value) {
    final changed = data.onShowReasoningChanged;
    if (changed == null) return;
    setState(() => _showReasoning = value);
    changed(value);
  }

  void _setFollowsSystem(bool value) {
    final changed = data.onReduceMotionFollowsSystemChanged;
    if (changed == null) return;
    setState(() {
      _followsSystem = value;
      if (value) _reduceMotion = true;
    });
    changed(value);
  }

  void _setReduceMotion(bool value) {
    final changed = data.onReduceMotionChanged;
    if (changed == null || _followsSystem) return;
    setState(() => _reduceMotion = value);
    changed(value);
  }

  void _setHighContrast(bool value) {
    final changed = data.onHighContrastChanged;
    if (changed == null) return;
    setState(() => _highContrast = value);
    changed(value);
  }

  bool get _hasMemoryHandlers =>
      data.onMemoryEnabledChanged != null ||
      data.onShareSessionMemoryChanged != null ||
      data.onMemoryFilesTap != null;

  bool get _hasMotionHandlers =>
      data.onReduceMotionChanged != null ||
      data.onReduceMotionFollowsSystemChanged != null ||
      data.onHighContrastChanged != null;

  @override
  Widget build(BuildContext context) {
    final status = data.loading
        ? OStatus.loading
        : data.errorMessage != null
        ? OStatus.error
        : OStatus.content;
    return OScreen(
      title: 'Appearance',
      child: OStateView(
        status: status,
        errorMessage: data.errorMessage,
        onRetry: data.onRetry,
        skeletonRows: 6,
        child: _content(context),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final sections = <Widget>[
      _themeMode(context),
      _textSize(context),
      if (data.onVoiceLanguageChanged != null) _voiceLanguage(context),
      if (_hasMemoryHandlers) _memory(context),
      if (data.onShowReasoningChanged != null) _chat(context),
      if (_hasMotionHandlers) _motion(context),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: sections,
      ),
    );
  }

  Widget _themeMode(BuildContext context) {
    return OSection(
      title: 'Theme',
      child: OCard(
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            for (final mode in const <ThemeMode>[
              ThemeMode.system,
              ThemeMode.light,
              ThemeMode.dark,
            ])
              Expanded(
                child: _themeChoice(context, mode, switch (mode) {
                  ThemeMode.system => 'System',
                  ThemeMode.light => 'Light',
                  ThemeMode.dark => 'Dark',
                }),
              ),
          ],
        ),
      ),
    );
  }

  Widget _themeChoice(BuildContext context, ThemeMode mode, String label) {
    final c = OColors.of(context);
    final selected = _theme == mode;
    final enabled = data.onThemeModeChanged != null;
    return Semantics(
      label: '$label theme',
      selected: selected,
      button: true,
      enabled: enabled,
      onTap: enabled ? () => _setThemeMode(mode) : null,
      child: ExcludeSemantics(
        child: OPressable(
          onTap: enabled ? () => _setThemeMode(mode) : null,
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.s,
              vertical: OSpace.m,
            ),
            decoration: BoxDecoration(
              color: selected ? c.accentSoft : null,
              borderRadius: BorderRadius.circular(ORadius.l),
              border: Border.all(
                color: selected ? c.accentFill : Colors.transparent,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(
                      color: selected ? c.accent : c.textMuted,
                    ),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: OSpace.xs),
                  Icon(Icons.check_rounded, size: 16, color: c.accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _voiceLanguage(BuildContext context) {
    return OSection(
      title: 'Voice',
      child: OCard(
        padding: EdgeInsets.zero,
        child: OListRow(
          key: const ValueKey<String>('voice-language-row'),
          title: 'Voice language',
          subtitle: data.voiceLanguageLabel,
          onTap: () => _pickVoiceLanguage(context),
        ),
      ),
    );
  }

  Future<void> _pickVoiceLanguage(BuildContext context) async {
    final chosen = await showOSheet<String>(
      context,
      title: 'Voice language',
      builder: (sheetContext) => _VoiceLanguageSheet(
        selectedId: _voiceLanguageId,
      ),
    );
    if (chosen != null && mounted) _setVoiceLanguage(chosen);
  }

  Widget _textSize(BuildContext context) {
    final c = OColors.of(context);
    final percent = (_textScale * 100).round();
    return OSection(
      title: 'Text size',
      child: OCard(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.s,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                label: 'Chat text size',
                value: '$percent%',
                child: Slider(
                  value: _textScale,
                  min: 0.75,
                  max: 1.8,
                  divisions: 21,
                  label: '$percent%',
                  activeColor: c.accentFill,
                  inactiveColor: c.surfaceRaised,
                  thumbColor: c.accentFill,
                  onChanged: data.onTextScaleChanged == null
                      ? null
                      : _setTextScale,
                ),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Text(
              '$percent%',
              maxLines: 1,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _memory(BuildContext context) {
    return OSection(
      title: 'Memory',
      child: OCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            if (data.onMemoryEnabledChanged != null)
              _toggleRow(
                context,
                title: 'Global memory',
                value: _memoryEnabled,
                onChanged: _setMemoryEnabled,
                switchKey: const ValueKey<String>('global-memory-switch'),
              ),
            if (data.onMemoryEnabledChanged != null &&
                data.onShareSessionMemoryChanged != null)
              _divider(context),
            if (data.onShareSessionMemoryChanged != null)
              _toggleRow(
                context,
                title: 'Share session memory',
                value: _shareSessionMemory,
                onChanged: _setShareSessionMemory,
                switchKey: const ValueKey<String>(
                  'share-session-memory-switch',
                ),
              ),
            if (data.onMemoryFilesTap != null &&
                (data.onMemoryEnabledChanged != null ||
                    data.onShareSessionMemoryChanged != null))
              _divider(context),
            if (data.onMemoryFilesTap != null)
              OListRow(
                key: const ValueKey<String>('memory-files-row'),
                title: 'Memory files',
                onTap: data.onMemoryFilesTap,
              ),
          ],
        ),
      ),
    );
  }

  Widget _chat(BuildContext context) {
    return OSection(
      title: 'Chat',
      child: OCard(
        padding: EdgeInsets.zero,
        child: _toggleRow(
          context,
          title: 'Show reasoning',
          value: _showReasoning,
          onChanged: _setShowReasoning,
          switchKey: const ValueKey<String>('show-reasoning-switch'),
        ),
      ),
    );
  }

  Widget _motion(BuildContext context) {
    return OSection(
      title: 'Motion',
      child: OCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            if (data.onReduceMotionChanged != null) ...[
              _toggleRow(
                context,
                title: 'Reduce motion',
                value: _reduceMotion,
                onChanged: _followsSystem ? null : _setReduceMotion,
                switchKey: const ValueKey<String>('reduce-motion-switch'),
              ),
              _divider(context),
            ],
            if (data.onReduceMotionFollowsSystemChanged != null) ...[
              _toggleRow(
                context,
                title: 'Follow device setting',
                value: _followsSystem,
                onChanged: _setFollowsSystem,
                switchKey: const ValueKey<String>('follow-device-switch'),
              ),
              if (data.onHighContrastChanged != null) _divider(context),
            ],
            if (data.onHighContrastChanged != null)
              _toggleRow(
                context,
                title: 'High contrast',
                value: _highContrast,
                onChanged: _setHighContrast,
                switchKey: const ValueKey<String>('high-contrast-switch'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _divider(BuildContext context) =>
      Divider(height: 1, color: OColors.of(context).hairline);

  Widget _toggleRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required Key switchKey,
  }) {
    final c = OColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.s,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.body.copyWith(
                  color: onChanged == null ? c.textFaint : c.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Semantics(
              label: title,
              toggled: value,
              enabled: onChanged != null,
              child: Switch(
                key: switchKey,
                value: value,
                onChanged: onChanged,
                activeThumbColor: c.onAccent,
                activeTrackColor: c.accentFill,
                inactiveThumbColor: c.textFaint,
                inactiveTrackColor: c.surfaceRaised,
                trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Language picker for dictation. One row per supported language.
class _VoiceLanguageSheet extends StatelessWidget {
  const _VoiceLanguageSheet({required this.selectedId});

  final String selectedId;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final id in _voiceLanguageIds)
            OListRow(
              key: ValueKey<String>('voice-language-$id'),
              title: _voiceLanguageLabels[id] ?? id,
              showChevron: false,
              trailing: id == selectedId
                  ? Icon(Icons.check_rounded, size: 20, color: c.accent)
                  : null,
              onTap: () => Navigator.of(context).pop(id),
            ),
        ],
      ),
    );
  }
}

