import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_screen.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';
import 'package:ovid_ai/ui/v2/v2_screen_entry.dart';

/// Responsive gate for every registered UI v2 screen.
///
/// The contract (`docs/design/MINIMAL_UI_CONTRACT.md`, §5) says a screen must
/// survive 320 dp → tablet at 200 % text, and that above 600 dp the body
/// centres to a max width instead of stretching. This file enforces both:
///
///  * **No overflow, nothing wider than the window.** Every screen is pumped at
///    every supported width, at 100 % and 200 % text, in light and dark. A
///    layout exception (a `RenderFlex` overflow, a failed assertion) or a render
///    box wider than the window fails the screen. Content inside a horizontal
///    scrollable is exempt: that is a deliberate pan surface, not a broken row.
///  * **The body is capped.** At 600 dp+ the widest content column may not
///    exceed `OBreakpoints.contentMaxWidth` (640 on tablet, 720 on wide). A
///    screen that renders a 1200 dp line of text fails with the widget that is
///    too wide.
///
/// The cap is measured on the rendered content, so a screen that caps by hand
/// passes; a screen that stretches a phone layout across a desktop window fails
/// and is told to use `OScreen` / `OContent`.
void main() {
  for (final entry in v2Screens) {
    testWidgets('${entry.id} fits every width and text scale', (tester) async {
      final failures = <String>{};

      for (final width in _widths) {
        for (final scale in _scales) {
          for (final dark in _themes) {
            final found = await _auditAt(
              tester,
              entry,
              width: width,
              scale: scale,
              dark: dark,
            );
            for (final failure in found) {
              failures.add(
                '${width.toInt()} dp / ${scale}x / '
                '${dark ? 'dark' : 'light'} — $failure',
              );
            }
          }
        }
      }

      expect(
        failures,
        isEmpty,
        reason:
            '${entry.title} (${entry.id}) breaks the responsive contract:\n'
            '${failures.map((f) => '• $f').join('\n')}',
      );
    });
  }

  testWidgets('every screen body is capped at its breakpoint max width', (
    tester,
  ) async {
    final failures = <String>[];

    for (final entry in v2Screens) {
      for (final width in _capWidths) {
        final limit = OBreakpoints.contentMaxWidth(width);
        final measured = await _measureContent(tester, entry, width: width);
        if (measured == null) continue;
        if (measured.width <= limit + _slack) continue;
        failures.add(
          '${entry.id} @ ${width.toInt()} dp — ${measured.describe} is '
          '${measured.width.toStringAsFixed(1)} dp wide, cap is '
          '${limit.toInt()} dp',
        );
      }
    }

    expect(
      failures,
      isEmpty,
      reason:
          'These screens stretch their body past the contract max width. Use '
          'OScreen (or OContent) so the body centres instead of growing a '
          '1200 dp text column:\n'
          '${failures.map((f) => '• $f').join('\n')}',
    );
  });

  testWidgets('OScreen caps and centres the body on a wide window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const OScreen(
          title: 'Capped',
          leading: SizedBox.shrink(),
          child: Text('A line that must not run the full window width.'),
        ),
      ),
    );
    await tester.pump();

    final body = tester.getRect(find.byType(OContent));
    final column = tester.getRect(
      find.text('A line that must not run the full window width.'),
    );
    expect(body.width, 1280, reason: 'the screen itself fills the window');
    expect(
      column.width,
      lessThanOrEqualTo(720),
      reason: 'at 1280 dp the content must stop at 720, not stretch',
    );
    expect(
      column.center.dx,
      moreOrLessEquals(640, epsilon: 1),
      reason: 'the capped column is centred in the window',
    );
  });

  test('breakpoint caps match the contract', () {
    expect(OBreakpoints.contentMaxWidth(320), double.infinity);
    expect(OBreakpoints.contentMaxWidth(599), double.infinity);
    expect(OBreakpoints.contentMaxWidth(600), 640);
    expect(OBreakpoints.contentMaxWidth(899), 640);
    expect(OBreakpoints.contentMaxWidth(900), 720);
    expect(OBreakpoints.contentMaxWidth(1280), 720);
    expect(OBreakpoints.isCompact(320), isTrue);
    expect(OBreakpoints.isTablet(600), isTrue);
    expect(OBreakpoints.isWide(900), isTrue);
  });

  // The page-level audit pumps each screen at the window width. In the app the
  // shell keeps a 280 dp rail from 600 dp, so chat really gets 320 dp there —
  // the band where its header drew two actions and overflowed by 16 dp.
  group('chat fits the column beside the 600 dp rail', () {
    for (final entry in v2Screens.where(
      (entry) => entry.id == 'chat' || entry.id == 'live_chat',
    )) {
      testWidgets('${entry.id} at 200 % text', (tester) async {
        final failures = await _auditBesideRail(tester, entry);
        expect(
          failures,
          isEmpty,
          reason:
              '${entry.title} (${entry.id}) overflows the column the shell '
              'actually gives it at 600 dp (600 − 280 rail = 320):\n'
              '${failures.map((f) => '• $f').join('\n')}',
        );
        // The rail replaces the drawer here, so the shell passes no menu
        // handler and the header must not draw a dead glyph.
        expect(
          find.byIcon(Icons.menu_rounded),
          findsNothing,
          reason: 'the header drew a menu control with no handler',
        );
      });
    }
  });

  group('audit detectors', () {
    testWidgets('a fixed width wider than the window is reported', (
      tester,
    ) async {
      await _pumpProbe(
        tester,
        const Row(children: <Widget>[SizedBox(width: 900, height: 10)]),
        width: 320,
      );
      // The probe overflows on purpose (that is the only way to get a box
      // wider than its parent here). Drain the error so this test asserts the
      // detector, not the framework.
      tester.takeException();
      expect(_tooWide(tester, 320), isNotEmpty);
    });

    testWidgets('a horizontal pan surface is not reported', (tester) async {
      await _pumpProbe(
        tester,
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: const SizedBox(width: 900, height: 10),
        ),
        width: 320,
      );
      expect(_tooWide(tester, 320), isEmpty);
    });

    testWidgets('an overflowing Row is reported as a layout exception', (
      tester,
    ) async {
      await _pumpProbe(
        tester,
        const Row(
          children: <Widget>[
            SizedBox(width: 300, height: 10),
            SizedBox(width: 300, height: 10),
          ],
        ),
        width: 320,
      );
      expect(tester.takeException(), isNotNull);
    });

    testWidgets('an uncapped body measures wider than the cap', (
      tester,
    ) async {
      final measured = await _measureProbe(
        tester,
        const SizedBox(
          width: double.infinity,
          child: Text('A body that stretches the whole desktop window.'),
        ),
        width: 1280,
      );
      expect(measured, isNotNull);
      expect(measured!.width, greaterThan(720));
    });

    testWidgets('a body inside OContent measures at the cap', (tester) async {
      final measured = await _measureProbe(
        tester,
        const OContent(child: Text('A body that stops at the cap.')),
        width: 1280,
      );
      expect(measured, isNotNull);
      expect(measured!.width, lessThanOrEqualTo(720));
    });
  });
}

