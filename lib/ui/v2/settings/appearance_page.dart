import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'settings_rows.dart';

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

/// Theme, text size and voice: one section per choice.
///
/// The page owns a local copy of every choice so the control changes on the
/// same frame it is tapped. The injected callback still performs the real
/// persistence (`AppState.setThemeMode`, …); the local copy is re-synced
/// whenever the parent supplies new data.
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key, required this.data});

  final V2AppearancePageData data;

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  late ThemeMode _theme = widget.data.themeMode;
  late double _textScale = widget.data.resolvedTextScale;
  late String _voiceLanguageId = widget.data.resolvedVoiceLanguageId;

  V2AppearancePageData get data => widget.data;

  @override
  void didUpdateWidget(AppearancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data == widget.data) return;
    _theme = widget.data.themeMode;
    _textScale = widget.data.resolvedTextScale;
    _voiceLanguageId = widget.data.resolvedVoiceLanguageId;
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
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: sections,
      ),
    );
  }

  /// System / Light / Dark as a 3-up row of small preview tiles. The tile
  /// shows the mode instead of naming it again: a framed mini window painted
  /// in the mode's own colours.
  Widget _themeMode(BuildContext context) {
    return OSection(
      title: 'Theme',
      child: Row(
        children: [
          for (final mode in const <ThemeMode>[
            ThemeMode.system,
            ThemeMode.light,
            ThemeMode.dark,
          ])
            Expanded(
              child: Padding(
                padding: mode == ThemeMode.light
                    ? const EdgeInsets.symmetric(horizontal: OSpace.s)
                    : EdgeInsets.zero,
                child: _ThemeTile(
                  mode: mode,
                  label: switch (mode) {
                    ThemeMode.system => 'System',
                    ThemeMode.light => 'Light',
                    ThemeMode.dark => 'Dark',
                  },
                  selected: _theme == mode,
                  enabled: data.onThemeModeChanged != null,
                  onTap: () => _setThemeMode(mode),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _voiceLanguage(BuildContext context) {
    return OSection(
      title: 'Voice',
      child: V2SettingsRowList(
        rows: [
          V2SettingsRow(
            key: const ValueKey<String>('voice-language-row'),
            icon: Icons.mic_none_rounded,
            title: 'Voice language',
            value: data.voiceLanguageLabel,
            onTap: () => _pickVoiceLanguage(context),
          ),
        ],
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


/// One theme choice: a small preview tile painted in the mode's own colours
/// with the label under it. The selected tile carries the accent edge.
class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.mode,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ThemeMode mode;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: '$label theme',
      selected: selected,
      button: true,
      enabled: enabled,
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: OPressable(
          onTap: enabled ? onTap : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: OMotion.fast,
                curve: OMotion.standard,
                height: 72,
                decoration: BoxDecoration(
                  color: selected ? c.accentSoft : c.surface,
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(
                    color: selected ? c.accentFill : c.hairline,
                    width: selected ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _ThemePreview(mode: mode),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: OSpace.touch),
                child: Center(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(
                      color: selected ? c.accent : c.textMuted,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tiny framed window inside a theme tile: a header bar and two text
/// lines in the mode's colours. System splits light and dark down the middle.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.mode});

  final ThemeMode mode;

  // Derived from the design tokens so the tile cannot drift from the theme.
  static final _lightBg = OColors.light.bg;
  static final _lightLine = OColors.light.hairline;
  static final _darkBg = OColors.dark.bg;
  static final _darkLine = OColors.dark.hairline;

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      ThemeMode.light => _frame(_lightBg, _lightLine),
      ThemeMode.dark => _frame(_darkBg, _darkLine),
      ThemeMode.system => Row(
        children: [
          Expanded(child: _frame(_lightBg, _lightLine)),
          Expanded(child: _frame(_darkBg, _darkLine)),
        ],
      ),
    };
  }

  Widget _frame(Color bg, Color line) {
    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(OSpace.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: line,
                borderRadius: BorderRadius.circular(ORadius.xs),
              ),
            ),
            const Spacer(),
            _textLine(line, 0.7),
            const SizedBox(height: OSpace.xs),
            _textLine(line, 0.45),
          ],
        ),
      ),
    );
  }

  Widget _textLine(Color color, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(ORadius.xs),
        ),
      ),
    );
  }
}
