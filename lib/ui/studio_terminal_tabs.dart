import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/sandbox_service.dart';
import '../core/state.dart';
import '../core/studio_terminal.dart';
import '../core/theme.dart';
import 'studio_errors.dart';
import 'studio_layout.dart';

/// Test seam: replaces the sandbox spawner for the Studio terminal so host
/// widget tests can drive a real host shell without a native sandbox.
/// Production is null (commands run through [SandboxService.spawn]).
///
/// Re-exported from `studio_screen.dart` so existing tests keep importing it
/// from there.
@visibleForTesting
Future<Process> Function()? studioPtySpawnerOverrideForTest;

// ── Multi-terminal (P8) — N independent persistent shells ─────────────
// Each terminal keeps its own scrollback + busy state and its own
// persistent pipe shell (StudioShellSession), so `cd`/exports survive
// across commands. Tabs at the top with add/close icons (VS Code style).
// Shells are owner-scoped in PtyPool so agent Stop never kills them.
class StudioTerminalTabs extends StatefulWidget {
  const StudioTerminalTabs({
    super.key,
    this.collapsed = false,
    this.onToggleCollapse,
    this.onResizeDrag,
  });

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

  @override
  void initState() {
    super.initState();
    _addTerminal();
  }

  void _addTerminal() {
    setState(() {
      _terms.add(_TerminalSession());
      _active = _terms.length - 1;
    });
  }

