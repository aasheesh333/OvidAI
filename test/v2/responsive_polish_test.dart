import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_screen.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/phone_auth_sheet.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';
import 'package:ovid_ai/ui/v2/v2_registry_web.dart';
import 'package:ovid_ai/ui/v2/v2_screen_entry.dart';

/// Responsive polish gate for the three-band shell.
///
/// The shell keeps a fixed navigation column from 600 dp up: 280 dp on the
/// tablet band, 300 dp on the wide band. The page therefore receives
/// `window − rail` dp while `MediaQuery` still reports the window width — the
/// exact mismatch that makes a screen lay itself out as a tablet inside a
/// 320 dp column. Every screen is pumped in that real column here.
void main() {
  test('the rail widths this gate simulates are the shell rail widths', () {
    expect(Sidebar.railWidthTablet, 280);
    expect(Sidebar.railWidthWide, 300);
    expect(_rail(600), Sidebar.railWidthTablet);
    expect(_rail(900), Sidebar.railWidthWide);
  });

  group('every screen fits the column beside the rail', () {
    for (final entry in v2Screens) {
      testWidgets('${entry.id} at 600 and 900 dp', (tester) async {
        final failures = <String>[];
        for (final window in const <double>[600, 900]) {
          final found = await _auditBesideRail(tester, entry, window: window);
          failures.addAll(found.map((f) => '${window.toInt()} dp: $f'));
        }
        expect(
          failures,
          isEmpty,
          reason:
              '${entry.title} (${entry.id}) breaks in the shell column '
              '(600 − 280 = 320 dp, 900 − 300 = 600 dp):\n'
              '${failures.map((f) => '• $f').join('\n')}',
        );
      });
    }
  });

  group('no text column wider than 720 dp on desktop', () {
    for (final entry in v2Screens) {
      testWidgets('${entry.id} at 1024 and 1280 dp', (tester) async {
        final failures = <String>[];
        for (final window in const <double>[1024, 1280]) {
          final found = await _auditCap(tester, entry, window: window);
          failures.addAll(found.map((f) => '${window.toInt()} dp: $f'));
        }
        expect(
          failures,
          isEmpty,
          reason:
              '${entry.title} (${entry.id}) renders a stretched text column '
              'beside the rail:\n'
              '${failures.map((f) => '• $f').join('\n')}',
        );
      });
    }
  });

  group('sheets become centred dialogs from 600 dp', () {
    testWidgets('showOSheet centres a 560 dp dialog at 600 and 900 dp', (
      tester,
    ) async {
      for (final window in const <double>[600, 900]) {
        await _pumpSheetHost(tester, window: window);
        final body = tester.getRect(find.text('Sheet body'));
        final surface = tester.getRect(
          find.byKey(const ValueKey<String>('o-sheet-surface')),
        );
        expect(
          surface.width,
          lessThanOrEqualTo(560.5),
          reason: '${window.toInt()} dp: the dialog must cap at 560',
        );
        expect(
          surface.center.dx,
          moreOrLessEquals(window / 2, epsilon: 1),
          reason: '${window.toInt()} dp: the dialog must be centred',
        );
        expect(
          body.top,
          greaterThan(0),
          reason: '${window.toInt()} dp: a dialog is not flush with the bottom',
        );
        expect(
          body.bottom,
          lessThan(window),
          reason: '${window.toInt()} dp: the dialog must not touch the bottom',
        );
      }
    });

    testWidgets('showOSheet stays a bottom sheet on a phone', (tester) async {
      await _pumpSheetHost(tester, window: 360);
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(sheet.width, moreOrLessEquals(360, epsilon: 1));
      expect(sheet.bottom, moreOrLessEquals(900, epsilon: 1));
    });

    testWidgets('the gallery sheet host centres its sheet at 600 dp+', (
      tester,
    ) async {
      final entry = v2ScreensWeb.firstWhere(
        (entry) => entry.id == 'phone_auth',
      );
      for (final window in const <double>[600, 900]) {
        await _pumpEntry(tester, entry, width: window, height: 900);
        final sheet = tester.getRect(find.byType(V2PhoneAuthSheet));
        expect(
          sheet.width,
          lessThanOrEqualTo(560.5),
          reason: '${window.toInt()} dp: the sheet caps at 560',
        );
        expect(
          sheet.center.dx,
          moreOrLessEquals(window / 2, epsilon: 1),
          reason: '${window.toInt()} dp: the sheet is centred',
        );
        expect(
          sheet.top,
          greaterThan(100),
          reason:
              '${window.toInt()} dp: the sheet is a dialog, not bottom-docked',
        );
      }
    });
  });

  group('landscape phone 640×360 keeps the header and composer', () {
    for (final entry in v2Screens) {
      testWidgets('${entry.id} at 640×360', (tester) async {
        final failures = await _auditLandscape(tester, entry);
        expect(
          failures,
          isEmpty,
          reason:
              '${entry.title} (${entry.id}) clips its header or composer at '
              '640×360:\n'
              '${failures.map((f) => '• $f').join('\n')}',
        );
      });
    }
  });
}

const _height = 900.0;

/// Sub-pixel slack for rounding in the render tree.
const _slack = 0.5;

double _rail(double window) => window >= OBreakpoints.wide ? 300 : 280;

double _column(double window) => window - _rail(window);

/// Pumps one screen in the page column the shell gives it.
Future<List<String>> _auditBesideRail(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double window,
}) async {
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
    previousOnError?.call(details);
  };

  try {
    await _pumpBesideRail(tester, entry, window: window);
  } catch (error) {
    errors.add(FlutterErrorDetails(exception: error));
  } finally {
    FlutterError.onError = previousOnError;
  }
  tester.takeException();

  return <String>[
    for (final error in errors) 'layout exception: ${_errorLine(error)}',
    for (final offender in _tooWide(tester, _column(window), fromPage: true))
      'wider than the column: $offender',
  ];
}

