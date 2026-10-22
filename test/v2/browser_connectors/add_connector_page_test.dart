import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/add_connector_page.dart';

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

V2AddConnectorData _data({
  V2AddConnectorStatus status = V2AddConnectorStatus.content,
  bool? testResult,
  bool testing = false,
  V2ConnectorPlan plan = V2ConnectorPlan.plus,
  int used = 0,
  V2ConnectorTarget target = V2ConnectorTarget.url,
  V2ConnectorAuth auth = V2ConnectorAuth.apiKey,
  bool? planLimitReached,
  String planLimitMessage = '',
}) {
  return V2AddConnectorData(
    status: status,
    testResult: testResult,
    testing: testing,
    plan: plan,
    customConnectorsUsed: used,
    target: target,
    auth: auth,
    planLimitReached: planLimitReached,
    planLimitMessage: planLimitMessage,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(_app(child, theme: theme));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

/// Pumps a 320 dp wide phone. The text scaler is injected below the
/// `MaterialApp` because the app rebuilds its own `MediaQuery` from the view.
Future<void> _pumpCompact(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double scale = 2,
}) async {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 720),
          textScaler: TextScaler.linear(scale),
        ),
        child: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> _enterCustom(
  WidgetTester tester, {
  required String name,
  required String endpoint,
  bool command = false,
  String key = 'sk-test-key',
}) async {
  // Start from the top: a previous call may have scrolled to the key field,
  // which disposes the name field in a lazy list.
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.enterText(find.byKey(const Key('add-connector-name')), name);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.enterText(
    find.byKey(Key(command ? 'add-connector-command' : 'add-connector-url')),
    endpoint,
  );
  await tester.pump(const Duration(milliseconds: 200));
  final keyField = find.byKey(const Key('add-connector-key'));
  if (key.isNotEmpty && keyField.evaluate().isNotEmpty) {
    await tester.ensureVisible(keyField);
    await tester.enterText(keyField, key);
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('connector-save')));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('the form is name, URL, key, three grants and a test', (
    tester,
  ) async {
    await _pump(tester, AddConnectorPage(data: _data()));

    expect(find.text('Add connector'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);

    // The catalog browser, suggestion grid, plan banner and safety cards are
    // gone; the form is the whole screen.
    expect(find.text('FROM THE CATALOG'), findsNothing);
    expect(find.text('Safe install'), findsNothing);
    expect(find.text('Custom connectors'), findsNothing);
    expect(find.textContaining('never installs'), findsNothing);
    expect(find.text('Supabase'), findsNothing);
    expect(find.text('Set up'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Test connection'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Test connection'), findsOneWidget);

    for (final title in ['Read data', 'Write & update', 'Execute actions']) {
      await tester.scrollUntilVisible(
        find.text(title),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsOneWidget);
    }
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.byKey(const Key('connector-save')), findsOneWidget);
  });

  testWidgets('add connector renders in dark theme', (tester) async {
    await _pump(tester, AddConnectorPage(data: _data()), theme: OTheme.dark());

    expect(find.text('Add connector'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
  });

  testWidgets('Free plan shows the cap line and blocks save', (tester) async {
    var upgrades = 0;
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(plan: V2ConnectorPlan.free),
        onSave: (draft) => saved = draft,
        onUpgrade: () => upgrades++,
      ),
    );

    expect(find.byKey(const Key('connector-cap-notice')), findsOneWidget);
    expect(find.text('No custom connectors on Free.'), findsOneWidget);
    expect(
      tester
          .widget<OIconButton>(find.byKey(const Key('connector-save')))
          .onPressed,
      isNull,
    );

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test/v1',
    );
    await _save(tester);
    expect(saved, isNull, reason: 'Free has no custom-connector slots');

    // The form scrolled to the key field; go back up to the cap line.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('connector-cap-upgrade')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(upgrades, 1);
  });

  testWidgets('Go plan saves under 5 slots and caps at 5', (tester) async {
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(plan: V2ConnectorPlan.go, used: 2),
        onSave: (draft) => saved = draft,
      ),
    );

    expect(find.byKey(const Key('connector-cap-notice')), findsNothing);

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test/v1',
    );
    await _save(tester);
    expect(saved, isNotNull);

    await _pump(
      tester,
      AddConnectorPage(
        data: _data(plan: V2ConnectorPlan.go, used: 5),
        onSave: (draft) => saved = draft,
      ),
    );
    expect(find.text('All 5 custom slots used on Go.'), findsOneWidget);
  });

  testWidgets('Plus and Pro both show the 20 connector allowance', (
    tester,
  ) async {
    await _pump(
      tester,
      AddConnectorPage(data: _data(plan: V2ConnectorPlan.plus, used: 3)),
    );
    expect(find.byKey(const Key('connector-cap-notice')), findsNothing);

    await _pump(
      tester,
      AddConnectorPage(data: _data(plan: V2ConnectorPlan.pro, used: 20)),
    );
    expect(
      find.text('All 20 custom slots used on Pro.'),
      findsOneWidget,
    );
  });

  testWidgets('validation rejects shell metacharacters', (tester) async {
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(data: _data(), onSave: (draft) => saved = draft),
    );

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test; rm -rf /',
    );

    expect(find.byKey(const Key('custom-connector-error')), findsOneWidget);
    expect(find.textContaining('Remove shell characters'), findsOneWidget);
    await _save(tester);
    expect(saved, isNull);

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test/v1',
    );
    expect(find.byKey(const Key('custom-connector-error')), findsNothing);
    await _save(tester);
    expect(saved, isNotNull);
    expect(saved!.url, 'https://api.internal.test/v1');
  });

  testWidgets('a command cannot name a path outside the workspace', (
    tester,
  ) async {
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(target: V2ConnectorTarget.command),
        onSave: (draft) => saved = draft,
      ),
    );

    expect(find.text('Command'), findsOneWidget);
    await _enterCustom(
      tester,
      name: 'Local tools',
      endpoint: 'node /etc/passwd',
      command: true,
    );

    expect(find.byKey(const Key('custom-connector-error')), findsOneWidget);
    expect(
      find.text('Use a path inside your workspace.'),
      findsOneWidget,
    );
    await _save(tester);
    expect(saved, isNull);

    await _enterCustom(
      tester,
      name: 'Local tools',
      endpoint: 'node /workspace/server.js',
      command: true,
    );
    expect(find.byKey(const Key('custom-connector-error')), findsNothing);
    await _save(tester);
    expect(saved, isNotNull);
    expect(saved!.target, V2ConnectorTarget.command);
    expect(saved!.command, 'node /workspace/server.js');
  });

  testWidgets('test connection is wired and shows the result', (tester) async {
    V2CustomConnectorDraft? tested;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(testResult: true),
        onTestConnection: (draft) => tested = draft,
      ),
    );

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test/v1',
    );
    await tester.scrollUntilVisible(
      find.text('Test connection'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Test connection'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Test connection'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tested, isNotNull);
    expect(tested!.url, 'https://api.internal.test/v1');
    expect(find.text('Connection works.'), findsOneWidget);
  });

  testWidgets('the blocked state explains that chat cannot install plugins', (
    tester,
  ) async {
    var backs = 0;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(status: V2AddConnectorStatus.blocked),
        onBack: () => backs++,
      ),
    );

    expect(find.text('Add connectors here'), findsOneWidget);
    expect(
      find.text('Ovid never installs connectors from chat.'),
      findsOneWidget,
    );
    expect(find.text('Back to connectors'), findsOneWidget);

    await tester.tap(find.text('Back to connectors'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backs, 1);
  });

  testWidgets('execute permission switch reports the new value', (
    tester,
  ) async {
    V2ConnectorPermissionKind? kind;
    bool? value;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(),
        onPermissionChanged: (changedKind, changedValue) {
          kind = changedKind;
          value = changedValue;
        },
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Execute actions'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byType(Switch).last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(Switch).last);
    await tester.pump(const Duration(milliseconds: 300));

    expect(kind, V2ConnectorPermissionKind.execute);
    expect(value, isTrue);
  });

  testWidgets('OAuth setup shows a sign-in line instead of a key field', (
    tester,
  ) async {
    await _pump(
      tester,
      AddConnectorPage(data: _data(auth: V2ConnectorAuth.oauth)),
    );

    expect(find.byKey(const Key('add-connector-key')), findsNothing);
    expect(find.text('Sign in after saving.'), findsOneWidget);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(status: V2AddConnectorStatus.error),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('That did not work'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pumpCompact(
        tester,
        AddConnectorPage(data: _data(testResult: false)),
        theme: dark ? OTheme.dark() : OTheme.light(),
      );

      // Walk the whole page so every lazily built child lays out.
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('the Free cap fits 320 dp at 200% text', (tester) async {
    await _pumpCompact(
      tester,
      AddConnectorPage(data: _data(plan: V2ConnectorPlan.free)),
    );
    expect(find.text('No custom connectors on Free.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the blocked state fits 320 dp at 200% text', (tester) async {
    await _pumpCompact(
      tester,
      AddConnectorPage(data: _data(status: V2AddConnectorStatus.blocked)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the permission labels stay readable at 320 dp with 200% text', (
    tester,
  ) async {
    await _pumpCompact(tester, AddConnectorPage(data: _data()));

    await tester.scrollUntilVisible(
      find.text('Execute actions'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));

    for (final label in ['Read data', 'Write & update', 'Execute actions']) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(label).first,
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '$label must not be cut off',
      );
    }
  });

  testWidgets('narrow app bar keeps save reachable without a label', (
    tester,
  ) async {
    await _pumpCompact(tester, AddConnectorPage(data: _data()));

    expect(find.text('Save'), findsNothing);
    expect(find.bySemanticsLabel('Save'), findsOneWidget);
    expect(tester.getSize(find.bySemanticsLabel('Save')), const Size(48, 48));
  });

  testWidgets('save needs a name, a valid endpoint and a key', (tester) async {
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(data: _data(), onSave: (draft) => saved = draft),
    );

    await _save(tester);
    expect(saved, isNull);

    await tester.enterText(
      find.byKey(const Key('add-connector-name')),
      'Internal API',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _save(tester);
    expect(saved, isNull);

    await tester.enterText(
      find.byKey(const Key('add-connector-url')),
      'https://api.internal.test/v1',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _save(tester);
    expect(
      saved,
      isNull,
      reason: 'API-key auth needs a key before the connector can be saved',
    );

    await tester.enterText(
      find.byKey(const Key('add-connector-key')),
      'sk-test-key',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _save(tester);
    expect(saved, isNotNull);
  });

  testWidgets('at 600 dp the form centres in a 640 max width', (tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, AddConnectorPage(data: _data()));

    final list = tester.getRect(find.byType(ListView));
    expect(list.width, lessThanOrEqualTo(640));
    expect(list.center.dx, closeTo(300, 0.5));
    expect(tester.takeException(), isNull);
  });
}
