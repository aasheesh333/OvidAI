import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

// ── Studio shared chrome ────────────────────────────────────────────────────
// Extracted out of studio_screen.dart (2026-09-30 audit) because the screen
// had grown four hand-rolled bottom sheets with two different corner radii,
// two copies of the folder-pick + writability-probe flow, and inline
// ScaffoldMessenger calls that bypassed its own toast helper. Everything in
// here is presentation-only: no repo, session or sandbox logic.

/// Minimum edge of any interactive Studio control.
///
/// The repo already holds a 44dp invariant (see the overlay touch-target pin
/// in `test/overlay_live_indicator_test.dart`); Studio's tab-close (≈20dp),
/// terminal-tab close (11dp), "Save" (unpadded text) and file-tree rows
/// (≈25dp) were all far under it.
const double kStudioTapTarget = 44;

/// Smallest type Studio is allowed to render.
///
/// The screen shipped 9.5px / 10px / 10.5px monospace — unreadable on a phone,
/// and `docs/ENGINEERING_AUDIT.md` item 3 already asks for a 12sp floor.
const double kStudioMinFontSize = 12;

/// One corner radius for every Studio bottom sheet (they were 18 and 20).
const double studioSheetRadius = 20;

/// Generic monospace family, used as the fallback for every
/// `fontFamily: Aether.mono` style in Studio.
///
/// `Aether.mono` is `'JetBrainsMono'`, and `pubspec.yaml` declares no `fonts:`
/// section at all — so on its own it silently resolves to the platform's
/// proportional face and the code editor stops being monospace. Android's
/// system font map does define the generic `monospace` family, so naming it as
/// the fallback gives real fixed-width text today and still prefers
/// JetBrainsMono the moment it is bundled.
const List<String> kStudioMonoFallback = <String>['monospace'];

/// Repo-wide "wide" breakpoint — `lib/ui/shell.dart` and
/// `lib/ui/chat_screen.dart` both gate their two-pane layouts on 840, so
/// Studio uses the same number instead of inventing a third scheme.
const double kStudioWideBreakpoint = 840;

/// Material 3 compact/medium boundary. Below it there is no room to dock a
/// file tree beside an editor, so the tree becomes an overlay.
const double kStudioMediumBreakpoint = 600;

/// Width buckets. Named after the Material 3 window size classes so the
/// numbers mean the same thing here as they do in the rest of the app.
enum StudioWidth { compact, medium, expanded }

/// [double.clamp] widens to `num`; Studio's geometry is all `double`.
double _clamp(double v, double lo, double hi) =>
    v.isNaN || v < lo ? lo : (v > hi ? hi : v);

// ── Pane keys (tests measure the layout through these) ──────────────────────
const Key studioTreePaneKey = Key('studio-tree-pane');
const Key studioEditorPaneKey = Key('studio-editor-pane');
const Key studioTerminalPaneKey = Key('studio-terminal-pane');
const Key studioTreeDividerKey = Key('studio-tree-divider');
const Key studioTreeScrimKey = Key('studio-tree-scrim');
const Key studioTerminalHandleKey = Key('studio-terminal-handle');
const Key studioRepoBarKey = Key('studio-repo-bar');

/// Let variable-height chrome scroll when it would otherwise consume a pane.
/// The content fills the remaining viewport and retains a usable minimum; this
/// also keeps the editor reachable below long approval / conflict details.
class StudioPaneViewport extends StatelessWidget {
  const StudioPaneViewport({
    required this.chrome,
    required this.child,
    this.minContentHeight = 120,
    super.key,
  });

  final List<Widget> chrome;
  final Widget child;
  final double minContentHeight;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    primary: false,
    slivers: [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: chrome,
        ),
      ),
      SliverLayoutBuilder(builder: (context, constraints) {
        return SliverToBoxAdapter(
          child: SizedBox(
            height: math.max(minContentHeight,
                constraints.viewportMainAxisExtent - constraints.precedingScrollExtent),
            child: child,
          ),
        );
      }),
    ],
  );
}

/// Pulls the `done / total` pair out of a [RepoCache.sync] progress line.
///
/// `RepoCache.sync` reports `synced 25 / 400 files` every 25 files; Studio
/// never passed the callback, so a multi-minute serial fetch of up to 400
/// files showed only an 11px spinner. Returns null for lines that carry no
/// progress (tree fetch, the final "repo synced ✓" line).
/// The `(done, total)` pair from a progress line, or null when it carries none.
({int done, int total})? parseSyncCounts(String line) {
  final m = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(line);
  if (m == null) return null;
  final done = int.tryParse(m.group(1)!);
  final total = int.tryParse(m.group(2)!);
  if (done == null || total == null || total <= 0) return null;
  return (done: done, total: total);
}

