import 'package:flutter/material.dart';

import '../../../core/cloud/account_settings_client.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

/// The server-enforced response-wait bounds.
const int _minSeconds = minResponseWaitSeconds;
const int _maxSeconds = maxResponseWaitSeconds;

const int _stepSeconds = 15;
const int _sliderDivisions = (_maxSeconds - _minSeconds) ~/ _stepSeconds;

/// What actually happens at the limit. A surface, never a cancel: the run
/// keeps going, the composer only says it is still working.
const String _consequence = 'Ovid shows "Still working…" and keeps waiting.';

/// The nearest slider stop for a raw drag value.
int _snapWait(double value) {
  final steps = ((value - _minSeconds) / _stepSeconds).round();
  return (_minSeconds + steps * _stepSeconds).clamp(_minSeconds, _maxSeconds);
}

String _waitLabel(int seconds) {
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  if (rest == 0) return '$minutes min';
  return '$minutes min $rest s';
}

/// Persists a wait. The future must fail when the value did not reach disk —
/// that is what lets the page roll the thumb back instead of lying.
typedef V2ResponseWaitSave = Future<void> Function(int seconds);

/// Injected state for the Response wait limit screen.
@immutable
class V2ResponseWaitPageData {
  const V2ResponseWaitPageData({
    this.seconds,
    this.errorMessage,
    this.onChanged,
    this.onPreset,
    this.onRetry,
  });

  /// The persisted wait in seconds. `null` means "not read yet": the page
  /// shows its loading state rather than pretending a default was chosen.
  final int? seconds;

  /// Set when the stored value could not be read; the page offers [onRetry].
  final String? errorMessage;

  /// Writes the slider value.
  final V2ResponseWaitSave? onChanged;

  /// Writes a preset. Kept apart from [onChanged] because the chips are a
  /// discrete choice, and the caller may want to record it differently.
  final V2ResponseWaitSave? onPreset;

  final VoidCallback? onRetry;
}

