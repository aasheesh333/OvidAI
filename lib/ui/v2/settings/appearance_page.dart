import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Text-size scale: 75 % → 180 % in 5 % steps (21 divisions).
const double _textScaleMin = 0.75;
const double _textScaleMax = 1.8;
const int _textScaleDivisions = 21;

const String _sampleText = 'The quick brown fox jumps over the lazy dog.';

/// Persisted "reduce motion" preference.
///
/// Motion is a device preference, so it is stored next to the other device
/// preferences rather than on the account. The page reads it when it mounts
/// (so the choice survives a restart) and writes it on every toggle. A write
/// that returns `false` throws, which is what lets the screen roll the switch
/// back instead of showing a state that was never saved.
abstract final class V2MotionPreference {
  static const String key = 'ovid_reduce_motion';

  static Future<bool> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? false;
  }

  static Future<void> write(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setBool(key, value);
    if (!saved) throw StateError('Could not persist $key');
  }
}

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
/// One page owns how Ovid looks (theme, text size, motion, voice). Every
/// callback is the persistence seam: it is awaited so a failed write can be
/// rolled back and reported. A `null` callback means the control has no
/// service behind it and is therefore not drawn.
@immutable
class V2AppearancePageData {
  const V2AppearancePageData({
    this.themeMode = ThemeMode.system,
    this.textScale = 1,
    this.reduceMotion = false,
    this.voiceLanguageId = '',
    this.memoryEnabled = true,
    this.shareSessionMemory = false,
    this.showReasoning = true,
    this.preview,
    this.loading = false,
    this.errorMessage,
    this.onThemeModeChanged,
    this.onTextScaleChanged,
    this.onReduceMotionChanged,
    this.onVoiceLanguageChanged,
    this.onMemoryEnabledChanged,
    this.onShareSessionMemoryChanged,
    this.onShowReasoningChanged,
    this.onMemoryFilesTap,
    this.onRetry,
  });

  final ThemeMode themeMode;
  final double textScale;

  /// Injected motion state. The page prefers this when a callback is supplied
  /// and otherwise reads [V2MotionPreference] itself.
  final bool reduceMotion;

  /// Voice input language id (`en`, `hi`, `hinglish`, `pa`, `ta`), or an empty
  /// string when the person has not chosen one. An unset value is never shown
  /// as if it were a choice.
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

  /// Persistence seams. Each may complete asynchronously and may throw; the
  /// page then restores the previous value and reports the failure.
  final FutureOr<void> Function(ThemeMode)? onThemeModeChanged;
  final FutureOr<void> Function(double)? onTextScaleChanged;
  final FutureOr<void> Function(bool)? onReduceMotionChanged;
  final FutureOr<void> Function(String)? onVoiceLanguageChanged;
  final FutureOr<void> Function(bool)? onMemoryEnabledChanged;
  final FutureOr<void> Function(bool)? onShareSessionMemoryChanged;
  final FutureOr<void> Function(bool)? onShowReasoningChanged;

  /// Opens the Memory files screen, where each file can be edited.
  final VoidCallback? onMemoryFilesTap;
  final VoidCallback? onRetry;

  double get resolvedTextScale {
    if (!textScale.isFinite) return 1;
    return textScale.clamp(_textScaleMin, _textScaleMax).toDouble();
  }

  /// The chosen voice language, or `null` when nothing has been chosen yet.
  String? get resolvedVoiceLanguageId =>
      _voiceLanguageIds.contains(voiceLanguageId) ? voiceLanguageId : null;

  String? get voiceLanguageLabel =>
      _voiceLanguageLabels[resolvedVoiceLanguageId];
}