  void _closeTerminal(int i) {
    final t = _terms[i];
    t.dispose();
    setState(() {
      _terms.removeAt(i);
      if (_terms.isEmpty) {
        _terms.add(_TerminalSession());
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
    final strip = Material(
      type: MaterialType.canvas,
      color: Aether.surface,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: widget.onResizeDrag == null
            ? null
            : (d) => widget.onResizeDrag!(d.delta.dy),
        child: SizedBox(
          key: studioTerminalHandleKey,
          height: math.max(kStudioTapTarget, kStudioTapTarget * scale),
          child: Row(
            children: [
              const SizedBox(width: 10),
              Icon(Icons.terminal, size: 14, color: Aether.textMuted),
              const SizedBox(width: 6),
              Semantics(
                header: true,
                child: Text(
                  'TERMINALS',
                  style: TextStyle(
                    fontSize: kStudioMinFontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _terms.length,
                  itemBuilder: (_, i) {
                    final t = _terms[i];
                    final sel = i == _active;
                    return AnimatedBuilder(
                      animation: t.shell,
                      builder: (_, _) {
                        final busy = t.shell.busy;
                        return StudioTapTarget(
                          onTap: () => setState(() => _active = i),
                          label: 'bash ${i + 1}'
                              '${busy ? ', running a command' : ''}'
                              '${sel ? ', active' : ''}',
                          selected: sel,
                          minWidth: 0,
                          child: Container(
                            // No vertical margin and no Border.all: the strip
                            // is exactly the 44dp tap-target budget, and an
                            // 8dp inset plus a 1px border squeezed the close
                            // button to 34dp and then 42dp. Selection is
                            // carried by the fill, the weight and the
                            // `selected` semantics flag — not by colour alone.
                            padding: const EdgeInsets.only(left: 9),
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              color:
                                  sel ? Aether.surfaceAlt : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  busy ? Icons.sync : Icons.chevron_right,
                                  size: 13,
                                  color: busy
                                      ? Aether.accent
                                      : sel
                                          ? Aether.textMuted
                                          : Aether.textFaint,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'bash ${i + 1}',
                                  style: TextStyle(
                                    fontFamily: Aether.mono,
                                    fontFamilyFallback: kStudioMonoFallback,
                                    fontSize: kStudioMinFontSize,
                                    fontWeight:
                                        sel ? FontWeight.w700 : FontWeight.w400,
                                    color: sel
                                        ? Aether.text
                                        : Aether.textFaint,
                                  ),
                                ),
                                StudioIconButton(
                                  icon: Icons.close,
                                  tooltip: 'Close terminal ${i + 1}',
                                  iconSize: 13,
                                  onPressed: () => _closeTerminal(i),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              // New terminal button.
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
              const SizedBox(width: 2),
            ],
          ),
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

/// One terminal's mutable UI state. Each tab owns a stable [tabId] and the
/// persistent shell it is bound to (created lazily on first command).
class _TerminalSession {
  _TerminalSession() {
    tabId = 'tab-${_seq++}';
    shell = StudioShellSession(tabId: tabId);
  }
  static int _seq = 0;
  late final String tabId;
  late final StudioShellSession shell;
  final input = TextEditingController();
  final scroll = ScrollController();

  void dispose() {
    shell.dispose();
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
    widget.term.shell.addListener(_onShellChanged);
  }

  @override
  void didUpdateWidget(_TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.term, widget.term)) {
      oldWidget.term.shell.removeListener(_onShellChanged);
      widget.term.shell.addListener(_onShellChanged);
    }
  }

  @override
  void dispose() {
    widget.term.shell.removeListener(_onShellChanged);
    super.dispose();
  }

  void _onShellChanged() => _scrollToBottom(widget.term);

  void _scrollToBottom(_TerminalSession t) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!t.scroll.hasClients) return;
      final pos = t.scroll.position;
      // Follow-mode: only auto-scroll when the user is already near the
      // bottom — scrolling up to read earlier output must not be yanked
      // back down by every new line of command output.
      if (pos.maxScrollExtent - pos.pixels > 48) return;
      t.scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  Future<void> _run(String cmd) async {
    final t = widget.term;
    final shell = t.shell;
    final c = cmd.trim();
    if (c.isEmpty || shell.busy) return;
    t.input.clear();
    shell.begin(c);
    _scrollToBottom(t);

    final sessionId = AppState.I.activeSession?.sandboxId ?? 'default';
    // Persistent per-tab shell: state (`cd`, exports) survives commands and
    // output streams in as it happens. Falls back to the one-shot exec when
    // the sandbox is unavailable.
    final override = studioPtySpawnerOverrideForTest;
    try {
      final spawner = override ??
          () async {
            final workDir = await SandboxService.I.workDirFor(sessionId);
            return SandboxService.I.spawn(['bash'], hostWorkDir: workDir);
          };
      if (await shell.runPersistent(c, sid: sessionId, spawner: spawner,
          workspace: SandboxService.I.workDirForSync(sessionId).path)) {
        return;
      }
    } catch (_) {
      // Fall through to the one-shot exec fallback.
    }

    try {
      final workDir = await SandboxService.I.workDirFor(sessionId);
      final out = await SandboxService.I.exec(
        ['bash', '-c', c],
        hostWorkDir: workDir,
        onLine: shell.addOutput,
      );
      if (out.trim().isEmpty) shell.addOutput('(no output)');
    } catch (e) {
      // Terminal output is a developer surface, but a raw Dart exception is
      // still noise: keep the first line, which is the actionable part.
      shell.addOutput('⚠ ${StudioFailure.of(e).detail}');
    } finally {
      shell.finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.term;
    return AnimatedBuilder(
      animation: t.shell,
      builder: (_, _) {
        final s = t.shell;
        return Column(
          children: [
            Expanded(
              child: Semantics(
                label: 'Terminal output',
                container: true,
                child: ListView.builder(
                  controller: t.scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: s.history.length + (s.busy ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == s.history.length) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Aether.accent,
                          ),
                        ),
                      );
                    }
                    final l = s.history[i];
                    return SelectableText(
                      l,
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontFamilyFallback: kStudioMonoFallback,
                        fontSize: kStudioMinFontSize,
                        height: 1.6,
                        color: l.startsWith('\$')
                            ? Aether.accent
                            : l.startsWith('⚠')
                                ? Aether.danger
                                : l.endsWith('✓') || l.startsWith('✓')
                                    ? Aether.successLight
                                    : Aether.textMuted,
                      ),
                    );
                  },
                ),
              ),
            ),
            // Real command input — runs natively in the sandbox.
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
                        hintText: 'bash \$ …',
                        hintStyle: TextStyle(
                          fontFamily: Aether.mono,
                          fontFamilyFallback: kStudioMonoFallback,
                          fontSize: kStudioMinFontSize + 0.5,
                          color: Aether.textFaint,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        prefixIcon: const Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Aether.accent,
                        ),
                        // While a command runs the suffix is a Stop button —
                        // a hung command must never wedge the terminal.
                        suffixIcon: s.busy
                            ? StudioIconButton(
                                icon: Icons.stop_circle_outlined,
                                tooltip: 'Stop command',
                                iconSize: 18,
                                color: Aether.danger,
                                onPressed: () => setState(s.cancel),
                              )
                            : null,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: _run,
                      enabled: !s.busy,
                    ),
                  ),
                  // Clear scrollback for THIS terminal.
                  if (s.history.isNotEmpty)
                    StudioIconButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Clear terminal output',
                      iconSize: 16,
                      onPressed: () => setState(s.history.clear),
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
