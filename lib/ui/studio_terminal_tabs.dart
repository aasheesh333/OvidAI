import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/cloud/cloud_ws.dart';
import '../core/cloud/studio_pty.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'studio_layout.dart';
import 'widgets/aether_primitives.dart';

/// Test seam: replaces the cloud pty channel factory so host widget tests can
/// drive a channel without a live multiplexer. Production is null (the real
/// [CloudPtyChannel] over `WsMultiplexer.I`).
@visibleForTesting
CloudPtyChannel Function(String sessionId, String tabId)?
    studioPtyChannelFactoryOverrideForTest;

/// The terminal's Stop button (sends Ctrl-C / 0x03).
const Key studioTerminalStopKey = ValueKey('studio-terminal-stop');

// ── Multi-terminal — N independent cloud PTYs ─────────────────────────────
// Each terminal keeps its own scrollback and its own P2 pty channel, so
// `cd`/exports survive across commands. Tabs at the top with add/close icons
// (VS Code style). The server owns the process; this is a thin byte channel.
class StudioTerminalTabs extends StatefulWidget {
  const StudioTerminalTabs({
    super.key,
    this.sessionId,
    this.collapsed = false,
    this.onToggleCollapse,
    this.onResizeDrag,
  });

  /// Explicit server-session binding (tests); null falls back to [AppState].
  final String? sessionId;

  /// When true only the header strip is drawn — the pane is collapsed to
  /// give the editor the room back on short viewports.
  final bool collapsed;

  /// Header affordance that collapses/expands the pane. Null hides it.
  final VoidCallback? onToggleCollapse;

  /// Vertical drag on the header strip resizes the pane. Null disables it
  /// (a collapsed pane has nothing to resize).
  final void Function(double delta)? onResizeDrag;

  @override
  State<StudioTerminalTabs> createState() => _StudioTerminalTabsState();
}

class _StudioTerminalTabsState extends State<StudioTerminalTabs> {
  final List<_TerminalSession> _terms = [];
  int _active = 0;

  String get _sid => widget.sessionId ?? AppState.I.activeSession?.id ?? '';

  @override
  void initState() {
    super.initState();
    _addTerminal();
  }

  void _addTerminal() {
    final index = _terms.length;
    setState(() {
      _terms.add(_TerminalSession(
        sessionId: _sid,
        tabId: 'tab-$index-${DateTime.now().microsecondsSinceEpoch}',
      ));
      _active = _terms.length - 1;
    });
  }

  void _closeTerminal(int i) {
    final t = _terms[i];
    t.dispose();
    setState(() {
      _terms.removeAt(i);
      if (_terms.isEmpty) {
        _terms.add(_TerminalSession(
          sessionId: _sid,
          tabId: 'tab-0-${DateTime.now().microsecondsSinceEpoch}',
        ));
        _active = 0;
      } else if (_active >= _terms.length) {
        _active = _terms.length - 1;
      }
    });
  }

  @override
  void dispose() {
    for (final t in _terms) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.collapsed) return _strip(context);
    return Column(
      children: [
        _strip(context),
        // The hairline under the strip is its own 1px row: a bottom Border on
        // the strip's Container counts as padding (Decoration.padding) and
        // squeezed the strip's 44dp buttons to 43dp.
        Divider(height: 1, thickness: 1, color: Aether.hairline),
        Expanded(
          child: _terms.isEmpty
              ? const SizedBox.shrink()
              : _TerminalPane(term: _terms[_active]),
        ),
      ],
    );
  }

  /// Terminal tab strip. Doubles as the resize handle, so the 44dp touch
  /// target is doing real work instead of eating vertical space twice.
  Widget _strip(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final options = <({int value, String label, IconData? icon})>[
      for (var i = 0; i < _terms.length; i++)
        (
          value: i,
          label: 'bash ${i + 1}',
          icon: _terms[i].channel.closed
              ? Icons.chevron_right
              : Icons.sync,
        ),
    ];
    final strip = Material(
      type: MaterialType.canvas,
      color: Aether.surface,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: widget.onResizeDrag == null
            ? null
            : (d) => widget.onResizeDrag!(d.delta.dy),
        child: Container(
          key: studioTerminalHandleKey,
          height: math.max(kStudioTapTarget, kStudioTapTarget * scale),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: LayoutBuilder(builder: (context, constraints) => Row(
            children: [
              if (constraints.maxWidth >= 560 * math.max(1.0, scale)) ...[
                Icon(Icons.terminal, size: 14, color: Aether.textMuted),
                const SizedBox(width: 8),
                Semantics(
                  header: true,
                  child: Text(
                    'TERMINALS',
                    style: AetherType.label.copyWith(
                      letterSpacing: 1.2,
                      color: Aether.textFaint,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: AnimatedBuilder(
                    // Rebuild the segmented control whenever any channel's
                    // state flips so the per-option icon stays in sync.
                    animation: Listenable.merge(
                      [for (final t in _terms) t.channel],
                    ),
                    builder: (_, _) {
                      return AetherSegmentedControl<int>(
                        options: options,
                        value: _active.clamp(0, _terms.length - 1),
                        onChanged: (v) => setState(() => _active = v),
                      );
                    },
                  ),
                ),
              ),
              if (_terms.isNotEmpty)
                StudioIconButton(
                  icon: Icons.close,
                  tooltip: 'Close terminal ${_active + 1}',
                  iconSize: 16,
                  onPressed: () => _closeTerminal(_active),
                ),
              StudioIconButton(
                icon: Icons.add,
                tooltip: 'New terminal',
                iconSize: 17,
                onPressed: _addTerminal,
              ),
              if (widget.onToggleCollapse != null)
                StudioIconButton(
                  icon: widget.collapsed
                      ? Icons.expand_less
                      : Icons.expand_more,
                  tooltip: widget.collapsed
                      ? 'Expand terminal'
                      : 'Collapse terminal',
                  iconSize: 20,
                  onPressed: widget.onToggleCollapse,
                ),
            ],
          )),
        ),
      ),
    );
    return Semantics(
      container: true,
      label: widget.onResizeDrag == null
          ? 'Terminal panel'
          : 'Terminal panel — drag the header to resize',
      child: strip,
    );
  }
}