double? parseSyncFraction(String line) {
  final counts = parseSyncCounts(line);
  if (counts == null) return null;
  return _clamp(counts.done / counts.total, 0.0, 1.0);
}

/// Resolved Studio geometry for one layout pass.
///
/// Built from the constraints of the region that actually holds the
/// tree/editor/terminal split, so [terminalHeight] is derived from the height
/// that is really left after the app bar, the repo bar and any banners.
class StudioMetrics {
  const StudioMetrics._({
    required this.width,
    required this.treeWidth,
    required this.treeDocked,
    required this.treeVisibleByDefault,
    required this.compactActions,
    required this.terminalFits,
    required this.terminalHeight,
    this.textScale = 1.0,
  });

  /// Window size class for the current width.
  final StudioWidth width;

  /// Width of the file tree — the docked width, or the overlay panel width.
  final double treeWidth;

  /// True when the tree sits beside the editor. False on compact widths,
  /// where it is drawn over the editor instead (so the editor keeps 100% of
  /// the width when the tree is closed, and is still usable when open).
  final bool treeDocked;

  /// True when the tree is drawn over the editor behind a scrim rather than
  /// docked beside it.
  bool get treeOverlays => !treeDocked;

  /// Whether the tree starts open. Only [StudioWidth.expanded] has the room.
  final bool treeVisibleByDefault;

  /// True when the app bar must fold secondary actions into an overflow menu.
  final bool compactActions;

  /// False when the region is too short to hold both panes at their minimums;
  /// the terminal then starts collapsed to its header bar.
  final bool terminalFits;

  /// The OS text scale the geometry was resolved with. Both minimums grow with
  /// it: the terminal's header strip and command row scale, and so does the
  /// editor's tab strip. Ignoring it clipped 13px of terminal at 2x.
  final double textScale;

  /// The OS text scale the geometry was resolved with. Both minimums grow with
  /// it: the terminal's header strip and command row scale, and so does the
  /// editor's tab strip. Ignoring it clipped 13px of terminal at 2x.

  /// Default terminal pane height for this region.
  final double terminalHeight;

  // ── Tunables ────────────────────────────────────────────────────────────
  static const double wideBreakpoint = kStudioWideBreakpoint;
  static const double mediumBreakpoint = kStudioMediumBreakpoint;

  /// The editor is the point of the screen; it always keeps at least this.
  static const double minEditorWidth = 320;
  static const double minEditorHeight = 200;

  static const double minTerminalHeight = 120;
  static const double maxTerminalHeight = 320;
  static const double minTreeWidth = 180;
  static const double maxTreeWidth = 340;

  /// Height of the collapsed terminal bar / drag handle.
  static const double collapsedBarHeight = 44;

  /// Height of the terminal's command row (a 48dp prefix-icon field plus its
  /// padding and hairline). Together with the header strip it is the hard floor
  /// for an *explicitly expanded* terminal: below that the pane overflows its
  /// own chrome by ~13px.
  static const double commandRowHeight = 60;

  /// Share of the region the terminal takes by default.
  static const double terminalShare = 0.30;

  factory StudioMetrics.of(BoxConstraints c, {double textScale = 1.0}) {
    final w = c.maxWidth.isFinite ? c.maxWidth : wideBreakpoint;
    final h = c.maxHeight.isFinite ? c.maxHeight : 800.0;
    final scale = (textScale.isFinite && textScale > 0) ? textScale : 1.0;
    final width = w >= wideBreakpoint
        ? StudioWidth.expanded
        : w >= mediumBreakpoint
            ? StudioWidth.medium
            : StudioWidth.compact;

    final minEditor = minEditorHeightFor(scale);
    final minTerminal = minTerminalHeightFor(scale);
    final roomForTerminal = h - minEditor;
    final fits = roomForTerminal >= minTerminal;
    final collapsedHeight = collapsedBarHeight * scale;

    return StudioMetrics._(
      width: width,
      treeWidth: _treeWidth(width, w),
      treeDocked: width != StudioWidth.compact,
      treeVisibleByDefault: width == StudioWidth.expanded,
      compactActions: width == StudioWidth.compact,
      terminalFits: fits,
      textScale: scale,
      terminalHeight: fits
          ? _clamp(
              h * terminalShare,
              minTerminal,
              math.min(math.max(maxTerminalHeight, minTerminal), roomForTerminal),
            )
          : math.min(collapsedHeight, math.max(0.0, roomForTerminal)),
    );
  }

