import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';
import 'live_chat_page.dart';

/// Interactive chat preview for the gallery.
///
/// This is the end-to-end "input and output" check for Auto versus a manually
/// picked model: type a message, send it, and the transcript shows which model
/// answered. Auto is simulated with a routing line ("Auto routed this to Ovid
/// 2 Flash") so the difference from a manual pick is visible on screen instead
/// of being implied.
class V2ChatModelPreview extends StatefulWidget {
  const V2ChatModelPreview({super.key, this.startWithAuto = true});

  final bool startWithAuto;

  @override
  State<V2ChatModelPreview> createState() => _V2ChatModelPreviewState();
}

class _V2ChatModelPreviewState extends State<V2ChatModelPreview> {
  late bool _auto = widget.startWithAuto;
  final List<V2LiveChatItem> _items = <V2LiveChatItem>[];
  int _seq = 0;

  String get _label => _auto ? 'Auto' : 'Ovid 2 Pro';

  void _send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _items.add(V2LiveUserMessage(id: 'u${_seq++}', text: trimmed));
      _items.add(
        V2LiveAssistantMessage(
          id: 'a${_seq++}',
          markdown: _auto
              ? '**Auto** answered this one.\n\n'
                    'Auto routed the message to Ovid 2 Flash because the '
                    'request was short. You did not pick a model, so the '
                    'router is free to trade depth for speed.\n\n'
                    '> Sent: $trimmed'
              : '**Ovid 2 Pro** answered this one.\n\n'
                    'You picked this model manually, so Auto did not route it. '
                    'Ovid 2 Pro is the slower, deeper model.\n\n'
                    '> Sent: $trimmed',
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.l, OSpace.s, OSpace.l, 0),
          // Wrap, not Row: at 320 dp with 200 % text the two chips and the
          // model label cannot share one line.
          child: Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OChip(
                label: 'Auto',
                selected: _auto,
                onTap: () => setState(() => _auto = true),
              ),
              OChip(
                label: 'Manual',
                selected: !_auto,
                onTap: () => setState(() => _auto = false),
              ),
              Text(
                'model: $_label',
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.s),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ORadius.xl),
            child: Material(
              color: c.bg,
              child: V2LiveChatPage(
                data: V2LiveChatData(
                  title: 'Ovid Si',
                  sessionTitle: _auto ? 'Auto chat' : 'Manual chat',
                  modelLabel: _label,
                  autoOnly: false,
                  items: List<V2LiveChatItem>.unmodifiable(_items),
                  emptyTitle: 'Test Auto vs manual',
                  emptyMessage:
                      'Type a message to see which model answers.',
                ),
                onSend: _send,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
