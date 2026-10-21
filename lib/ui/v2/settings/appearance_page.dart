import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

const List<String> _accentIds = <String>['violet', 'blue', 'green', 'amber'];
const List<String> _accentLabels = <String>['Violet', 'Blue', 'Green', 'Amber'];
const List<String> _densityIds = <String>['comfortable', 'compact'];
const List<String> _codeFontIds = <String>['jetbrains', 'system', 'fira'];
const List<String> _voiceLanguageIds = <String>[
  'en',
  'hi',
  'hinglish',
  'pa',
  'ta',
];
const List<String> _voiceLanguageLabels = <String>[
  'English',
  'Hindi',
  'Hinglish',
  'Punjabi',
  'Tamil',
];

String _densityLabel(String id) => id == 'compact' ? 'Compact' : 'Comfortable';

String _codeFontLabel(String id) => switch (id) {
  'system' => 'System mono',
  'fira' => 'Fira Code',
  _ => 'JetBrains Mono',
};

String _codeFontFamily(String id) => switch (id) {
  'system' => 'monospace',
  'fira' => 'FiraCode',
  _ => 'JetBrainsMono',
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
@immutable
class V2AppearancePageData {
  const V2AppearancePageData({
    this.themeMode = ThemeMode.system,
    this.accentId = 'violet',
    this.textScale = 1,
    this.reduceMotion = false,
    this.reduceMotionFollowsSystem = true,
    this.highContrast = false,
    this.densityId = 'comfortable',
    this.codeFontId = 'jetbrains',
    this.voiceLanguageId = 'en',
    this.preview,
    this.loading = false,
    this.errorMessage,
    this.onThemeModeChanged,
    this.onAccentChanged,
    this.onTextScaleChanged,
    this.onReduceMotionChanged,
    this.onReduceMotionFollowsSystemChanged,
    this.onHighContrastChanged,
    this.onDensityChanged,
    this.onCodeFontChanged,
    this.onVoiceLanguageChanged,
    this.onPreviewSend,
    this.onRefreshPreview,
    this.onRetry,
  });

  final ThemeMode themeMode;
  final String accentId;
  final double textScale;
  final bool reduceMotion;
  final bool reduceMotionFollowsSystem;
  final bool highContrast;
  final String densityId;
  final String codeFontId;

  /// Voice input language id (`en`, `hi`, `hinglish`, `pa`, `ta`).
  final String voiceLanguageId;

  final V2AppearancePreview? preview;
  final bool loading;
  final String? errorMessage;

  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final ValueChanged<String>? onAccentChanged;
  final ValueChanged<double>? onTextScaleChanged;
  final ValueChanged<bool>? onReduceMotionChanged;
  final ValueChanged<bool>? onReduceMotionFollowsSystemChanged;
  final ValueChanged<bool>? onHighContrastChanged;
  final ValueChanged<String>? onDensityChanged;
  final ValueChanged<String>? onCodeFontChanged;
  final ValueChanged<String>? onVoiceLanguageChanged;
  final VoidCallback? onPreviewSend;
  final VoidCallback? onRefreshPreview;
  final VoidCallback? onRetry;

  String get resolvedAccentId =>
      _accentIds.contains(accentId) ? accentId : 'violet';

  double get resolvedTextScale => textScale.clamp(0.75, 1.8).toDouble();

  String get resolvedDensityId =>
      _densityIds.contains(densityId) ? densityId : 'comfortable';

  String get resolvedCodeFontId =>
      _codeFontIds.contains(codeFontId) ? codeFontId : 'jetbrains';

  String get resolvedVoiceLanguageId =>
      _voiceLanguageIds.contains(voiceLanguageId) ? voiceLanguageId : 'en';
}

/// Theme, accent, text size and accessibility settings with a live preview.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, required this.data});

  final V2AppearancePageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Appearance'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 6));
    }
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.l,
          OSpace.screen,
          OSpace.xxl,
        ),
        child: OStagger(
          children: [
            _themeMode(context),
            _accentColor(context),
            _textSize(context),
            _chatLayout(context),
            _voiceLanguage(context),
            _accessibility(context),
            _livePreview(context),
            _deviceNote(context),
          ],
        ),
      ),
    );
  }

  Widget _themeMode(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Theme mode',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          SizedBox(
            height: 120,
            child: Row(
              children: [
                _themeCard(context, ThemeMode.system, 'System'),
                const SizedBox(width: OSpace.s),
                _themeCard(context, ThemeMode.light, 'Light'),
                const SizedBox(width: OSpace.s),
                _themeCard(context, ThemeMode.dark, 'Dark'),
              ],
            ),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            'System follows your device setting and is the default.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _themeCard(BuildContext context, ThemeMode mode, String label) {
    final c = OColors.of(context);
    final selected = data.themeMode == mode;
    return Expanded(
      child: Semantics(
        label: '$label theme',
        selected: selected,
        button: true,
        enabled: data.onThemeModeChanged != null,
        onTap: data.onThemeModeChanged == null
            ? null
            : () => data.onThemeModeChanged!(mode),
        child: ExcludeSemantics(
          child: OPressable(
            onTap: data.onThemeModeChanged == null
                ? null
                : () => data.onThemeModeChanged!(mode),
            child: AnimatedContainer(
              duration: OMotion.fast,
              curve: OMotion.standard,
              padding: const EdgeInsets.all(OSpace.s),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(ORadius.l),
                border: Border.all(
                  color: selected ? c.accentFill : c.hairline,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _themeThumb(mode),
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: OType.label.copyWith(color: c.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 16,
                          color: c.accentFill,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _themeThumb(ThemeMode mode) {
    if (mode == ThemeMode.system) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(ORadius.s),
        child: const SizedBox(
          height: 58,
          child: Row(
            children: [
              Expanded(child: _ThemeThumbPanel(colors: OColors.light)),
              Expanded(child: _ThemeThumbPanel(colors: OColors.dark)),
            ],
          ),
        ),
      );
    }
    final colors = mode == ThemeMode.light ? OColors.light : OColors.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(ORadius.s),
      child: SizedBox(height: 58, child: _ThemeThumbPanel(colors: colors)),
    );
  }

  Widget _accentColor(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    'Accent color',
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Flexible(
                  flex: 2,
                  child: Text(
                    'Applied system-wide',
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.m),
            Row(
              children: [
                for (var i = 0; i < _accentIds.length; i++)
                  Expanded(
                    child: Center(
                      child: _accentDot(
                        context,
                        id: _accentIds[i],
                        label: _accentLabels[i],
                        color: _accentFor(c, _accentIds[i]),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _accentDot(
    BuildContext context, {
    required String id,
    required String label,
    required Color color,
  }) {
    final c = OColors.of(context);
    final selected = data.resolvedAccentId == id;
    return Semantics(
      key: ValueKey<String>('accent-$id'),
      label: '$label accent',
      selected: selected,
      button: true,
      enabled: data.onAccentChanged != null,
      onTap: data.onAccentChanged == null
          ? null
          : () => data.onAccentChanged!(id),
      child: OPressable(
        onTap: data.onAccentChanged == null
            ? null
            : () => data.onAccentChanged!(id),
        child: Container(
          width: OSpace.touch,
          height: OSpace.touch,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selected ? color : c.surface, width: 2),
          ),
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: selected
                ? Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check_rounded, size: 15, color: c.text),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _textSize(BuildContext context) {
    final c = OColors.of(context);
    final percent = (data.resolvedTextScale * 100).round();
    final label = percent == 100 ? 'Default (100%)' : '$percent%';
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Text size',
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.s),
            Row(
              children: [
                Text('A', style: OType.caption.copyWith(color: c.textMuted)),
                Expanded(
                  child: Semantics(
                    label: 'Text size',
                    value: '$percent%',
                    child: SizedBox(
                      height: OSpace.touch,
                      child: Slider(
                        value: data.resolvedTextScale,
                        min: 0.75,
                        max: 1.8,
                        divisions: 21,
                        label: '$percent%',
                        activeColor: c.accentFill,
                        inactiveColor: c.surfaceRaised,
                        thumbColor: c.accentFill,
                        onChanged: data.onTextScaleChanged,
                      ),
                    ),
                  ),
                ),
                Text('A', style: OType.h2.copyWith(color: c.text)),
              ],
            ),
            const SizedBox(height: OSpace.xs),
            Text(
              'Smaller 75% · Larger 180%',
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chatLayout(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Chat layout',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Density',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'How much space each chat row uses.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.s),
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (final id in _densityIds)
                      _settingChoice(
                        context,
                        key: ValueKey<String>('density-$id'),
                        label: _densityLabel(id),
                        selected: data.resolvedDensityId == id,
                        onTap: data.onDensityChanged == null
                            ? null
                            : () => data.onDensityChanged!(id),
                      ),
                  ],
                ),
                const SizedBox(height: OSpace.l),
                Divider(color: c.hairline, height: 1),
                const SizedBox(height: OSpace.l),
                Text(
                  'Code font',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Used for code blocks and files.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.s),
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (final id in _codeFontIds)
                      _settingChoice(
                        context,
                        key: ValueKey<String>('code-font-$id'),
                        label: _codeFontLabel(id),
                        selected: data.resolvedCodeFontId == id,
                        onTap: data.onCodeFontChanged == null
                            ? null
                            : () => data.onCodeFontChanged!(id),
                      ),
                  ],
                ),
                const SizedBox(height: OSpace.m),
                Container(
                  padding: const EdgeInsets.all(OSpace.m),
                  decoration: BoxDecoration(
                    color: c.codeBg,
                    borderRadius: BorderRadius.circular(ORadius.m),
                    border: Border.all(color: c.hairline),
                  ),
                  child: Text(
                    'const answer = 42;',
                    style: OType.mono.copyWith(
                      color: c.text,
                      fontFamily: _codeFontFamily(data.resolvedCodeFontId),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _voiceLanguage(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Voice input',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Voice language',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Used when you dictate a message with the microphone.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.s),
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (var i = 0; i < _voiceLanguageIds.length; i++)
                      _settingChoice(
                        context,
                        key: ValueKey<String>(
                          'voice-language-${_voiceLanguageIds[i]}',
                        ),
                        label: _voiceLanguageLabels[i],
                        selected:
                            data.resolvedVoiceLanguageId ==
                            _voiceLanguageIds[i],
                        onTap: data.onVoiceLanguageChanged == null
                            ? null
                            : () => data.onVoiceLanguageChanged!(
                                _voiceLanguageIds[i],
                              ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingChoice(
    BuildContext context, {
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final c = OColors.of(context);
    return Semantics(
      key: key,
      label: label,
      selected: selected,
      button: true,
      enabled: onTap != null,
      onTap: onTap,
      child: ExcludeSemantics(
        child: OPressable(
          onTap: onTap,
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: OSpace.xs,
            ),
            decoration: BoxDecoration(
              color: selected ? c.accentSoft : c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(
                color: selected ? c.accentFill : c.hairline,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
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

  Widget _accessibility(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Accessibility & motion',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _toggleTile(
                  context,
                  title: 'Reduce motion',
                  subtitle: data.reduceMotionFollowsSystem
                      ? 'Follows your device setting.'
                      : 'Turns off animations.',
                  value: data.reduceMotion,
                  onChanged: data.reduceMotionFollowsSystem
                      ? null
                      : data.onReduceMotionChanged,
                  switchKey: const ValueKey<String>('reduce-motion-switch'),
                  trailing: data.reduceMotionFollowsSystem
                      ? const OPill(label: 'Device', tone: OPillTone.accent)
                      : null,
                ),
                Divider(color: c.hairline, height: 1),
                _toggleTile(
                  context,
                  title: 'Follow device setting',
                  subtitle:
                      'Use the motion setting from your phone or computer.',
                  value: data.reduceMotionFollowsSystem,
                  onChanged: data.onReduceMotionFollowsSystemChanged,
                  switchKey: const ValueKey<String>('follow-device-switch'),
                ),
                Divider(color: c.hairline, height: 1),
                _toggleTile(
                  context,
                  title: 'High contrast',
                  subtitle: 'Enhances borders and text contrast.',
                  value: data.highContrast,
                  onChanged: data.onHighContrastChanged,
                  switchKey: const ValueKey<String>('high-contrast-switch'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    Key? switchKey,
    Widget? trailing,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: OType.body.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    subtitle,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            trailing ??
                Semantics(
                  label: title,
                  toggled: value,
                  button: true,
                  enabled: onChanged != null,
                  onTap: onChanged == null ? null : () => onChanged(!value),
                  child: ExcludeSemantics(
                    child: Switch(
                      key: switchKey,
                      value: value,
                      onChanged: onChanged,
                      activeThumbColor: c.onAccent,
                      activeTrackColor: c.accentFill,
                      inactiveThumbColor: c.textFaint,
                      inactiveTrackColor: c.surfaceRaised,
                      trackOutlineColor: WidgetStatePropertyAll(
                        c.hairlineStrong,
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _livePreview(BuildContext context) {
    final c = OColors.of(context);
    final preview = data.preview;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Live preview',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome_rounded, size: 15, color: c.accent),
                const SizedBox(width: OSpace.xs),
                Text('Live', style: OType.caption.copyWith(color: c.accent)),
              ],
            ),
          ),
          if (preview == null)
            OCard(
              child: OEmptyState(
                icon: Icons.visibility_off_outlined,
                title: 'No preview yet',
                message:
                    'Turn the preview back on to see how your chat will look.',
                compact: true,
                action: OButton(
                  label: 'Show preview',
                  onPressed: data.onRefreshPreview,
                ),
              ),
            )
          else
            MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(data.resolvedTextScale)),
              child: OCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 18,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Text(
                            preview.sessionLabel,
                            style: OType.h3.copyWith(color: c.text),
                          ),
                        ),
                        OPill(
                          label: preview.statusLabel,
                          tone: OPillTone.success,
                          dot: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: OSpace.l),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 280),
                        padding: const EdgeInsets.all(OSpace.m),
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(ORadius.l),
                            topRight: Radius.circular(ORadius.l),
                            bottomLeft: Radius.circular(ORadius.l),
                            bottomRight: Radius.circular(ORadius.s),
                          ),
                          border: data.highContrast
                              ? Border.all(color: c.hairlineStrong)
                              : null,
                        ),
                        child: Text(
                          preview.userMessage,
                          style: OType.bodySm.copyWith(color: c.text),
                        ),
                      ),
                    ),
                    const SizedBox(height: OSpace.m),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: _accentFor(c, data.resolvedAccentId),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.bolt_rounded,
                            size: 17,
                            color: c.onAccent,
                          ),
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Ovid Si',
                                style: OType.caption.copyWith(
                                  color: c.textMuted,
                                ),
                              ),
                              const SizedBox(height: OSpace.xs),
                              Text(
                                preview.assistantMessage,
                                style: OType.bodySm.copyWith(color: c.text),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: OSpace.l),
                    Container(
                      padding: const EdgeInsets.all(OSpace.s),
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(ORadius.pill),
                        border: data.highContrast
                            ? Border.all(color: c.hairlineStrong)
                            : null,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.add_rounded, size: 20, color: c.textMuted),
                          const SizedBox(width: OSpace.s),
                          Expanded(
                            child: Text(
                              preview.composerHint,
                              style: OType.caption.copyWith(color: c.textFaint),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            width: OSpace.touch,
                            height: OSpace.touch,
                            decoration: BoxDecoration(
                              color: _accentFor(
                                c,
                                data.resolvedAccentId,
                              ).withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                            ),
                            child: OIconButton(
                              icon: Icons.arrow_upward_rounded,
                              semanticLabel: 'Send preview message',
                              onPressed: data.onPreviewSend,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _deviceNote(BuildContext context) {
    final c = OColors.of(context);
    return Text(
      'These settings apply to this device.',
      textAlign: TextAlign.center,
      style: OType.caption.copyWith(color: c.textFaint),
    );
  }
}

Color _accentFor(OColors c, String id) {
  return switch (id) {
    'blue' => Color.lerp(c.accentFill, c.success, 0.55) ?? c.success,
    'green' => c.success,
    'amber' => c.warn,
    _ => c.accentFill,
  };
}

class _ThemeThumbPanel extends StatelessWidget {
  const _ThemeThumbPanel({required this.colors});

  final OColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.bg,
      padding: const EdgeInsets.all(7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 4,
            decoration: BoxDecoration(
              color: colors.accentFill,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 6),
          FractionallySizedBox(
            widthFactor: 0.92,
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: colors.textMuted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 4),
          FractionallySizedBox(
            widthFactor: 0.62,
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: colors.textMuted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Spacer(),
          Container(
            height: 9,
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ),
    );
  }
}