Future<List<String>> _auditCap(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double window,
}) async {
  final limit = entry.id == 'browser' ? 1100.0 : 720.0;
  final widest = await _widestText(tester, entry, window: window);
  if (widest == null) return const <String>[];
  if (widest.width <= limit + _slack) return const <String>[];
  return <String>[
    '${widest.describe} is ${widest.width.toStringAsFixed(1)} dp wide '
        '(cap ${limit.toInt()})',
  ];
}

Future<List<String>> _auditLandscape(
  WidgetTester tester,
  V2ScreenEntry entry,
) async {
  const window = 640.0;
  const height = 360.0;
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
    previousOnError?.call(details);
  };

  try {
    await _pumpBesideRail(tester, entry, window: window, height: height);
  } catch (error) {
    errors.add(FlutterErrorDetails(exception: error));
  } finally {
    FlutterError.onError = previousOnError;
  }
  tester.takeException();

  final failures = <String>[
    for (final error in errors) 'layout exception: ${_errorLine(error)}',
    for (final offender in _tooWide(tester, _column(window), fromPage: true))
      'wider than the column: $offender',
  ];
  for (final bar in find.byType(AppBar).evaluate()) {
    final render = bar.renderObject;
    if (render is RenderBox && render.hasSize) {
      final rect = render.localToGlobal(Offset.zero) & render.size;
      if (rect.top < -_slack || rect.bottom > height + _slack) {
        failures.add(
          'header ${rect.top.toStringAsFixed(1)}…'
          '${rect.bottom.toStringAsFixed(1)} outside 0…$height',
        );
      }
    }
  }
  return failures;
}

Future<void> _pumpBesideRail(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double window,
  double height = _height,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(window, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  Widget page = Builder(builder: entry.builder);
  if (entry.isSheet) page = Scaffold(body: page);
  page = KeyedSubtree(key: _pageKey, child: page);

  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(window, height),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: Row(
            children: [
              SizedBox(width: _rail(window), height: height),
              Expanded(child: page),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _pumpEntry(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double width,
  required double height,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      key: ValueKey<String>('entry-${width.toInt()}-${height.toInt()}'),
      theme: OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, height)),
        child: Builder(builder: entry.builder),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _pumpSheetHost(
  WidgetTester tester, {
  required double window,
}) async {
  tester.view.physicalSize = Size(window, _height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      key: ValueKey<String>('sheet-host-${window.toInt()}'),
      theme: OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(window, _height)),
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: OButton(
                label: 'Open',
                onPressed: () => showOSheet<void>(
                  context,
                  title: 'Probe sheet',
                  builder: (_) =>
                      const SizedBox(height: 200, child: Text('Sheet body')),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

/// The widest rendered text paragraph in the screen body, or `null` when the
/// screen cannot lay out at all (the overflow test reports that instead).
Future<_Measurement?> _widestText(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required double window,
}) async {
  try {
    await _pumpBesideRail(tester, entry, window: window);
  } catch (_) {
    tester.takeException();
    return null;
  }
  if (tester.takeException() != null) return null;

  _Measurement? widest;
  void consider(double width, String describe) {
    if (width > (widest?.width ?? 0)) {
      widest = _Measurement(width, describe);
    }
  }

  void visit(Element element) {
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) return;
    if (widget.runtimeType.toString() == '_DeferredLayout') return;
    final render = element.renderObject;
    if (render is RenderBox &&
        render.hasSize &&
        render is RenderParagraph &&
        !_isPannable(element) &&
        !_isInHeader(element)) {
      consider(render.size.width, _describe(element, render.size.width));
    }
    element.visitChildren(visit);
  }

  final root = tester.binding.rootElement;
  if (root != null) visit(root);
  return widest;
}

/// Render boxes wider than [viewport], ignoring content inside a horizontal
/// scrollable or an intentionally unconstrained box.
///
/// With [fromPage] the walk starts at the page column, not at the window, so
/// the app root (which is as wide as the window by definition) is not reported.
List<String> _tooWide(
  WidgetTester tester,
  double viewport, {
  bool fromPage = false,
}) {
  final offenders = <String>[];

  void visit(Element element) {
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) return;
    // The overlay portal's layout surrogate is sized to the window by design:
    // it hosts tooltips and value indicators, not page content.
    if (widget.runtimeType.toString() == '_DeferredLayout') return;
    final render = element.renderObject;
    if (render is RenderBox &&
        render.hasSize &&
        render.size.width > viewport + _slack &&
        !_isPannable(element) &&
        !_isUnconstrained(element)) {
      offenders.add(_describe(element, render.size.width));
      return;
    }
    element.visitChildren(visit);
  }

  final root = fromPage ? _pageElement(tester) : tester.binding.rootElement;
  if (root != null) visit(root);
  return offenders;
}

/// The root of the page column the shell gives a screen.
Element? _pageElement(WidgetTester tester) {
  final found = find.byKey(_pageKey).evaluate();
  return found.isEmpty ? null : found.first;
}

const _pageKey = ValueKey<String>('responsive-polish-page');

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
  final label = _labelOf(widget) ?? _descendantLabel(element);
  return '$name${label == null ? '' : ' "$label"'} '
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

String _errorLine(FlutterErrorDetails details) {
  final message = _firstLine(details.exception);
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

class _Measurement {
  const _Measurement(this.width, this.describe);

  final double width;
  final String describe;
}
