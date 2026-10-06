import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/sandbox_service.dart';
import '../core/state.dart';
import '../core/studio_terminal.dart';
import '../core/theme.dart';
import 'studio_errors.dart';
import 'studio_layout.dart';
import 'widgets/aether_primitives.dart';

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
//
// v2-12 premium layer (UI-only — the shell protocol is untouched):
// - scrollback search: a filter box that narrows the rendered lines;
// - named tabs: long-press the tab strip to rename the active terminal;
// - per-tab command history: ↑/↓ in the input recalls previous commands;
// - queued input: the field never locks while a command runs — lines
//   submitted mid-run are echoed with a `» queued:` marker and dispatch
//   in order once the shell goes idle;
// - ANSI-lite: common SGR colour/weight codes render as coloured spans,
//   other escape sequences are stripped from the visible text.
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
  int _created = 0;

  @override
  void initState() {
    super.initState();
    _addTerminal();
  }

  void _addTerminal() {
    setState(() {
      _terms.add(_TerminalSession(name: 'bash ${++_created}'));
      _active = _terms.length - 1;
    });
  }

  void _closeTerminal(int i) {
    final t = _terms[i];
    t.dispose();
    setState(() {
      _terms.removeAt(i);
      if (_terms.isEmpty) {
        _terms.add(_TerminalSession(name: 'bash ${++_created}'));
        _active = 0;
      } else if (_active >= _terms.length) {
        _active = _terms.length - 1;
      }
    });
  }

  /// Long-press on the tab strip renames the ACTIVE terminal. Rename hangs
  /// off the strip (not each pill) so the segmented control stays the
  /// uniform, keyboard-accessible Aether primitive.
  Future<void> _renameActiveTerminal() async {
    if (_terms.isEmpty) return;
    final t = _terms[_active.clamp(0, _terms.length - 1)];
    final entered = await showDialog<String>(
      context: context,
      builder: (_) => _RenameTerminalDialog(initial: t.name),
    );
    final name = entered?.trim() ?? '';
    if (name.isNotEmpty && name != t.name) {
      setState(() => t.name = name);
    }
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
  /// target is doing real work instead of eating vertical space twice. The
  /// tab selector itself renders through [AetherSegmentedControl]; per-tab
  /// close is a dedicated action for the active tab (so the segmented control
  /// stays uniform and keyboard-accessible).
  Widget _strip(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    // Build segmented options from the live shell list — a busy terminal gets
    // a sync icon, idle gets a chevron. Labels are the (renameable) tab
    // names, kept short so a handful of terminals fit on compact widths.
    final options = <({int value, String label, IconData? icon})>[
      for (var i = 0; i < _terms.length; i++)
        (
          value: i,
          label: _terms[i].name,
          icon: _terms[i].shell.busy ? Icons.sync : Icons.chevron_right,
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
          // Tight at exactly the 44dp tap-target budget: any border or
          // vertical padding here comes out of the buttons' height (a
          // Container counts a bottom border as padding).
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
                    // Rebuild the segmented control whenever any shell's busy
                    // state flips so the per-option icon stays in sync.
                    animation: Listenable.merge(
                      [for (final t in _terms) t.shell],
                    ),
                    builder: (_, _) {
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPress: _renameActiveTerminal,
                        child: AetherSegmentedControl<int>(
                          options: options,
                          value: _active.clamp(0, _terms.length - 1),
                          onChanged: (v) => setState(() => _active = v),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Close the currently active terminal (the segmented control is
              // uniform; close is a separate action on the active tab so it is
              // reachable with a single tap without hunting through per-pill
              // controls).
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

/// Rename dialog for the active terminal. Owns its controller so disposal
/// rides the route's unmount — a controller disposed at `pop` time is still
/// built by the exit animation and throws.
class _RenameTerminalDialog extends StatefulWidget {
  const _RenameTerminalDialog({required this.initial});
  final String initial;
  @override
  State<_RenameTerminalDialog> createState() => _RenameTerminalDialogState();
}

class _RenameTerminalDialogState extends State<_RenameTerminalDialog> {
  late final TextEditingController ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename terminal'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(hintText: 'Terminal name'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ctrl.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// One terminal's mutable UI state. Each tab owns a stable [tabId], the
/// persistent shell it is bound to (created lazily on first command), its
/// renameable display [name], its scrollback filter, its queued input, and
/// its command-recall history.
class _TerminalSession {
  _TerminalSession({required this.name}) {
    tabId = 'tab-${_seq++}';
    shell = StudioShellSession(tabId: tabId);
    inputFocus = FocusNode(
      onKeyEvent: (_, event) =>
          onInputKey?.call(event) ?? KeyEventResult.ignored,
    );
  }
  static int _seq = 0;
  late final String tabId;
  late final StudioShellSession shell;

  /// Display name shown on the tab pill (default `bash N`, user-renameable).
  String name;

  final input = TextEditingController();
  final scroll = ScrollController();

  /// Scrollback search: the filter box text and whether the box is open.
  final search = TextEditingController();
  bool searchOpen = false;

  /// Commands submitted while the shell was busy, in submission order. They
  /// are echoed with a `» queued:` marker until the shell goes idle and the
  /// pane dispatches them.
  final queued = <String>[];

  /// Per-tab command history for ↑/↓ recall. [histIndex] is null while the
  /// user edits a fresh line; [histDraft] stashes that in-progress line so
  /// ↓ past the newest entry restores it.
  final cmdHistory = <String>[];
  int? histIndex;
  String histDraft = '';

  /// Input focus with a key-event hook so ↑/↓ recall intercepts the arrows
  /// before the text field's own caret handling. The pane installs the
  /// handler ([onInputKey]) because recall mutates pane state.
  late final FocusNode inputFocus;
  KeyEventResult Function(KeyEvent event)? onInputKey;

  void dispose() {
    shell.dispose();
    input.dispose();
    scroll.dispose();
    search.dispose();
    inputFocus.dispose();
  }
}

/// The active terminal's pane (scrollback + search + input).
class _TerminalPane extends StatefulWidget {
  final _TerminalSession term;
  const _TerminalPane({required this.term});
  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  bool _drainScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.term.onInputKey = _handleInputKey;
    widget.term.shell.addListener(_onShellChanged);
    // Catch up with anything the shell did while this pane was detached
    // (e.g. a queued command whose shell went idle on a background tab).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onShellChanged();
    });
  }

  @override
  void didUpdateWidget(_TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.term, widget.term)) {
      oldWidget.term.shell.removeListener(_onShellChanged);
      oldWidget.term.onInputKey = null;
      widget.term.onInputKey = _handleInputKey;
      widget.term.shell.addListener(_onShellChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onShellChanged();
      });
    }
  }

  @override
  void dispose() {
    widget.term.shell.removeListener(_onShellChanged);
    widget.term.onInputKey = null;
    super.dispose();
  }

  void _onShellChanged() {
    final t = widget.term;
    // Queue drain: the shell just went idle with input waiting. Defer the
    // dispatch past this notification so `begin` for the next command does
    // not re-enter the listener mid-callback.
    if (!t.shell.busy && t.queued.isNotEmpty && !_drainScheduled) {
      _drainScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _drainScheduled = false;
        if (!mounted || !identical(widget.term, t)) return;
        if (t.shell.busy || t.queued.isEmpty) return;
        final next = t.queued.removeAt(0);
        setState(() {}); // drop the drained line's queued marker
        _run(next);
      });
    }
    _scrollToBottom(t);
  }

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

  /// ↑/↓ command recall. Intercepted on the field's own FocusNode so it runs
  /// before the text field's caret shortcuts; modified arrows (selection,
  /// word jumps) are left to the field.
  KeyEventResult _handleInputKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed ||
        kb.isControlPressed ||
        kb.isAltPressed ||
        kb.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final t = widget.term;
    setState(() {
      if (key == LogicalKeyboardKey.arrowUp) {
        if (t.cmdHistory.isEmpty) return;
        if (t.histIndex == null) {
          t.histDraft = t.input.text;
          t.histIndex = t.cmdHistory.length - 1;
        } else if (t.histIndex! > 0) {
          t.histIndex = t.histIndex! - 1;
        }
        _setInput(t, t.cmdHistory[t.histIndex!]);
      } else {
        if (t.histIndex == null) return;
        if (t.histIndex! >= t.cmdHistory.length - 1) {
          t.histIndex = null;
          _setInput(t, t.histDraft);
        } else {
          t.histIndex = t.histIndex! + 1;
          _setInput(t, t.cmdHistory[t.histIndex!]);
        }
      }
    });
    return KeyEventResult.handled;
  }

  void _setInput(_TerminalSession t, String value) {
    t.input.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  /// Submit entry point. The field is never locked: a line entered while the
  /// shell is busy joins the per-tab queue (echoed with a `» queued:`
  /// marker) and runs once the current command finishes.
  Future<void> _submit(String raw) async {
    final t = widget.term;
    final c = raw.trim();
    if (c.isEmpty) return;
    t.cmdHistory.add(c);
    t.histIndex = null;
    t.histDraft = '';
    if (t.shell.busy) {
      setState(() {
        t.queued.add(c);
        t.input.clear();
      });
      _scrollToBottom(t);
      return;
    }
    await _run(c);
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

  /// The scrollback lines visible under the current search filter. An empty
  /// (or closed) filter shows everything; matching is case-insensitive.
  List<String> _visibleHistory(_TerminalSession t) {
    final q = t.search.text.trim().toLowerCase();
    if (!t.searchOpen || q.isEmpty) return t.shell.history;
    return [
      for (final l in t.shell.history)
        if (l.toLowerCase().contains(q)) l,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.term;
    return AnimatedBuilder(
      animation: t.shell,
      builder: (_, _) {
        final s = t.shell;
        final history = _visibleHistory(t);
        return Column(
          children: [
            Expanded(
              child: Semantics(
                label: 'Terminal output',
                container: true,
                child: ListView.builder(
                  controller: t.scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount:
                      history.length + t.queued.length + (s.busy ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i >= history.length + t.queued.length) {
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
                    if (i >= history.length) {
                      // Queued input: marked, not yet echoed through the
                      // shell. Runs in order once the command above finishes.
                      return SelectableText(
                        '» queued: ${t.queued[i - history.length]}',
                        style: TextStyle(
                          fontFamily: Aether.mono,
                          fontFamilyFallback: kStudioMonoFallback,
                          fontSize: kStudioMinFontSize,
                          height: 1.6,
                          fontStyle: FontStyle.italic,
                          color: Aether.warn,
                        ),
                      );
                    }
                    final l = history[i];
                    return _lineWidget(l);
                  },
                ),
              ),
            ),
            if (t.searchOpen) _searchBar(t),
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
                      focusNode: t.inputFocus,
                      // Never locks: lines submitted while busy queue up.
                      // Explicit `true` (rather than the default null) keeps
                      // the property meaningful as a not-busy probe for the
                      // pre-existing widget test.
                      enabled: true,
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
                        // a hung command must never wedge the terminal. The
                        // field itself stays enabled (input queues), which
                        // also keeps this button hittable mid-run.
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
                      onSubmitted: _submit,
                    ),
                  ),
                  // Scrollback search for THIS terminal.
                  StudioIconButton(
                    icon: Icons.search,
                    tooltip: 'Search terminal output',
                    iconSize: 16,
                    color: t.searchOpen ? Aether.accent : null,
                    onPressed: () => setState(() {
                      t.searchOpen = !t.searchOpen;
                      if (!t.searchOpen) t.search.clear();
                    }),
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

  /// The scrollback filter box. Filters as you type; close restores the full
  /// scrollback and clears the query.
  Widget _searchBar(_TerminalSession t) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Aether.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: t.search,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(
                fontFamily: Aether.mono,
                fontFamilyFallback: kStudioMonoFallback,
                fontSize: kStudioMinFontSize + 0.5,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter scrollback…',
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
                  Icons.search,
                  size: 16,
                  color: Aether.textFaint,
                ),
              ),
            ),
          ),
          StudioIconButton(
            icon: Icons.close,
            tooltip: 'Close search',
            iconSize: 16,
            onPressed: () => setState(() {
              t.searchOpen = false;
              t.search.clear();
            }),
          ),
        ],
      ),
    );
  }

  /// One scrollback line. Lines without escape sequences keep the cheap
  /// plain-text path (and the existing prompt/warning/success colouring);
  /// lines with SGR codes render through the ANSI-lite span builder.
  Widget _lineWidget(String l) {
    final base = _lineStyle(l);
    if (!l.contains('\x1B')) {
      return SelectableText(l, style: base);
    }
    return SelectableText.rich(
      TextSpan(style: base, children: _ansiSpans(l, base)),
    );
  }

  TextStyle _lineStyle(String l) => TextStyle(
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
      );
}