/// Every width the app claims to support: the two smallest Android phones, a
/// large phone, the tablet edge, and three desktop widths.
const _widths = <double>[320, 360, 412, 600, 800, 1024, 1280];

/// Widths where the body must stop growing. 600 itself is excluded because the
/// 640 dp cap is wider than the window, so the check would be vacuous.
const _capWidths = <double>[800, 1024, 1280];

const _scales = <double>[1, 2];

const _themes = <bool>[false, true];

const _height = 900.0;

/// Sub-pixel slack for rounding in the render tree.
const _slack = 0.5;

/// Pumps one screen at one size and returns every contract violation it sees.
Future<List<String>> _auditAt(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double width,
  required double scale,
  required bool dark,
}) async {
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
    previousOnError?.call(details);
  };

  try {
    await _pumpScreen(tester, entry, width: width, scale: scale, dark: dark);
  } catch (error) {
    errors.add(FlutterErrorDetails(exception: error));
  } finally {
    FlutterError.onError = previousOnError;
  }

  // Clear whatever the framework recorded so the next size starts clean.
  tester.takeException();

  final failures = <String>{
    for (final error in errors) 'layout exception: ${_errorLine(error)}',
    for (final offender in _tooWide(tester, width))
      'wider than the window: $offender',
  };
  return failures.toList();
}

