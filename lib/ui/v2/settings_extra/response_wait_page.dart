import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

const List<int> _waitPresets = <int>[30, 60, 120, 300, 600];

String _waitLabel(int seconds) {
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  if (rest == 0) return '$minutes min';
  return '$minutes min $rest s';
}

/// Injected state for the Response wait limit screen.
@immutable
class V2ResponseWaitPageData {
  const V2ResponseWaitPageData({
    this.seconds = 120,
    this.autoExtend = false,
    this.notifyAtLimit = true,
    this.loading = false,
    this.errorMessage,
    this.onChanged,
    this.onPreset,
    this.onAutoExtend,
    this.onNotify,
    this.onRetry,
  });

  /// Wait time in seconds. The UI supports 30 seconds to 10 minutes.
  final int seconds;
  final bool autoExtend;
  final bool notifyAtLimit;
  final bool loading;
  final String? errorMessage;

  final ValueChanged<int>? onChanged;
  final ValueChanged<int>? onPreset;
  final ValueChanged<bool>? onAutoExtend;
  final ValueChanged<bool>? onNotify;
  final VoidCallback? onRetry;
}

/// How long Ovid waits for a reply before it asks the user what to do.
class ResponseWaitPage extends StatelessWidget {
  const ResponseWaitPage({super.key, required this.data});

  final V2ResponseWaitPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Response wait limit'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 5));
    }
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    final seconds = data.seconds.clamp(30, 600).toInt();
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
            _waitCard(context, seconds),
            _options(context),
            _limitCard(context),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _waitCard(BuildContext context, int seconds) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: OCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Current wait',
              style: OType.bodyStrong.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.m),
            Text(
              _waitLabel(seconds),
              textAlign: TextAlign.center,
              style: OType.display.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.xs),
            Text(
              'before Ovid asks you',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.l),
            Semantics(
              label: 'Response wait limit',
              value: _waitLabel(seconds),
              enabled: data.onChanged != null,
              child: SizedBox(
                height: OSpace.touch,
                child: Slider(
                  value: seconds.toDouble(),
                  min: 30,
                  max: 600,
                  divisions: 19,
                  label: _waitLabel(seconds),
                  semanticFormatterCallback: (value) =>
                      _waitLabel(value.round()),
                  activeColor: c.accentFill,
                  inactiveColor: c.surfaceRaised,
                  thumbColor: c.accentFill,
                  onChanged: data.onChanged == null
                      ? null
                      : (value) => data.onChanged!(value.round()),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '30 s',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                ),
                Text(
                  '10 min',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ],
            ),
            const SizedBox(height: OSpace.m),
            Text(
              'Ovid waits this long for a reply before it asks you.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            Wrap(
              spacing: OSpace.s,
              runSpacing: OSpace.s,
              children: [
                for (final preset in _waitPresets)
                  _presetChip(context, preset, seconds),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _presetChip(BuildContext context, int preset, int seconds) {
    final selected = seconds == preset;
    final label = _waitLabel(preset);
    return Semantics(
      selected: selected,
      child: OPressable(
        onTap: data.onPreset == null ? null : () => data.onPreset!(preset),
        semanticLabel: '$label wait time',
        child: ExcludeSemantics(
          child: OChip(label: label, selected: selected),
        ),
      ),
    );
  }

  Widget _options(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'When time runs out',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _toggleRow(
                  context,
                  title: 'Auto-extend',
                  description: 'Give Ovid more time when a reply is close.',
                  value: data.autoExtend,
                  onChanged: data.onAutoExtend,
                ),
                Divider(color: c.hairline, height: 1),
                _toggleRow(
                  context,
                  title: 'Notify me',
                  description: 'Send a notification when time runs out.',
                  value: data.notifyAtLimit,
                  onChanged: data.onNotify,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(
    BuildContext context, {
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final c = OColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: OType.body.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            Semantics(
              label: title,
              toggled: value,
              button: true,
              enabled: onChanged != null,
              onTap: onChanged == null ? null : () => onChanged(!value),
              child: ExcludeSemantics(
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: c.onAccent,
                  activeTrackColor: c.accentFill,
                  inactiveThumbColor: c.textFaint,
                  inactiveTrackColor: c.surfaceRaised,
                  trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _limitCard(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'At the limit',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.timer_outlined, size: 20, color: c.accent),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        'What happens at the limit',
                        style: OType.h3.copyWith(color: c.text),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.m),
                _limitStep(
                  context,
                  icon: Icons.pause_circle_outline_rounded,
                  text: 'Ovid pauses the run and asks you what to do.',
                ),
                const SizedBox(height: OSpace.s),
                _limitStep(
                  context,
                  icon: Icons.save_outlined,
                  text: 'Your work is kept. Nothing is lost.',
                ),
                const SizedBox(height: OSpace.s),
                _limitStep(
                  context,
                  icon: Icons.fast_forward_outlined,
                  text:
                      'With auto-extend on, Ovid waits a little longer first.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _limitStep(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: c.textMuted),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(text, style: OType.bodySm.copyWith(color: c.textMuted)),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final c = OColors.of(context);
    return Text(
      'This applies to every chat.',
      textAlign: TextAlign.center,
      style: OType.caption.copyWith(color: c.textFaint),
    );
  }
}