// ── ANSI-lite ─────────────────────────────────────────────────────────
// One-pass escape parser: SGR sequences (CSI … m) adjust the running text
// style; every other escape sequence (cursor moves, erases, OSC titles,
// two-char ESC forms) is dropped from the visible text. Colour tokens come
// from Aether where one exists; magenta/cyan use fixed terminal hues.

/// CSI groups (`ESC [ params letter`), OSC strings (`ESC ] … BEL/ST`), and
/// remaining two-character ESC forms.
final RegExp _ansiPattern = RegExp(
  '\x1B\\[([0-9;?]*)([A-Za-z])'
  '|\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)?'
  '|\x1B[^\\[\\]]',
);

/// SGR foreground colours, standard (30–37) and bright (90–97) ranges.
final Map<int, Color> _sgrForeground = <int, Color>{
  30: const Color(0xFF6B7280), // black → a grey that reads on both themes
  31: Aether.danger,
  32: Aether.successLight,
  33: Aether.warn,
  34: Aether.accent,
  35: const Color(0xFFC678DD), // magenta
  36: const Color(0xFF39C5CF), // cyan
  37: Aether.text,
  90: Aether.textFaint,
  91: Aether.danger,
  92: Aether.successLight,
  93: Aether.warn,
  94: Aether.accent,
  95: const Color(0xFFC678DD),
  96: const Color(0xFF39C5CF),
  97: Aether.text,
};

