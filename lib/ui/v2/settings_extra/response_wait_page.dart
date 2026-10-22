import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

/// Three presets is enough to cover the common cases; the slider handles the
/// rest in 30-second steps.
const List<int> _waitPresets = <int>[30, 120, 300];

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
    this.loading = false,
    this.errorMessage,
    this.onChanged,
    this.onPreset,
    this.onRetry,
  });

  /// Wait time in seconds. The UI supports 30 seconds to 10 minutes.
  final int seconds;
  final bool loading;
  final String? errorMessage;

  final ValueChanged<int>? onChanged;
  final ValueChanged<int>? onPreset;
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
    return OScreen(
      title: 'Response wait',
      subtitle: 'Before Ovid asks you',
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final status = data.loading
        ? OStatus.loading
        : data.errorMessage != null
        ? OStatus.error
        : OStatus.content;
    return OStateView(
      status: status,
      errorMessage: data.errorMessage ?? '',
      onRetry: data.onRetry,
      skeletonRows: 5,
      child: _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final seconds = _shown.clamp(30, 600).toInt();
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      children: [_waitCard(context, seconds)],
    );
  }

  Widget _waitCard(BuildContext context, int seconds) {
    final c = OColors.of(context);
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _waitLabel(seconds),
            key: const ValueKey<String>('response-wait-current'),
            textAlign: TextAlign.center,
            style: OType.display.copyWith(color: c.text),
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
    );
  }

  Widget _presetChip(BuildContext context, int preset, int seconds) {
    final selected = seconds == preset;
    final label = _waitLabel(preset);
    return OPressable(
      onTap: data.onPreset == null ? null : () => _pickPreset(preset),
      semanticLabel: '$label wait time',
      selected: selected,
      child: ExcludeSemantics(
        child: OChip(label: label, selected: selected),
      ),
    );
  }
}
