import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

const List<int> _waitPresets = <int>[30, 60, 120, 300, 600];

/// The slider steps in 30-second increments between 30 s and 10 min.
int _snapWait(double value) {
  final steps = ((value - 30) / 30).round();
  return (30 + steps * 30).clamp(30, 600);
}

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
///
/// The page keeps the chosen wait locally so the slider and the chips move
/// with the finger. The value still goes through [V2ResponseWaitPageData]'s
/// callbacks, which write `AppState.responseTimeoutSec` — the same field the
/// chat's "Still working…" watchdog reads (persisted as
/// `ovid_response_timeout_sec`).
class ResponseWaitPage extends StatefulWidget {
  const ResponseWaitPage({super.key, required this.data});

  final V2ResponseWaitPageData data;

  @override
  State<ResponseWaitPage> createState() => _ResponseWaitPageState();
}

class _ResponseWaitPageState extends State<ResponseWaitPage> {
  late int _seconds;
  late bool _autoExtend;
  late bool _notify;

  /// The in-flight drag value. Committing only on drag end keeps one
  /// SharedPreferences write per gesture instead of one per frame.
  int? _dragging;

  V2ResponseWaitPageData get data => widget.data;

  @override
  void initState() {
    super.initState();
    _adopt(data, null);
  }

  @override
  void didUpdateWidget(covariant ResponseWaitPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _adopt(widget.data, oldWidget.data);
    }
  }

  void _adopt(V2ResponseWaitPageData next, V2ResponseWaitPageData? prev) {
    if (prev == null || next.seconds != prev.seconds) {
      _seconds = next.seconds.clamp(30, 600).toInt();
    }
    if (prev == null || next.autoExtend != prev.autoExtend) {
      _autoExtend = next.autoExtend;
    }
    if (prev == null || next.notifyAtLimit != prev.notifyAtLimit) {
      _notify = next.notifyAtLimit;
    }
  }

  int get _shown => _dragging ?? _seconds;

  void _commit(int seconds) {
    final handler = data.onChanged;
    if (handler == null) return;
    setState(() {
      _dragging = null;
      _seconds = seconds;
    });
    handler(seconds);
  }

  void _pickPreset(int seconds) {
    final handler = data.onPreset;
    if (handler == null) return;
    setState(() {
      _dragging = null;
      _seconds = seconds;
    });
    handler(seconds);
  }

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
    final seconds = _shown.clamp(30, 600).toInt();
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
              key: const ValueKey<String>('response-wait-current'),
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
                      _waitLabel(_snapWait(value)),
                  activeColor: c.accentFill,
                  inactiveColor: c.surfaceRaised,
                  thumbColor: c.accentFill,
                  onChanged: data.onChanged == null
                      ? null
                      : (value) => setState(() => _dragging = _snapWait(value)),
                  onChangeEnd: data.onChanged == null
                      ? null
                      : (value) => _commit(_snapWait(value)),
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
        onTap: data.onPreset == null ? null : () => _pickPreset(preset),
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
                  value: _autoExtend,
                  onChanged: data.onAutoExtend == null
                      ? null
                      : (value) {
                          setState(() => _autoExtend = value);
                          data.onAutoExtend!(value);
                        },
                ),
                Divider(color: c.hairline, height: 1),
                _toggleRow(
                  context,
                  title: 'Notify me',
                  description: 'Send a notification when time runs out.',
                  value: _notify,
                  onChanged: data.onNotify == null
                      ? null
                      : (value) {
                          setState(() => _notify = value);
                          data.onNotify!(value);
                        },
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