  /// The editor's chrome (tab strip) grows with the OS text scale; its header
  /// is minHeight-based, so only the strip is added.
  static double minEditorHeightFor(double textScale) =>
      minEditorHeight + (collapsedBarHeight * (math.max(1.0, textScale) - 1));

  /// The terminal's header strip AND command row both scale.
  static double minTerminalHeightFor(double textScale) =>
      minTerminalHeight * math.max(1.0, textScale);

  static double _treeWidth(StudioWidth width, double regionWidth) {
    final requested = switch (width) {
      // Overlay panel: wide enough to read paths, narrow enough to leave the
      // editor visible behind the scrim so the user knows where they are.
      StudioWidth.compact => regionWidth * 0.80,
      StudioWidth.medium => regionWidth * 0.32,
      StudioWidth.expanded => regionWidth * 0.26,
    };
    final upper = switch (width) {
      StudioWidth.compact => math.min(320.0, regionWidth),
      StudioWidth.medium => 280.0,
      StudioWidth.expanded => maxTreeWidth,
    };
    final lower = width == StudioWidth.compact ? 200.0 : minTreeWidth;
    final clamped = _clamp(requested, math.min(lower, upper), upper);
    if (width == StudioWidth.compact) {
      return math.min(clamped, regionWidth);
    }
    // Never let the dock starve the editor below its minimum width.
    return math.min(clamped, math.max(0.0, regionWidth - minEditorWidth));
  }

  /// Clamps a user drag on the terminal divider.
  double clampTerminalHeight(double requested, {required double regionHeight}) {
    final minEditor = minEditorHeightFor(textScale);
    final minTerminal = minTerminalHeightFor(textScale);
    final room = regionHeight - minEditor;
    if (room < minTerminal) {
      return math.min(collapsedBarHeight * textScale, math.max(0.0, room));
    }
    final upper = math.min(
      math.max(room, 0.0),
      math.max(maxTerminalHeight, minTerminal),
    );
    final lower = math.min(minTerminal, upper);
    if (requested.isNaN) return lower;
    return _clamp(requested, lower, upper);
  }

  /// The height of an explicitly expanded terminal in a region too short for
  /// both panes: bounded below by the terminal's own chrome and above by the
  /// region, so honouring the user's tap can never overflow either pane.
  double expandedTerminalHeight(
    double requested, {
    required double regionHeight,
  }) {
    final chrome =
        (collapsedBarHeight + commandRowHeight) * math.max(1.0, textScale);
    final floor = math.min(chrome, math.max(0.0, regionHeight));
    if (requested.isNaN) return floor;
    return _clamp(requested, floor, math.max(floor, regionHeight));
  }

  /// Terminal height for the current region: the editor-minimum clamp when
  /// both panes fit, the chrome floor when the user explicitly expanded a
  /// terminal into a region that is too short for both.
  double resolveTerminalHeight(
    double requested, {
    required double regionHeight,
  }) =>
      terminalFits
          ? clampTerminalHeight(requested, regionHeight: regionHeight)
          : expandedTerminalHeight(requested, regionHeight: regionHeight);

  /// Clamps a user drag on the tree divider.
  double clampTreeWidth(double requested, {required double regionWidth}) {
    if (requested.isNaN || regionWidth <= 0) return 0;
    final room = regionWidth - minEditorWidth;
    if (room <= 0) return _clamp(requested, 0.0, regionWidth);
    final upper = math.min(room, maxTreeWidth);
    final lower = math.min(minTreeWidth, upper);
    return _clamp(requested, lower, upper);
  }

  @override
  bool operator ==(Object other) =>
      other is StudioMetrics &&
      other.width == width &&
      other.treeWidth == treeWidth &&
      other.treeDocked == treeDocked &&
      other.treeVisibleByDefault == treeVisibleByDefault &&
      other.compactActions == compactActions &&
      other.terminalFits == terminalFits &&
      other.textScale == textScale &&
      other.terminalHeight == terminalHeight;

  @override
  int get hashCode => Object.hash(
        width,
        treeWidth,
        treeDocked,
        treeVisibleByDefault,
        compactActions,
        terminalFits,
        textScale,
        terminalHeight,
      );

  @override
  String toString() => 'StudioMetrics($width tree=$treeWidth '
      'docked=$treeDocked terminal=$terminalHeight fits=$terminalFits)';
}