/// How long Ovid stays quiet before it flags a reply as still working.
///
/// The page keeps the chosen wait locally so the thumb and the chips move
/// with the finger. The value goes through [V2ResponseWaitPageData]'s
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
  /// The value on screen. Leads the persisted value while a write is in
  /// flight, then either stays (success) or falls back to [_saved] (failure).
  int? _seconds;

  /// The last value the parent confirmed as persisted — the rollback target.
  int? _saved;

  /// The in-flight drag value. Committing only on drag end keeps one write
  /// per gesture instead of one per frame.
  int? _dragging;

  bool _saving = false;

  /// Shown inline under the presets after a write fails.
  String? _saveError;

  /// Guards against an older write landing after a newer one.
  int _saveToken = 0;

  V2ResponseWaitPageData get data => widget.data;

  V2ResponseWaitSave? get _sliderSave => data.onChanged;

  V2ResponseWaitSave? get _presetSave => data.onPreset ?? data.onChanged;

  @override
  void initState() {
    super.initState();
    _adopt(data, null);
  }

  @override
  void didUpdateWidget(covariant ResponseWaitPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.data, widget.data)) return;
    // A write owns the value until it lands; the parent's pre-write value
    // must not yank the thumb back mid-save.
    if (_saving) return;
    _adopt(widget.data, oldWidget.data);
  }

  void _adopt(V2ResponseWaitPageData next, V2ResponseWaitPageData? prev) {
    if (prev != null && next.seconds == prev.seconds) return;
    final value = _readable(next.seconds);
    _seconds = value;
    _saved = value;
    if (value != null) _saveError = null;
  }

  /// A value below the product minimum is a degenerate read, not a choice, so
  /// it is treated as unset. The ceiling is the product's own maximum: the
  /// state layer already clamps on load, so this is only defence.
  static int? _readable(int? seconds) {
    if (seconds == null || seconds < _minSeconds) return null;
    return seconds > _maxSeconds ? _maxSeconds : seconds;
  }

  int? get _shown => _dragging ?? _seconds;

  Future<void> _save(int seconds, V2ResponseWaitSave handler) async {
    final previous = _seconds;
    final token = ++_saveToken;
    setState(() {
      _dragging = null;
      _seconds = seconds;
      _saveError = null;
      _saving = true;
    });
    try {
      await handler(seconds);
    } catch (_) {
      if (!mounted || token != _saveToken) return;
      final restored = _saved ?? previous;
      setState(() {
        _saving = false;
        _seconds = restored;
        _saveError = restored == null
            ? 'Could not save.'
            : 'Could not save. Still ${_waitLabel(restored)}.';
      });
      return;
    }
    // Even a superseded write reached disk, so it is a valid rollback target
    // if a newer write fails.
    _saved = seconds;
    if (!mounted || token != _saveToken) return;
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Response wait',
      subtitle: 'When a reply goes quiet',
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final seconds = _readable(_shown);
    final status = data.errorMessage != null
        ? OStatus.error
        : seconds == null
        ? OStatus.loading
        : OStatus.content;
    return OStateView(
      status: status,
      errorMessage: data.errorMessage ?? '',
      onRetry: data.onRetry,
      skeletonRows: 4,
      child: _content(context, seconds ?? _minSeconds),
    );
  }

  Widget _content(BuildContext context, int seconds) {
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      children: [_waitCard(context, seconds)],
    );
  }

  Widget _waitCard(BuildContext context, int seconds) {
    final c = OColors.of(context);
    final canDrag = _sliderSave != null;
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
          const SizedBox(height: OSpace.s),
          Text(
            _consequence,
            key: const ValueKey<String>('response-wait-consequence'),
            textAlign: TextAlign.center,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.l),
          MergeSemantics(
            child: Semantics(
              // The slider speaks its own value; the label carries the
              // range, which the thumb alone cannot show.
              label: 'Response wait limit, 15 seconds to 10 minutes',
              enabled: canDrag,
              child: SizedBox(
                height: OSpace.touch,
                child: Slider(
                  value: seconds.toDouble(),
                  min: _minSeconds.toDouble(),
                  max: _maxSeconds.toDouble(),
                  divisions: _sliderDivisions,
                  // No `label`: the value indicator would repeat the readout
                  // above, and so would the spoken value.
                  semanticFormatterCallback: (value) =>
                      _waitLabel(_snapWait(value)),
                  activeColor: c.accentFill,
                  inactiveColor: c.surfaceRaised,
                  thumbColor: c.accentFill,
                  onChanged: !canDrag
                      ? null
                      : (value) => setState(() => _dragging = _snapWait(value)),
                  onChangeEnd: !canDrag
                      ? null
                      : (value) => _save(_snapWait(value), _sliderSave!),
                ),
              ),
            ),
          ),
          const SizedBox(height: OSpace.m),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              for (final preset in responseWaitPresets)
                _presetChip(preset, seconds),
            ],
          ),
          if (_saveError != null) ...[
            const SizedBox(height: OSpace.m),
            Semantics(
              liveRegion: true,
              child: Text(
                _saveError!,
                key: const ValueKey<String>('response-wait-save-error'),
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.danger),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _presetChip(ResponseWaitPreset preset, int seconds) {
    final handler = _presetSave;
    final selected = seconds == preset.seconds;
    final duration = _waitLabel(preset.seconds);
    final label = '${preset.label} · $duration';
    return OPressable(
      onTap: handler == null ? null : () => _save(preset.seconds, handler),
      semanticLabel: '${preset.label}, $duration wait time',
      selected: selected,
      child: SizedBox(
        // The chip draws at 34 dp; the touch target stays 48.
        height: OSpace.touch,
        child: Center(
          widthFactor: 1,
          child: ExcludeSemantics(
            child: OChip(label: label, selected: selected),
          ),
        ),
      ),
    );
  }
}
