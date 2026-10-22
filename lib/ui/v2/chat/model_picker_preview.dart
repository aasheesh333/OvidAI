import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';
import 'model_picker_sheet.dart';

/// Interactive model picker for the gallery.
///
/// Two plan modes are offered so the reviewer can exercise both contract cases:
/// Free/Go (Auto only, manual rows locked) and Plus/Pro (manual rows
/// selectable).
///
/// The banner under the sheet is the "output" half of the test. It counts the
/// `onSelect` callbacks the sheet fired, so a tap on a locked row is proven
/// inert by the counter staying at zero while the selection does not move.
class V2ModelPickerPreview extends StatefulWidget {
  const V2ModelPickerPreview({super.key, required this.manualModelsAllowed});

  final bool manualModelsAllowed;

  @override
  State<V2ModelPickerPreview> createState() => _V2ModelPickerPreviewState();
}

class _V2ModelPickerPreviewState extends State<V2ModelPickerPreview> {
  String _selected = 'auto';
  int _callbacks = 0;
  String? _lastId;

  void _recordSelect(String id) {
    setState(() {
      _selected = id;
      _lastId = id;
      _callbacks++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final allowed = widget.manualModelsAllowed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ORadius.xl),
            child: Material(
              color: c.surface,
              child: V2ModelPickerSheet(
                data: V2ModelPickerData(
                  models: _options(allowed: allowed),
                  selectedId: _selected,
                  manualModelsAllowed: allowed,
                  planLabel: allowed ? 'Plus' : 'Free',
                ),
                onSelect: _recordSelect,
                onManageModels: () => setState(() => _lastId = 'manage models'),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.l, OSpace.s, OSpace.l, 0),
          child: OCard(
            padding: const EdgeInsets.all(OSpace.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'onSelect $_callbacks · ${_selected == 'auto' ? 'Auto' : _selected}',
                  style: OType.bodyStrong.copyWith(color: c.accent),
                ),
                const SizedBox(height: 2),
                Text(
                  _outputLine(allowed),
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _outputLine(bool allowed) {
    if (_lastId == null) {
      return allowed
          ? 'Every row is tappable. Tap one to see onSelect fire.'
          : 'Tap a manual row: it should do nothing, so onSelect stays at 0.';
    }
    if (_lastId == 'manage models') {
      return 'onManageModels fired. No model was selected.';
    }
    if (_lastId == 'auto') {
      return 'onSelect("auto") fired. Auto is available on every plan.';
    }
    return allowed
        ? 'onSelect("$_lastId") fired and the row is now selected.'
        : 'Unexpected: a manual model fired onSelect on Free / Go.';
  }

  List<V2ModelOption> _options({required bool allowed}) => [
    V2ModelOption(
      id: 'ovid-2-flash',
      name: 'Ovid 2 Flash',
      subtitle: 'Fast answers and small edits',
      speed: 'Fast',
      costHint: '1 credit',
      locked: !allowed,
    ),
    V2ModelOption(
      id: 'ovid-2-pro',
      name: 'Ovid 2 Pro',
      subtitle: 'Hard reasoning and long code',
      speed: 'Slower',
      costHint: '4 credits',
      locked: !allowed,
      advanced: true,
    ),
    V2ModelOption(
      id: 'custom-anthropic',
      name: 'Claude (your key)',
      subtitle: 'Connected provider',
      speed: 'Standard',
      costHint: 'Your key',
      locked: !allowed,
      icon: Icons.key_rounded,
    ),
  ];
}