/// An icon button that cannot render smaller than [kStudioTapTarget].
///
/// Studio's app bar used `visualDensity: VisualDensity.compact` on every
/// action, which drops the target below the invariant; this pins the box and
/// adds the semantics label the bare `Icon` never had.
class StudioIconButton extends StatelessWidget {
  const StudioIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 19,
    this.color,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: kStudioTapTarget,
          height: kStudioTapTarget,
          child: IconButton(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(
              minWidth: kStudioTapTarget,
              minHeight: kStudioTapTarget,
            ),
            iconSize: iconSize,
            color: color ?? Aether.textMuted,
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }
}

/// Wraps any control in a hit area that is at least [kStudioTapTarget] on both
/// axes, with a semantics label. Used for the custom-drawn controls Studio
/// builds by hand (tree rows, editor tabs, the "Save" affordance).
class StudioTapTarget extends StatelessWidget {
  const StudioTapTarget({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.label,
    this.selected = false,
    this.minWidth = kStudioTapTarget,
    this.minHeight = kStudioTapTarget,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? label;
  final bool selected;
  final double minWidth;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      selected: selected,
      enabled: onTap != null,
      label: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth, minHeight: minHeight),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: child,
        ),
      ),
    );
  }
}

/// Vertical drag handle between the file tree and the editor.
///
/// 44dp wide (the touch invariant) but painted as a gutter — a hairline with a
/// small grip — so it reads as spacing rather than as a hole in the layout.
class StudioPaneDivider extends StatelessWidget {
  const StudioPaneDivider({
    required this.onDragDelta,
    this.onReset,
    this.label = 'Resize the file panel',
    super.key,
  });

  /// Called with the horizontal drag delta in logical pixels.
  final void Function(double delta) onDragDelta;

  /// Double-tap restores the breakpoint default width.
  final VoidCallback? onReset;

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      hint: 'Drag to resize. Double-tap to reset.',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDragDelta(d.delta.dx),
          onDoubleTap: onReset,
          child: SizedBox(
            width: kStudioTapTarget,
            child: DecoratedBox(
              // Hard split at the midline so the 44dp touch gutter reads as the
              // tree's surface on the left and the editor's on the right, not
              // as a fat extension of the tree panel.
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Aether.surface, Aether.surface, Aether.bg, Aether.bg],
                  stops: const [0, 0.5, 0.5, 1],
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 1, height: 12, color: Aether.hairlineStrong),
                    const SizedBox(height: 3),
                    Container(
                      width: 4,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Aether.hairlineStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(width: 1, height: 12, color: Aether.hairlineStrong),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One Studio bottom sheet. Radius, background and safe-area handling were
/// copy-pasted (with two different radii) into four call sites.
Future<T?> showStudioSheet<T>(
  BuildContext context, {
  required Widget child,
  bool scrollable = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Aether.surface,
    isScrollControlled: scrollable,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(studioSheetRadius)),
    ),
    builder: (_) => SafeArea(child: child),
  );
}

/// Sheet title + optional supporting line, matching across all four sheets.
class StudioSheetHeader extends StatelessWidget {
  const StudioSheetHeader({required this.title, this.subtitle, super.key});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// A sheet row with a guaranteed 48dp target (dense `ListTile` is ~40).
class StudioSheetTile extends StatelessWidget {
  const StudioSheetTile({
    required this.title,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.iconColor,
    this.selected = false,
    super.key,
  });

  final String title;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? subtitle;
  final Color? iconColor;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: subtitle == null ? title : '$title. $subtitle',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        // ListTile needs a Material ancestor and the ink needs somewhere to
        // paint; carrying our own keeps the tile usable in any host.
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
            dense: true,
            selected: selected,
            leading: icon == null
                ? null
                : Icon(icon, size: 19, color: iconColor ?? Aether.textMuted),
            title: Text(title, style: const TextStyle(fontSize: 13.5)),
            subtitle: subtitle == null
                ? null
                : Text(
                    subtitle!,
                    style: TextStyle(fontSize: 12, color: Aether.textFaint),
                  ),
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

/// The one toast path for Studio. Replaces the inline `ScaffoldMessenger`
/// calls that bypassed the screen's own helper, and carries the optional
/// secondary detail line so a human message never has to contain raw error
/// text.
void showStudioToast(
  BuildContext context,
  String message, {
  String? detail,
  bool error = false,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(
                fontSize: 13,
                // SnackBars sit on the inverse (dark) surface in both themes,
                // so the brighter red is the one that clears AA there.
                color: error ? Aether.danger : null,
              ),
            ),
            if (detail != null && detail.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    );
}
