import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/add_connector_page.dart';

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

const _suggestions = <V2ConnectorSuggestion>[
  V2ConnectorSuggestion(
    id: 'supabase',
    name: 'Supabase',
    description: 'PostgreSQL database and auth',
    icon: Icons.storage_rounded,
  ),
  V2ConnectorSuggestion(
    id: 'figma',
    name: 'Figma',
    description: 'Inspect files and export components',
    icon: Icons.draw_outlined,
  ),
  V2ConnectorSuggestion(
    id: 'discord',
    name: 'Discord',
    description: 'Community agent webhook',
    icon: Icons.forum_outlined,
  ),
];

V2AddConnectorData _data({
  V2AddConnectorStatus status = V2AddConnectorStatus.content,
  List<V2ConnectorSuggestion> suggestions = _suggestions,
  bool? testResult,
  bool testing = false,
  V2ConnectorPlan plan = V2ConnectorPlan.plus,
  int used = 0,
  V2ConnectorTarget target = V2ConnectorTarget.url,
  bool? planLimitReached,
  String planNote = '',
  String planLimitMessage = '',
}) {
  return V2AddConnectorData(
    suggestions: suggestions,
    status: status,
    testResult: testResult,
    testing: testing,
    plan: plan,
    customConnectorsUsed: used,
    target: target,
    planLimitReached: planLimitReached,
    planNote: planNote,
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
  if (command) {
    final choice = find.byKey(const Key('target-command'));
    await tester.scrollUntilVisible(
      choice,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(choice);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(choice);
    await tester.pump(const Duration(milliseconds: 200));
  }
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

void main() {
  testWidgets('add connector shows the plan, safe-install and custom form', (
    tester,
  ) async {
    await _pump(tester, AddConnectorPage(data: _data()));

    expect(find.text('Add connector'), findsOneWidget);
    expect(find.byKey(const Key('connector-plan-banner')), findsOneWidget);
    expect(find.text('Custom connectors'), findsOneWidget);
    expect(find.text('0 of 20 custom connectors used on Plus.'), findsOneWidget);
    expect(find.byKey(const Key('chat-install-blocked')), findsOneWidget);
    expect(
      find.textContaining('never installs plugins or connectors from a chat'),
      findsOneWidget,
    );
    expect(find.text('FROM THE CATALOG'), findsOneWidget);
    expect(find.text('Supabase'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Server address'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Test connection'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Test connection'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Execute actions'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Execute actions'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('safe-install-note')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('safe-install-note')), findsOneWidget);
    expect(find.text('Safe install'), findsOneWidget);
  });

  testWidgets('add connector renders in dark theme', (tester) async {
    await _pump(tester, AddConnectorPage(data: _data()), theme: OTheme.dark());

    expect(find.text('Add connector'), findsOneWidget);
    expect(find.text('Supabase'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
  });

  testWidgets('Free plan blocks custom connectors and offers an upgrade', (
    tester,
  ) async {
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

    expect(find.text('Plan limit reached'), findsOneWidget);
    expect(
      find.textContaining('not available on the Free plan'),
      findsWidgets,
    );
    expect(find.textContaining('Upgrade to Go to add up to 5'), findsWidgets);

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test/v1',
    );
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNull, reason: 'Free has no custom-connector slots');

    // Scroll back to the top: the form helper moved the banner off-screen and
    // a ListView disposes children that are far out of view.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 400));
    final bannerUpgrade = find.descendant(
      of: find.byKey(const Key('connector-plan-banner')),
      matching: find.text('Upgrade'),
    );
    await tester.ensureVisible(bannerUpgrade);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(bannerUpgrade);
    await tester.pump(const Duration(milliseconds: 300));
    expect(upgrades, 1);
  });

  testWidgets('Go plan shows 5 slots and blocks at the limit', (tester) async {
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(plan: V2ConnectorPlan.go, used: 2),
        onSave: (draft) => saved = draft,
      ),
    );

    expect(find.text('2 of 5 custom connectors used on Go.'), findsOneWidget);
    expect(find.text('3 slots left.'), findsOneWidget);

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test/v1',
    );
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNotNull);

    await _pump(
      tester,
      AddConnectorPage(
        data: _data(plan: V2ConnectorPlan.go, used: 5),
        onSave: (draft) => saved = draft,
      ),
    );
    await tester.drag(
      find.byType(Scrollable).first,
      const Offset(0, 3000),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Plan limit reached'), findsOneWidget);
    expect(
      find.textContaining('You have used all 5 custom connectors on the Go plan.'),
      findsWidgets,
    );
  });

  testWidgets('Plus and Pro both show the 20 connector allowance', (
    tester,
  ) async {
    await _pump(
      tester,
      AddConnectorPage(data: _data(plan: V2ConnectorPlan.plus, used: 3)),
    );
    expect(find.text('3 of 20 custom connectors used on Plus.'), findsOneWidget);
    expect(find.text('17 slots left.'), findsOneWidget);

    await _pump(
      tester,
      AddConnectorPage(data: _data(plan: V2ConnectorPlan.pro, used: 20)),
    );
    expect(find.text('Plan limit reached'), findsOneWidget);
    expect(
      find.textContaining('You have used all 20 custom connectors on Pro.'),
      findsWidgets,
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
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNull);

    await _enterCustom(
      tester,
      name: 'Internal API',
      endpoint: 'https://api.internal.test/v1',
    );
    expect(find.byKey(const Key('custom-connector-error')), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNotNull);
    expect(saved!.url, 'https://api.internal.test/v1');
  });

  testWidgets('a command cannot name a path outside the workspace', (
    tester,
  ) async {
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(data: _data(), onSave: (draft) => saved = draft),
    );

    await _enterCustom(
      tester,
      name: 'Local tools',
      endpoint: 'node /etc/passwd',
      command: true,
    );

    expect(find.byKey(const Key('custom-connector-error')), findsOneWidget);
    expect(
      find.text(
        'Use a path inside your workspace. Paths like ../ or /etc are not '
        'allowed.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNull);

    await _enterCustom(
      tester,
      name: 'Local tools',
      endpoint: 'node /workspace/server.js',
      command: true,
    );
    expect(find.byKey(const Key('custom-connector-error')), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
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
    expect(
      find.text('Connection works. You can save this connector.'),
      findsOneWidget,
    );
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

    expect(find.text('Plugins are added here, not in chat'), findsOneWidget);
    expect(
      find.textContaining('never installs plugins or connectors from a chat'),
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

  testWidgets('choosing sign-in explains that auth is required', (
    tester,
  ) async {
    V2ConnectorAuth? auth;
    await _pump(
      tester,
      AddConnectorPage(data: _data(), onAuthChanged: (value) => auth = value),
    );

    await tester.scrollUntilVisible(
      find.text('OAuth'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('OAuth'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('OAuth'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(auth, V2ConnectorAuth.oauth);
    expect(
      find.text('This app needs a sign-in. You will sign in after you save.'),
      findsOneWidget,
    );
  });

  testWidgets('a catalog suggestion fires its add callback', (tester) async {
    String? added;
    await _pump(
      tester,
      AddConnectorPage(data: _data(), onAddSuggested: (id) => added = id),
    );

    await tester.tap(find.text('Set up').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(added, 'supabase');
  });

  testWidgets('adding a suggestion fills the name field', (tester) async {
    await _pump(
      tester,
      AddConnectorPage(data: _data(), onAddSuggested: (_) {}),
    );

    await tester.tap(find.text('Set up').first);
    await tester.pump(const Duration(milliseconds: 300));

    final field = tester.widget<TextField>(
      find.byKey(const Key('add-connector-name')),
    );
    expect(field.controller?.text, 'Supabase');
  });

  testWidgets('empty catalog suggests a way out and fires it', (tester) async {
    String? query;
    await _pump(
      tester,
      AddConnectorPage(
        data: _data(suggestions: const []),
        onSearchChanged: (value) => query = value,
      ),
    );

    expect(find.text('No suggestions'), findsOneWidget);
    expect(find.text('Clear search'), findsOneWidget);

    await tester.tap(find.text('Clear search'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(query, '');
  });

  testWidgets('a missing plan note hides the note row', (tester) async {
    await _pump(tester, AddConnectorPage(data: _data(planNote: '')));

    expect(find.textContaining('Custom connectors —'), findsNothing);
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

    expect(find.text('Something went wrong'), findsOneWidget);
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

  testWidgets('the blocked state fits 320 dp at 200% text', (tester) async {
    await _pumpCompact(
      tester,
      AddConnectorPage(data: _data(status: V2AddConnectorStatus.blocked)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('auth choices stay readable at 320 dp with 200% text', (
    tester,
  ) async {
    await _pumpCompact(tester, AddConnectorPage(data: _data()), scale: 2);

    await tester.scrollUntilVisible(
      find.text('Test connection'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));

    for (final label in ['OAuth', 'API key', 'None']) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(label).first,
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '$label must not be cut off',
      );
    }

    // The three segments no longer fit side by side, so they stack instead of
    // clipping: each choice sits on its own row.
    final oauth = tester.getCenter(find.text('OAuth').first);
    final key = tester.getCenter(find.text('API key').first);
    final none = tester.getCenter(find.text('None').first);
    expect(oauth.dy, lessThan(key.dy));
    expect(key.dy, lessThan(none.dy));
  });

  testWidgets('auth choices share one row at normal text sizes', (
    tester,
  ) async {
    await _pump(tester, AddConnectorPage(data: _data()));

    await tester.scrollUntilVisible(
      find.text('Test connection'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));

    final oauth = tester.getCenter(find.text('OAuth').first);
    final key = tester.getCenter(find.text('API key').first);
    final none = tester.getCenter(find.text('None').first);
    expect(oauth.dy, key.dy);
    expect(key.dy, none.dy);
  });

  testWidgets('narrow app bar keeps save reachable without a label', (
    tester,
  ) async {
    await _pumpCompact(tester, AddConnectorPage(data: _data()));

    // The labelled pill would squeeze the title, so the icon control stands in
    // with the same 48 dp target and the same screen-reader label.
    expect(find.text('Save'), findsNothing);
    expect(find.bySemanticsLabel('Save'), findsOneWidget);
    expect(tester.getSize(find.bySemanticsLabel('Save')), const Size(48, 48));
  });

  testWidgets('save needs a name and a valid endpoint', (tester) async {
    V2CustomConnectorDraft? saved;
    await _pump(
      tester,
      AddConnectorPage(data: _data(), onSave: (draft) => saved = draft),
    );

    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNull);

    await tester.enterText(
      find.byKey(const Key('add-connector-name')),
      'Internal API',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNull);

    await tester.enterText(
      find.byKey(const Key('add-connector-url')),
      'https://api.internal.test/v1',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
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
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved, isNotNull);
  });
}
