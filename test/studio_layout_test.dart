import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/ui/studio_layout.dart';

/// Studio responsive geometry (2026-09-30 audit): the screen had ZERO
/// responsive logic — a fixed 210px tree and a fixed 240px terminal on every
/// device, so a 360dp phone left ~150dp for the editor and a ~640dp-tall
/// phone left a ~250px editor viewport. These pins hold the breakpoint scheme
/// and the "the editor is never unusable" invariant.
void main() {
  group('breakpoints follow the repo-wide 840 convention', () {
    test('expanded at >=840, medium at >=600, compact below', () {
      expect(
        StudioMetrics.of(const BoxConstraints.tightFor(width: 360, height: 640))
            .width,
        StudioWidth.compact,
      );
      expect(
        StudioMetrics.of(const BoxConstraints.tightFor(width: 599, height: 640))
            .width,
        StudioWidth.compact,
      );
      expect(
        StudioMetrics.of(const BoxConstraints.tightFor(width: 600, height: 640))
            .width,
        StudioWidth.medium,
      );
      expect(
        StudioMetrics.of(const BoxConstraints.tightFor(width: 839, height: 640))
            .width,
        StudioWidth.medium,
      );
      expect(
        StudioMetrics.of(const BoxConstraints.tightFor(width: 840, height: 640))
            .width,
        StudioWidth.expanded,
      );
      expect(
        StudioMetrics.of(
          const BoxConstraints.tightFor(width: 1440, height: 900),
        ).width,
        StudioWidth.expanded,
      );
      expect(StudioMetrics.wideBreakpoint, 840,
          reason: 'shell.dart:203 and chat_screen.dart:1155 already use 840');
    });

    test('the file tree is docked only when there is room beside the editor',
        () {
      final compact =
          StudioMetrics.of(const BoxConstraints.tightFor(width: 360, height: 640));
      expect(compact.treeDocked, isFalse,
          reason: 'a 210px dock left ~150dp of editor on a 360dp phone');
      expect(compact.treeVisibleByDefault, isFalse);
      expect(compact.treeOverlays, isTrue);

      final medium =
          StudioMetrics.of(const BoxConstraints.tightFor(width: 700, height: 900));
      expect(medium.treeDocked, isTrue);
      expect(medium.treeVisibleByDefault, isFalse);
      expect(medium.treeOverlays, isFalse);

      final wide = StudioMetrics.of(
          const BoxConstraints.tightFor(width: 1200, height: 900));
      expect(wide.treeDocked, isTrue);
      expect(wide.treeVisibleByDefault, isTrue);
      expect(wide.treeOverlays, isFalse);
    });

    test('the app bar collapses secondary actions only on compact widths', () {
      expect(
        StudioMetrics.of(const BoxConstraints.tightFor(width: 360, height: 640))
            .compactActions,
        isTrue,
      );
      expect(
        StudioMetrics.of(const BoxConstraints.tightFor(width: 800, height: 600))
            .compactActions,
        isFalse,
      );
    });
  });

  group('the editor never collapses to an unusable size', () {
    const widths = <double>[360, 480, 600, 700, 840, 1024, 1440, 2560];

    test('a docked tree always leaves the editor its minimum width', () {
      for (final w in widths) {
        final m = StudioMetrics.of(BoxConstraints.tightFor(width: w, height: 900));
        if (!m.treeDocked) {
          expect(m.treeWidth, lessThanOrEqualTo(w),
              reason: 'overlay tree must fit on screen at $w');
          continue;
        }
        expect(m.treeWidth, greaterThanOrEqualTo(StudioMetrics.minTreeWidth),
            reason: 'docked tree must be readable at $w');
        expect(m.treeWidth, lessThanOrEqualTo(w - StudioMetrics.minEditorWidth),
            reason: 'editor starved by the tree at $w');
      }
    });

    test('the terminal never eats the editor viewport', () {
      for (final h in <double>[200, 256, 320, 400, 494, 536, 800, 1096, 1600]) {
        final m = StudioMetrics.of(
            BoxConstraints.tightFor(width: 1200, height: h));
        if (!m.terminalFits) {
          expect(
              m.terminalHeight,
              lessThanOrEqualTo(
                  (h - StudioMetrics.minEditorHeight).clamp(0.0, double.infinity)),
              reason: 'editor viewport squeezed at $h');
          expect(m.terminalHeight,
              lessThanOrEqualTo(StudioMetrics.collapsedBarHeight));
          continue;
        }
        expect(m.terminalHeight,
            greaterThanOrEqualTo(StudioMetrics.minTerminalHeight));
        expect(m.terminalHeight, lessThanOrEqualTo(h - StudioMetrics.minEditorHeight),
            reason: 'editor viewport squeezed at $h');
        expect(h - m.terminalHeight,
            greaterThanOrEqualTo(StudioMetrics.minEditorHeight));
      }
    });

    test('a landscape phone (640x360 region) collapses the terminal', () {
      final m =
          StudioMetrics.of(const BoxConstraints.tightFor(width: 640, height: 256));
      expect(m.terminalFits, isFalse);
      expect(m.terminalHeight, StudioMetrics.collapsedBarHeight);
    });

    test('an explicitly expanded terminal in a short region keeps its chrome',
        () {
      // Landscape phone: too short for both panes at their minimums.
      final m = StudioMetrics.of(
          const BoxConstraints.tightFor(width: 640, height: 256));
      expect(m.terminalFits, isFalse);
      final expanded = m.resolveTerminalHeight(m.terminalHeight,
          regionHeight: 256);
      expect(
          expanded,
          greaterThanOrEqualTo(StudioMetrics.collapsedBarHeight +
              StudioMetrics.commandRowHeight),
          reason: 'below its own chrome the terminal pane overflows');
      expect(expanded, lessThanOrEqualTo(256));
      expect(256 - expanded, greaterThanOrEqualTo(0),
          reason: 'the editor must keep a non-negative viewport');
      // A drag in the same region is bounded the same way.
      expect(m.resolveTerminalHeight(100000, regionHeight: 256), 256);
    });

    test('drag clamping keeps both minimums', () {
      final m = StudioMetrics.of(
          const BoxConstraints.tightFor(width: 1200, height: 494));
      expect(m.clampTerminalHeight(10000, regionHeight: 494),
          lessThanOrEqualTo(494 - StudioMetrics.minEditorHeight));
      expect(m.clampTerminalHeight(-50, regionHeight: 494),
          greaterThanOrEqualTo(StudioMetrics.minTerminalHeight));
      expect(m.clampTreeWidth(10000, regionWidth: 1200),
          lessThanOrEqualTo(1200 - StudioMetrics.minEditorWidth));
      expect(m.clampTreeWidth(1, regionWidth: 1200),
          greaterThanOrEqualTo(StudioMetrics.minTreeWidth));
      // A narrow region must still yield a sane (<= region) width.
      expect(m.clampTreeWidth(10000, regionWidth: 300), lessThanOrEqualTo(300));
    });
  });

  group('sync progress parsing', () {
    test('reads the done/total pair out of RepoCache.onLine text', () {
      expect(parseSyncFraction('synced 25 / 400 files'), closeTo(0.0625, 1e-9));
      expect(parseSyncFraction('synced 400 / 400 files'), 1.0);
      expect(parseSyncFraction('synced 0 / 12 files'), 0.0);
    });

    test('returns null for lines that carry no progress', () {
      expect(parseSyncFraction('fetching tree of o/r …'), isNull);
      expect(parseSyncFraction('repo synced ✓ 12 files in memory'), isNull);
      expect(parseSyncFraction('synced 5 / 0 files'), isNull);
      expect(parseSyncFraction(''), isNull);
    });

    test('never returns a fraction outside 0..1', () {
      expect(parseSyncFraction('synced 900 / 400 files'), 1.0);
    });
  });

  group('shared sheet scaffold is consistent', () {
    test('one corner radius for every Studio bottom sheet', () {
      expect(studioSheetRadius, isNot(equals(18)),
          reason: 'the audit found 18 vs 20 sheets side by side');
      expect(studioSheetRadius, 20);
    });
  });

  group('tap-target and type floors', () {
    test('the 44dp tap-target invariant is the floor', () {
      expect(kStudioTapTarget, greaterThanOrEqualTo(44));
    });
    test('no Studio text may render below the readable floor', () {
      expect(kStudioMinFontSize, greaterThanOrEqualTo(12));
    });
  });
}