/// Pumps [entry] in the column the shell gives it at 600 dp: the 280 dp rail
/// plus the page, at 200 % text. The page-level audit only sees the window, so
/// this is the case that hid a 16 dp header overflow.
Future<List<String>> _auditBesideRail(
  WidgetTester tester,
  V2ScreenEntry entry,
) async {
  const width = 600.0;
  const rail = 280.0;
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
    previousOnError?.call(details);
  };

  tester.view.physicalSize = const Size(width, _height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(width, _height),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: rail),
                Expanded(child: Builder(builder: entry.builder)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  } catch (error) {
    errors.add(FlutterErrorDetails(exception: error));
  } finally {
    FlutterError.onError = previousOnError;
  }

  tester.takeException();
  return [
    for (final error in errors) 'layout exception: ${_errorLine(error)}',
  ];
}

Future<void> _pumpScreen(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double width,
  required double scale,
  required bool dark,
}) async {
  tester.view.physicalSize = Size(width, _height);
  tester.view.devicePixelRatio = 1;

  Widget child = Builder(builder: entry.builder);
  if (entry.isSheet) child = Scaffold(body: child);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, _height),
          textScaler: TextScaler.linear(scale),
        ),
        child: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// The width of the widest content column at [width], or `null` when the
/// screen renders nothing measurable (or fails to lay out).
///
/// Both the shared shell's cap and the widest text/image leaf are measured and
/// the larger is reported: a screen can cap one region and leave another
/// stretched, and the stretched one is the violation.
///
/// The top bar is chrome, not body: a header title sits between the leading
/// control and the actions and is allowed to use the window width (the same
/// way `OScreen` fills the window while capping its body), so header text is
/// skipped.
Future<_Measurement?> _measureContent(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double width,
}) async {
  try {
    await _pumpScreen(tester, entry, width: width, scale: 1, dark: false);
  } catch (_) {
    tester.takeException();
    return null;
  }
  // A broken layout leaves sizes missing, so there is nothing honest to
  // measure; the overflow test reports that screen instead.
  if (tester.takeException() != null) return null;
  return _widestContent(tester);
}

_Measurement? _widestContent(WidgetTester tester) {
  _Measurement? widest;
  void consider(double width, String describe) {
    if (width > (widest?.width ?? 0)) {
      widest = _Measurement(width, describe);
    }
  }

  for (final element in find.byType(OContent).evaluate()) {
    // OContent builds Align > ConstrainedBox > Padding > child. The
    // ConstrainedBox carries the cap, so its size is the content column.
    final constrained = _firstDescendant<ConstrainedBox>(element);
    final render = constrained?.renderObject;
    if (render is RenderBox && render.hasSize) {
      consider(render.size.width, 'OContent column');
    }
  }

  void visit(Element element) {
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) return;
    final render = element.renderObject;
    if (render is RenderBox &&
        render.hasSize &&
        !_isPannable(element) &&
        !_isInHeader(element) &&
        (render is RenderParagraph || render is RenderImage)) {
      consider(render.size.width, _describe(element, render.size.width));
    }
    element.visitChildren(visit);
  }

  final root = tester.binding.rootElement;
  if (root != null) visit(root);
  return widest;
}

Element? _firstDescendant<T extends Widget>(Element root) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget is T) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return found;
}