/// Theme, text size, voice and motion: one section per choice.
///
/// The page owns a local copy of every choice so the control changes on the
/// same frame it is tapped. The injected callback still performs the real
/// persistence (`AppState.setThemeMode`, …); if it fails the local copy rolls
/// back and the page says which choice was not saved.
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key, required this.data});

  final V2AppearancePageData data;

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  late ThemeMode _theme;
  late double _textScale;
  late String? _voiceLanguageId;
  late bool _reduceMotion;

  /// The motion preference is read from disk before the page draws a choice;
  /// until it resolves the page stays in its loading state.
  bool _motionLoaded = false;

  /// The last failed write, shown above the sections until it is retried.
  String? _saveError;
  VoidCallback? _retrySave;

  /// The value the current text-size drag started from, so a failed write
  /// restores the size the person had before the drag, not the last tick.
  double? _textBaseline;

  // Each control keeps its own generation so a slow failed write cannot
  // revert a newer choice the person has already made.
  int _themeSaves = 0;
  int _textSaves = 0;
  int _voiceSaves = 0;
  int _motionSaves = 0;

  V2AppearancePageData get data => widget.data;

  @override
  void initState() {
    super.initState();
    _adopt(widget.data);
    unawaited(_loadMotion());
  }

  @override
  void didUpdateWidget(AppearancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.data, widget.data)) return;
    final previous = oldWidget.data;
    final next = widget.data;
    // Adopt only fields the parent actually changed. A rebuild for an
    // unrelated reason must not undo an optimistic choice that is still being
    // written.
    if (next.themeMode != previous.themeMode) _theme = next.themeMode;
    if (next.resolvedTextScale != previous.resolvedTextScale) {
      _textScale = next.resolvedTextScale;
    }
    if (next.resolvedVoiceLanguageId != previous.resolvedVoiceLanguageId) {
      _voiceLanguageId = next.resolvedVoiceLanguageId;
    }
    // Without an injected seam the page's own store stays authoritative: a
    // parent rebuild must not reset a preference the page just saved.
    if (next.onReduceMotionChanged != null &&
        next.reduceMotion != previous.reduceMotion) {
      _reduceMotion = next.reduceMotion;
    }
    if (next.onReduceMotionChanged != null) _motionLoaded = true;
  }

  void _adopt(V2AppearancePageData next) {
    _theme = next.themeMode;
    _textScale = next.resolvedTextScale;
    _voiceLanguageId = next.resolvedVoiceLanguageId;
    _reduceMotion = next.reduceMotion;
  }

  Future<void> _loadMotion() async {
    if (data.onReduceMotionChanged != null) {
      _motionLoaded = true;
      return;
    }
    var value = false;
    try {
      value = await V2MotionPreference.read();
    } catch (_) {
      // A missing or unreadable preference means "no preference": motion
      // stays on. The toggle can still write a real value.
    }
    if (!mounted) return;
    setState(() {
      _reduceMotion = value;
      _motionLoaded = true;
    });
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    final changed = data.onThemeModeChanged;
    if (changed == null || mode == _theme) return;
    final previous = _theme;
    setState(() {
      _theme = mode;
      _saveError = null;
      _retrySave = null;
    });
    final token = ++_themeSaves;
    try {
      await changed(mode);
      if (mounted && token == _themeSaves) _clearError('Theme not saved.');
    } catch (_) {
      if (!mounted || token != _themeSaves) return;
      setState(() => _theme = previous);
      _report('Theme not saved.', () => _setThemeMode(mode));
    }
  }

  Future<void> _setTextScale(double value) async {
    final changed = data.onTextScaleChanged;
    if (changed == null) return;
    final next = value.clamp(_textScaleMin, _textScaleMax).toDouble();
    if ((next - _textScale).abs() < 0.001) return;
    _textBaseline ??= _textScale;
    setState(() {
      _textScale = next;
      _saveError = null;
      _retrySave = null;
    });
    final token = ++_textSaves;
    try {
      await changed(next);
      if (mounted && token == _textSaves) {
        _textBaseline = null;
        _clearError('Text size not saved.');
      }
    } catch (_) {
      if (!mounted || token != _textSaves) return;
      final restore = _textBaseline ?? _textScale;
      _textBaseline = null;
      setState(() => _textScale = restore);
      _report('Text size not saved.', () => _setTextScale(next));
    }
  }

  Future<void> _setVoiceLanguage(String id) async {
    final changed = data.onVoiceLanguageChanged;
    if (changed == null || id == _voiceLanguageId) return;
    final previous = _voiceLanguageId;
    setState(() {
      _voiceLanguageId = id;
      _saveError = null;
      _retrySave = null;
    });
    final token = ++_voiceSaves;
    try {
      await changed(id);
      if (mounted && token == _voiceSaves) {
        _clearError('Voice language not saved.');
      }
    } catch (_) {
      if (!mounted || token != _voiceSaves) return;
      setState(() => _voiceLanguageId = previous);
      _report('Voice language not saved.', () => _setVoiceLanguage(id));
    }
  }

  Future<void> _setReduceMotion(bool value) async {
    if (value == _reduceMotion) return;
    final previous = _reduceMotion;
    setState(() {
      _reduceMotion = value;
      _saveError = null;
      _retrySave = null;
    });
    final token = ++_motionSaves;
    try {
      final changed = data.onReduceMotionChanged;
      if (changed != null) {
        await changed(value);
      } else {
        await V2MotionPreference.write(value);
      }
      if (mounted && token == _motionSaves) _clearError('Motion not saved.');
    } catch (_) {
      if (!mounted || token != _motionSaves) return;
      setState(() => _reduceMotion = previous);
      _report('Motion not saved.', () => _setReduceMotion(value));
    }
  }

  void _report(String message, VoidCallback retry) {
    if (!mounted) return;
    setState(() {
      _saveError = message;
      _retrySave = retry;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Clears the banner only when it belongs to [message]; a success in one
  /// section must not hide another section's failure.
  void _clearError([String? message]) {
    if (!mounted || _saveError == null) return;
    if (message != null && _saveError != message) return;
    setState(() {
      _saveError = null;
      _retrySave = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final systemReduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final status = data.loading || !_motionLoaded
        ? OStatus.loading
        : data.errorMessage != null
        ? OStatus.error
        : OStatus.content;
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: _reduceMotion || systemReduced),
      child: OScreen(
        title: 'Appearance',
        // A settings page keeps the tablet line length at 640 even on a wide
        // window: more room becomes margin, not a longer row.
        maxWidth: 640,
        child: OStateView(
          status: status,
          errorMessage: data.errorMessage,
          onRetry: data.onRetry,
          skeletonRows: 6,
          child: _content(context),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final sections = <Widget>[
      if (_saveError != null) _saveBanner(context),
      _themeMode(context),
      _textSize(context),
      if (data.onVoiceLanguageChanged != null) _voiceLanguage(context),
      _motion(context),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: sections,
      ),
    );
  }

  Widget _saveBanner(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Container(
        key: const ValueKey<String>('appearance-save-error'),
        padding: const EdgeInsets.fromLTRB(
          OSpace.m,
          OSpace.s,
          OSpace.s,
          OSpace.s,
        ),
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.danger.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 18, color: c.danger),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                _saveError!,
                style: OType.bodySm.copyWith(color: c.text),
              ),
            ),
            if (_retrySave != null)
              OTextAction(label: 'Retry', onPressed: _retrySave),
          ],
        ),
      ),
    );
  }

  /// System / Light / Dark as a 3-up radio group of small preview tiles. The
  /// tile shows the mode instead of naming it again: a framed mini window
  /// painted in the mode's own colours.
  Widget _themeMode(BuildContext context) {
    const modes = <ThemeMode>[
      ThemeMode.system,
      ThemeMode.light,
      ThemeMode.dark,
    ];
    final enabled = data.onThemeModeChanged != null;
    return OSection(
      title: 'Theme',
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'Theme',
        child: Row(
          children: [
            for (var index = 0; index < modes.length; index++) ...[
              if (index > 0) const SizedBox(width: OSpace.s),
              Expanded(
                child: _ThemeTile(
                  key: ValueKey<String>(
                    'appearance-theme-${modes[index].name}',
                  ),
                  mode: modes[index],
                  label: switch (modes[index]) {
                    ThemeMode.system => 'System',
                    ThemeMode.light => 'Light',
                    ThemeMode.dark => 'Dark',
                  },
                  selected: _theme == modes[index],
                  enabled: enabled,
                  onTap: () => _setThemeMode(modes[index]),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _textSize(BuildContext context) {
    final c = OColors.of(context);
    final percent = (_textScale * 100).round();
    final canChange = data.onTextScaleChanged != null;
    return OSection(
      title: 'Text size',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: MergeSemantics(
                  child: Semantics(
                    label: 'Text size',
                    child: Slider(
                      key: const ValueKey<String>('appearance-text-scale'),
                      value: _textScale,
                      min: _textScaleMin,
                      max: _textScaleMax,
                      divisions: _textScaleDivisions,
                      semanticFormatterCallback: (value) =>
                          '${(value * 100).round()}%',
                      activeColor: c.accentFill,
                      inactiveColor: c.surfaceRaised,
                      thumbColor: c.accentFill,
                      onChanged: canChange ? _setTextScale : null,
                    ),
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
          const SizedBox(height: OSpace.s),
          _textPreview(context),
        ],
      ),
    );
  }

  /// A sample line drawn at the chosen size, so the slider has a visible
  /// result before it is released. The card scales with the preference and
  /// with the system setting, and is hidden from screen readers: the size is
  /// already announced by the slider.
  Widget _textPreview(BuildContext context) {
    final c = OColors.of(context);
    final systemScale = MediaQuery.textScalerOf(context).scale(1);
    final sample = data.preview?.assistantMessage.trim();
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey<String>('appearance-text-preview'),
        width: double.infinity,
        padding: const EdgeInsets.all(OSpace.m),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.hairline),
        ),
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(systemScale * _textScale)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Aa', style: OType.h3.copyWith(color: c.text)),
              const SizedBox(height: OSpace.xs),
              Text(
                sample == null || sample.isEmpty ? _sampleText : sample,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _motion(BuildContext context) {
    final c = OColors.of(context);
    return OSection(
      title: 'Motion',
      child: V2SettingsRowList(
        rows: [
          V2SettingsRow(
            key: const ValueKey<String>('appearance-reduce-motion'),
            icon: Icons.animation_rounded,
            title: 'Reduce motion',
            subtitle: 'Fewer animations',
            showChevron: false,
            onTap: () => _setReduceMotion(!_reduceMotion),
            trailing: Semantics(
              label: 'Reduce motion',
              toggled: _reduceMotion,
              enabled: true,
              onTap: () => _setReduceMotion(!_reduceMotion),
              child: ExcludeSemantics(
                child: Switch(
                  key: const ValueKey<String>(
                    'appearance-reduce-motion-switch',
                  ),
                  value: _reduceMotion,
                  onChanged: _setReduceMotion,
                  activeThumbColor: c.onAccent,
                  activeTrackColor: c.accentFill,
                  inactiveThumbColor: c.textFaint,
                  inactiveTrackColor: c.surfaceRaised,
                  trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
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
            subtitle: 'Dictation only',
            value: _voiceLanguageLabels[_voiceLanguageId] ?? 'Not set',
            stacksTrailing: true,
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
      builder: (sheetContext) =>
          _VoiceLanguageSheet(selectedId: _voiceLanguageId),
    );
    if (chosen != null && mounted) await _setVoiceLanguage(chosen);
  }
}

/// Language picker for dictation. One row per supported language; the chosen
/// row is the only one that announces itself as selected.
class _VoiceLanguageSheet extends StatelessWidget {
  const _VoiceLanguageSheet({required this.selectedId});

  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final id in _voiceLanguageIds)
            _VoiceLanguageRow(
              key: ValueKey<String>('voice-language-$id'),
              label: _voiceLanguageLabels[id] ?? id,
              selected: id == selectedId,
              onTap: () => Navigator.of(context).pop(id),
            ),
        ],
      ),
    );
  }
}

class _VoiceLanguageRow extends StatelessWidget {
  const _VoiceLanguageRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: OListRow(
          title: label,
          showChevron: false,
          padding: const EdgeInsets.symmetric(vertical: OSpace.m),
          trailing: selected
              ? Icon(Icons.check_rounded, size: 20, color: c.accent)
              : null,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// One theme choice: a small preview tile painted in the mode's own colours
/// with the label under it. The selected tile carries the accent edge and is
/// the checked member of the radio group.
class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    super.key,
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
      inMutuallyExclusiveGroup: true,
      checked: selected,
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
                duration: OMove.duration(context, OMotion.fast),
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
                  // At 320 dp / 200 % text three labels cannot all keep their
                  // full size in a 90 dp tile. Scale the label down just
                  // enough to stay whole: an ellipsized "Syst…" is worse than
                  // a slightly smaller word, and the radio group is still
                  // announced at the system size.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: OType.caption.copyWith(
                        color: selected ? c.accent : c.textMuted,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
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
