import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/shared_memory_page.dart';

Future<void> _pump(
  WidgetTester tester,
  V2SharedMemoryPageData data, {
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
  bool reduceMotion = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: SharedMemoryPage(data: data),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

V2SharedMemoryPageData _ready({
  bool enabled = true,
  int factCount = 3,
  ValueChanged<bool>? onEnabledChanged,
  void Function(String id, bool value)? onScopeChanged,
  VoidCallback? onForget,
  VoidCallback? onRetry,
}) {
  return V2SharedMemoryPageData(
    enabled: enabled,
    factCount: factCount,
    onEnabledChanged: onEnabledChanged,
    onScopeChanged: onScopeChanged,
    onForget: onForget,
    onRetry: onRetry,
  );
}

void main() {
  testWidgets('renders the explainer, scopes and retention note in light', (
    tester,
  ) async {
    await _pump(tester, _ready());

    expect(find.text('Shared memory'), findsOneWidget);
    expect(find.text('What shared memory does'), findsOneWidget);
    expect(find.text('SCOPES'), findsOneWidget);
    expect(find.text('This chat'), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Global'), findsOneWidget);
    expect(find.text('Who can see it: Project members'), findsOneWidget);
    expect(
      find.textContaining('Shared facts stay until you forget them'),
      findsOneWidget,
    );
    expect(find.text('Forget shared facts'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _ready(), dark: true);

    expect(find.text('What shared memory does'), findsOneWidget);
    expect(find.text('This chat'), findsOneWidget);
    expect(find.text('Forget shared facts'), findsOneWidget);
  });

  testWidgets('master toggle turns sharing on', (tester) async {
    bool? enabled;
    await _pump(
      tester,
      _ready(enabled: false, onEnabledChanged: (value) => enabled = value),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('shared-memory-master-switch')),
    );
    await tester.pumpAndSettle();

    expect(enabled, isTrue);
  });

  testWidgets('scope switches report the scope id and value', (tester) async {
    String? scopeId;
    bool? scopeValue;
    await _pump(
      tester,
      _ready(
        onScopeChanged: (id, value) {
          scopeId = id;
          scopeValue = value;
        },
      ),
    );

    final projectSwitch = find.byKey(
      const ValueKey<String>('shared-memory-scope-project-switch'),
    );
    await tester.ensureVisible(projectSwitch);
    await tester.tap(projectSwitch);
    await tester.pumpAndSettle();

    expect(scopeId, 'project');
    expect(scopeValue, isTrue);
  });

  testWidgets('scope switches are disabled while sharing is off', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _ready(enabled: false, onScopeChanged: (_, _) {}));

    final projectSwitch = tester.widget<Switch>(
      find.byKey(const ValueKey<String>('shared-memory-scope-project-switch')),
    );
    expect(projectSwitch.onChanged, isNull);

    final semantics = tester
        .getSemantics(
          find.byKey(
            const ValueKey<String>('shared-memory-scope-project-switch'),
          ),
        )
        .getSemanticsData();
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);

    handle.dispose();
  });

  testWidgets('forgetting shared facts asks for confirmation first', (
    tester,
  ) async {
    var forgotten = 0;
    await _pump(tester, _ready(onForget: () => forgotten++));

    final button = find.byKey(const ValueKey<String>('forget-shared-facts'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('Forget shared facts?'), findsOneWidget);
    expect(find.textContaining('This removes 3 shared facts.'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(forgotten, 0);

    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();

    expect(forgotten, 1);
  });

  testWidgets('forget is disabled when nothing is shared', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _ready(factCount: 0, onForget: () {}));

    final button = tester.widget<OButton>(
      find.byKey(const ValueKey<String>('forget-shared-facts')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('There are no shared facts to forget.'), findsOneWidget);

    final semantics = tester
        .getSemantics(find.byKey(const ValueKey<String>('forget-shared-facts')))
        .getSemanticsData();
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);

    handle.dispose();
  });

  testWidgets('renders the empty state and turns sharing on', (tester) async {
    var enabled = 0;
    await _pump(
      tester,
      V2SharedMemoryPageData(
        status: V2SharedMemoryStatus.empty,
        onEnabledChanged: (_) => enabled++,
      ),
    );

    expect(find.text('Nothing is shared yet'), findsOneWidget);
    await tester.tap(find.text('Turn on sharing'));
    await tester.pumpAndSettle();

    expect(enabled, 1);
  });

  testWidgets('empty state falls back to refresh without a toggle callback', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      const V2SharedMemoryPageData(status: V2SharedMemoryStatus.empty),
    );

    expect(find.text('Nothing is shared yet'), findsOneWidget);
    final refresh = tester.widget<OButton>(
      find.widgetWithText(OButton, 'Refresh'),
    );
    expect(refresh.onPressed, isNull);

    await _pump(
      tester,
      V2SharedMemoryPageData(
        status: V2SharedMemoryStatus.empty,
        onRetry: () => retries++,
      ),
    );
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(retries, 1);
  });

  testWidgets('renders the error state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      V2SharedMemoryPageData(
        status: V2SharedMemoryStatus.error,
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('We could not load shared memory.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('loading shows skeleton rows', (tester) async {
    await _pump(
      tester,
      const V2SharedMemoryPageData(status: V2SharedMemoryStatus.loading),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pump(
        tester,
        _ready(
          onEnabledChanged: (_) {},
          onScopeChanged: (_, _) {},
          onForget: () {},
        ),
        dark: dark,
        size: const Size(320, 640),
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('This chat'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('forget-shared-facts')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Forget shared facts'), findsOneWidget);
    });
  }

  testWidgets('the forget dialog fits 320 dp at 200% text', (tester) async {
    await _pump(
      tester,
      _ready(onForget: () {}),
      size: const Size(320, 640),
      textScale: 2,
    );

    final button = find.byKey(const ValueKey<String>('forget-shared-facts'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('Forget shared facts?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps every section', (tester) async {
    await _pump(tester, _ready(), reduceMotion: true);

    for (final label in const [
      'What shared memory does',
      'SCOPES',
      'This chat',
      'Project',
      'Global',
      'Forget shared facts',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label is hidden');
    }
  });

  testWidgets('unwired master toggle is announced as disabled', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _ready(enabled: false, factCount: 0));

    final semantics = tester
        .getSemantics(
          find.byKey(const ValueKey<String>('shared-memory-master-switch')),
        )
        .getSemanticsData();
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);

    handle.dispose();
  });
}