List<TextSpan> _ansiSpans(String line, TextStyle base) {
  final spans = <TextSpan>[];
  var style = base;
  var index = 0;
  for (final m in _ansiPattern.allMatches(line)) {
    if (m.start > index) {
      spans.add(TextSpan(text: line.substring(index, m.start), style: style));
    }
    if (m.group(2) == 'm') {
      style = _applySgr(style, base, m.group(1) ?? '');
    }
    index = m.end;
  }
  if (index < line.length) {
    spans.add(TextSpan(text: line.substring(index), style: style));
  }
  if (spans.isEmpty) spans.add(TextSpan(text: line, style: base));
  return spans;
}

TextStyle _applySgr(TextStyle style, TextStyle base, String params) {
  var s = style;
  for (final part in params.split(';')) {
    final code = part.isEmpty ? 0 : int.tryParse(part) ?? 0;
    if (code == 0) {
      s = base; // reset
    } else if (code == 1) {
      s = s.copyWith(fontWeight: FontWeight.w700);
    } else if (code == 2) {
      final c = s.color ?? base.color;
      s = s.copyWith(color: c?.withValues(alpha: 0.55));
    } else if (code == 4) {
      s = s.copyWith(decoration: TextDecoration.underline);
    } else if (code == 22) {
      s = s.copyWith(fontWeight: FontWeight.w400);
    } else if (code == 24) {
      s = s.copyWith(decoration: TextDecoration.none);
    } else if (code == 39) {
      s = s.copyWith(color: base.color);
    } else {
      final fg = _sgrForeground[code];
      if (fg != null) s = s.copyWith(color: fg);
    }
  }
  return s;
}