/// Render boxes wider than the window, ignoring content that lives inside a
/// horizontal scrollable (a pan surface, not a broken row).
List<String> _tooWide(WidgetTester tester, double viewport) {
  final offenders = <String>[];

  void visit(Element element) {
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) return;
    final render = element.renderObject;
    if (render is RenderBox &&
        render.hasSize &&
        render.size.width > viewport + _slack &&
        !_isPannable(element) &&
        !_isUnconstrained(element)) {
      // Report the outermost offending box; its descendants are the same bug.
      offenders.add(_describe(element, render.size.width));
      return;
    }
    element.visitChildren(visit);
  }

  final root = tester.binding.rootElement;
  if (root != null) visit(root);
  return offenders;
}

/// True inside the top bar: header chrome, not the scrolling body. A header
/// title may use the full window width, so it is not a stretched column.
bool _isInHeader(Element element) {
  var header = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is AppBar) {
      header = true;
      return false;
    }
    return true;
  });
  return header;
}

/// True inside a horizontal scrollable: the content is meant to be wider than
/// the window.
bool _isPannable(Element element) {
  var pannable = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Scrollable &&
        (widget.axisDirection == AxisDirection.left ||
            widget.axisDirection == AxisDirection.right)) {
      pannable = true;
      return false;
    }
    return true;
  });
  return pannable;
}

/// True inside a box that deliberately frees its child from the window width.
bool _isUnconstrained(Element element) {
  var free = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is OverflowBox ||
        widget is UnconstrainedBox ||
        widget is FittedBox) {
      free = true;
      return false;
    }
    return true;
  });
  return free;
}

String _describe(Element element, double width) {
  final widget = element.widget;
  final name = widget.runtimeType.toString();
  final key = widget.key == null ? '' : ' key=${widget.key}';
  final label = _labelOf(widget) ?? _descendantLabel(element);
  return '$name$key${label == null ? '' : ' "$label"'} '
      'w=${width.toStringAsFixed(1)}';
}

String? _labelOf(Widget widget) {
  final raw = switch (widget) {
    Text(:final data) => data,
    RichText(:final text) => text.toPlainText(),
    _ => null,
  };
  if (raw == null) return null;
  final flat = raw.replaceAll('\n', ' ').trim();
  if (flat.isEmpty) return null;
  return flat.length <= 40 ? flat : '${flat.substring(0, 40)}…';
}

String? _descendantLabel(Element element) {
  String? found;
  void visit(Element child) {
    if (found != null) return;
    final label = _labelOf(child.widget);
    if (label != null) {
      found = label;
      return;
    }
    child.visitChildren(visit);
  }

  element.visitChildren(visit);
  return found;
}

/// The first line of a layout error plus the file that caused it, which is what
/// a reader needs to fix it.
String _errorLine(FlutterErrorDetails details) {
  final message = _firstLine(details.exception);
  // Search the diagnostic before the stack: the "error-causing widget" line
  // there names the app file, while the stack starts inside the framework.
  final head = details.toString().split('\n#0 ').first;
  final match = RegExp(r'file:///\S+\.dart:\d+:\d+').firstMatch(head);
  if (match == null) return message;
  final uri = match.group(0)!;
  final lib = uri.indexOf('/lib/');
  return '$message at ${lib == -1 ? uri : uri.substring(lib + 1)}';
}

String _firstLine(Object error) {
  final text = error.toString().trim();
  final newline = text.indexOf('\n');
  return newline == -1 ? text : text.substring(0, newline);
}

Future<void> _pumpProbe(
  WidgetTester tester,
  Widget body, {
  required double width,
}) async {
  tester.view.physicalSize = Size(width, _height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, _height)),
        child: Scaffold(body: body),
      ),
    ),
  );
  await tester.pump();
}

Future<_Measurement?> _measureProbe(
  WidgetTester tester,
  Widget body, {
  required double width,
}) async {
  await _pumpProbe(tester, body, width: width);
  tester.takeException();
  return _widestContent(tester);
}

class _Measurement {
  const _Measurement(this.width, this.describe);

  final double width;
  final String describe;
}