/// One terminal's mutable UI state: a stable tab id and its cloud channel.
class _TerminalSession {
  _TerminalSession({required String sessionId, required this.tabId}) {
    final override = studioPtyChannelFactoryOverrideForTest;
    channel = override != null
        ? override(sessionId, tabId)
        : CloudPtyChannel(
            sessionId: sessionId,
            tabId: tabId,
            ws: WsMultiplexer.I,
          );
  }

  final String tabId;
  late final CloudPtyChannel channel;
  final input = TextEditingController();
  final scroll = ScrollController();

  void dispose() {
    channel.dispose();
    input.dispose();
    scroll.dispose();
  }
}

/// The active terminal's pane (scrollback + input).
class _TerminalPane extends StatefulWidget {
  final _TerminalSession term;
  const _TerminalPane({required this.term});
  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  @override
  void initState() {
    super.initState();
    widget.term.channel.addListener(_onChannelChanged);
  }

  @override
  void didUpdateWidget(_TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.term, widget.term)) {
      oldWidget.term.channel.removeListener(_onChannelChanged);
      widget.term.channel.addListener(_onChannelChanged);
    }
  }

  @override
  void dispose() {
    widget.term.channel.removeListener(_onChannelChanged);
    super.dispose();
  }

  void _onChannelChanged() => _scrollToBottom(widget.term);

  void _scrollToBottom(_TerminalSession t) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!t.scroll.hasClients) return;
      final pos = t.scroll.position;
      // Follow-mode: only auto-scroll when the user is already near the
      // bottom — scrolling up to read earlier output must not be yanked
      // back down by every new chunk.
      if (pos.maxScrollExtent - pos.pixels > 48) return;
      t.scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  void _run(String cmd) {
    final t = widget.term;
    final c = cmd.trimRight();
    if (c.trim().isEmpty) return;
    t.input.clear();
    t.channel.writeln(c);
    _scrollToBottom(t);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.term;
    return AnimatedBuilder(
      animation: t.channel,
      builder: (_, _) {
        final channel = t.channel;
        final text = channel.text;
        return Column(
          children: [
            Expanded(
              child: Semantics(
                label: 'Terminal output',
                container: true,
                child: SelectionArea(
                  child: SingleChildScrollView(
                    controller: t.scroll,
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: Text(
                        text.isEmpty
                            ? 'Cloud terminal — commands run in the Ovid '
                                'workspace.\n'
                            : text,
                        style: TextStyle(
                          fontFamily: Aether.mono,
                          fontFamilyFallback: kStudioMonoFallback,
                          fontSize: kStudioMinFontSize,
                          height: 1.6,
                          color: text.isEmpty
                              ? Aether.textFaint
                              : Aether.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (channel.error != null)
              Container(
                width: double.infinity,
                color: Aether.danger.withValues(alpha: 0.10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  'Terminal error: ${channel.error!.message}',
                  style: TextStyle(fontSize: 12, color: Aether.danger),
                ),
              ),
            // Real command input — bytes go to the server-side PTY.
            Container(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 6),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Aether.hairline)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: t.input,
                      // Shell commands: no autocorrect, no suggestions, no
                      // smart punctuation.
                      autocorrect: false,
                      enableSuggestions: false,
                      smartQuotesType: SmartQuotesType.disabled,
                      smartDashesType: SmartDashesType.disabled,
                      style: const TextStyle(
                        fontFamily: Aether.mono,
                        fontFamilyFallback: kStudioMonoFallback,
                        fontSize: kStudioMinFontSize + 0.5,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: channel.closed
                            ? 'terminal closed'
                            : 'bash \$ …',
                        hintStyle: TextStyle(
                          fontFamily: Aether.mono,
                          fontFamilyFallback: kStudioMonoFallback,
                          fontSize: kStudioMinFontSize + 0.5,
                          color: Aether.textFaint,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        prefixIcon: Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Aether.accent,
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: _run,
                      readOnly: channel.closed,
                    ),
                  ),
                  // Stop sends Ctrl-C (0x03) into the PTY.
                  if (!channel.closed)
                    StudioIconButton(
                      key: studioTerminalStopKey,
                      icon: Icons.stop_circle_outlined,
                      tooltip: 'Stop command (Ctrl-C)',
                      iconSize: 18,
                      color: Aether.danger,
                      onPressed: channel.interrupt,
                    ),
                  // Clear the local scrollback for THIS terminal.
                  if (text.isNotEmpty)
                    StudioIconButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Clear terminal output',
                      iconSize: 16,
                      onPressed: channel.clearScrollback,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
