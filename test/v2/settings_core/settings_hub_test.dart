import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/settings_hub.dart';
import 'package:ovid_ai/ui/v2/settings/settings_search.dart';

V2SettingsHubData _hubData({
  required List<String> taps,
  ValueChanged<bool>? onReasoningChanged,
  VoidCallback? onRetry,
  VoidCallback? onProfileTap,
  VoidCallback? onSignOut,
  bool showReasoning = true,
}) {
  V2SettingsItem row(
    String id,
    String label,
    IconData icon, {
    String? value,
    String? subtitle,
  }) {
    return V2SettingsItem(
      id: id,
      label: label,
      icon: icon,
      value: value,
      subtitle: subtitle,
      onTap: () => taps.add(id),
    );
  }

  return V2SettingsHubData(
    profile: const V2SettingsProfile(
      name: 'Aarav Sharma',
      email: 'aarav@gmail.com',
      initials: 'AS',
    ),
    // Deliberately shuffled: the hub must restore the canonical order.
    account: V2SettingsSection(
      title: 'Account',
      items: [
        row(
          'credentials',
          'Credentials',
          Icons.key_rounded,
          subtitle: 'Keys and access tokens',
        ),
        row('usage', 'Usage', Icons.data_usage_rounded, value: '12.4M tokens'),
        row(
          'plan_billing',
          'Plan & billing',
          Icons.credit_card_rounded,
          value: 'Free plan · 3 GB',
        ),
        row(
          'account',
          'Account',
          Icons.manage_accounts_rounded,
          subtitle: 'Profile, email and region',
        ),
      ],
    ),
    chat: V2SettingsSection(
      title: 'Chat',
      items: [
        row(
          'appearance',
          'Appearance',
          Icons.palette_outlined,
          subtitle: 'Theme, text size and motion',
        ),
        row(
          'memory',
          'Memory',
          Icons.psychology_outlined,
          subtitle: 'Global and project memory',
        ),
        row(
          'shared_memory',
          'Shared memory',
          Icons.hub_outlined,
          subtitle: 'Share memory with your project',
        ),
        row(
          'memory_files',
          'Memory files',
          Icons.folder_outlined,
          subtitle: '12 saved reference files',
        ),
        V2SettingsItem(
          id: 'show_reasoning',
          label: 'Show reasoning',
          subtitle: 'Show the thinking steps',
          icon: Icons.lightbulb_outline_rounded,
        ),
      ],
    ),
    models: V2SettingsSection(
      title: 'Models',
      items: [
        // Deliberately reversed: Connectors must come first.
        row(
          'response_wait_limit',
          'Response wait limit',
          Icons.timer_outlined,
          value: '30 s',
        ),
        row(
          'agent_presets',
          'Agent presets',
          Icons.tune_rounded,
          subtitle: 'Tone, speed and persona',
        ),
        row('connectors', 'Connectors', Icons.extension_outlined, value: '3'),
      ],
    ),
    dataControl: V2SettingsSection(
      title: 'Data control',
      items: [
        row(
          'export_import',
          'Export or import',
          Icons.import_export_rounded,
          subtitle: '64 MB archive ready',
        ),
        row(
          'permissions',
          'Permissions',
          Icons.security_rounded,
          subtitle: 'Browser, files and connectors',
        ),
        row(
          'crash_reports',
          'Crash reports',
          Icons.bug_report_outlined,
          subtitle: 'Anonymous error reports',
        ),
        row('storage', 'Storage', Icons.cloud_outlined, value: '1.2 of 3 GB'),
        V2SettingsItem(
          id: 'delete_data',
          label: 'Delete data',
          subtitle: 'Remove chats and artifacts',
          icon: Icons.delete_forever_outlined,
          danger: true,
          onTap: () => taps.add('delete_data'),
        ),
        V2SettingsItem(
          id: 'reset_memory',
          label: 'Reset memory',
          subtitle: 'Clear saved context',
          icon: Icons.restart_alt_rounded,
          danger: true,
          onTap: () => taps.add('reset_memory'),
        ),
      ],
    ),
    advanced: V2SettingsSection(
      title: 'Advanced',
      items: [
        row(
          'notifications',
          'Notifications',
          Icons.notifications_none_rounded,
          subtitle: 'Push and background alerts',
        ),
        row(
          'account_health',
          'Account health',
          Icons.health_and_safety_outlined,
          subtitle: 'All services working',
        ),
        row(
          'about',
          'About',
          Icons.info_outline_rounded,
          subtitle: 'Ovid Si v2.4.1 (Android)',
        ),
      ],
    ),
    showReasoning: showReasoning,
    // The hub removes a row whose handler is missing, so the shared fixture
    // wires the reasoning toggle the way the app shell does.
    onReasoningChanged: onReasoningChanged ?? (_) {},
    onProfileTap: onProfileTap,
    onSignOut: onSignOut,
    onRetry: onRetry,
  );
}

Widget _app(
  ThemeData theme,
  V2SettingsHubData data, {
  TextScaler? textScaler,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => textScaler == null && !disableAnimations
          ? SettingsHubPage(data: data)
          : MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: textScaler,
                disableAnimations: disableAnimations,
              ),
              child: SettingsHubPage(data: data),
            ),
    ),
  );
}

void _phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Tall enough that every section is mounted at once, so order assertions do
/// not depend on scroll position.
void _tallSize(WidgetTester tester, {double width = 390}) {
  tester.view.physicalSize = Size(width, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  _cardOrderContract();

  testWidgets('one header, profile row and five sections in light', (
    tester,
  ) async {
    _tallSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-search')), findsOneWidget);

    // The profile row replaces the separate "Account" destination.
    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
    expect(find.text('aarav@gmail.com'), findsNothing);

    for (final title in const [
      'ACCOUNT',
      'CHAT',
      'MODELS',
      'DATA CONTROL',
      'ADVANCED',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Show reasoning'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
  });

  testWidgets('renders correctly in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
  });

  testWidgets('rows carry a value, never a descriptive subtitle', (
    tester,
  ) async {
    _tallSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    // Real values stay.
    expect(find.text('Free plan · 3 GB'), findsOneWidget);
    expect(find.text('12.4M tokens'), findsOneWidget);
    expect(find.text('1.2 of 3 GB'), findsOneWidget);

    // Explanations are deleted.
    expect(find.text('Theme, text size and motion'), findsNothing);
    expect(find.text('Keys and access tokens'), findsNothing);
    expect(find.text('Profile, email and region'), findsNothing);
    expect(find.text('Push and background alerts'), findsNothing);
  });

  testWidgets('memory rows collapse into one Memory row', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: taps)));
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Shared memory'), findsNothing);
    expect(find.text('Memory files'), findsNothing);

    await tester.ensureVisible(find.text('Memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Memory'));
    await tester.pump();

    expect(taps, contains('memory'));
  });

  testWidgets('search opens over the hub sections and runs the row callback', (
    tester,
  ) async {
    _phoneSize(tester);
    final taps = <String>[];
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: taps)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSearchPage), findsOneWidget);
    expect(find.text('Search settings'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Storage');
    await tester.pumpAndSettle();

    expect(find.text('DATA CONTROL'), findsOneWidget);
    expect(find.text('Storage'), findsNWidgets(2));

    await tester.tap(find.text('Storage').last);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSearchPage), findsNothing);
    expect(taps, contains('storage'));
  });

  testWidgets('search toggles show reasoning through the hub callback', (
    tester,
  ) async {
    _phoneSize(tester);
    bool? changed;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _hubData(
          taps: <String>[],
          onReasoningChanged: (value) => changed = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'reasoning');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show reasoning'));
    await tester.pumpAndSettle();

    expect(changed, isFalse);
    expect(find.byType(SettingsSearchPage), findsNothing);
  });

  testWidgets('a search result for a hub-local row scrolls it into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final changed = <bool>[];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _hubData(taps: <String>[], onReasoningChanged: changed.add),
      ),
    );
    await tester.pumpAndSettle();

    final rowKey = const ValueKey<String>('settings-row-show_reasoning');
    // The row starts below the fold: a result that only closes search would
    // leave the person staring at an unchanged screen.
    expect(tester.getTopLeft(find.byKey(rowKey)).dy, greaterThan(500));

    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'reasoning');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show reasoning'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSearchPage), findsNothing);
    expect(changed, <bool>[false]);
    final rect = tester.getRect(find.byKey(rowKey));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(500));
  });

  testWidgets('a row with no handler is removed from the hub and the index', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          advanced: V2SettingsSection(
            title: 'Advanced',
            items: [
              const V2SettingsItem(
                id: 'ghost',
                label: 'Ghost row',
                icon: Icons.help_outline_rounded,
              ),
              V2SettingsItem(
                id: 'about',
                label: 'About',
                icon: Icons.info_outline_rounded,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A row that cannot act is not a disabled control: it is not rendered.
    expect(find.byKey(const ValueKey('settings-row-ghost')), findsNothing);
    expect(find.text('Ghost row'), findsNothing);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('ADVANCED'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ghost');
    await tester.pumpAndSettle();

    // The index is built from the same rows, so the dead row cannot come back
    // as a result that silently goes nowhere.
    expect(find.text('No settings found'), findsOneWidget);
    expect(find.text('Ghost row'), findsNothing);
    handle.dispose();
  });

  testWidgets('the connectors row opens through the host work route', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          onAddConnector: () => taps.add('connectors'),
          models: V2SettingsSection(
            title: 'Models',
            items: [
              // The settings route table has no connectors case; the row is
              // wired through the host's work route instead of being a dead
              // end. No item handler is needed.
              const V2SettingsItem(
                id: 'connectors',
                label: 'Connectors',
                icon: Icons.extension_rounded,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Connectors'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connectors'));
    await tester.pump();

    expect(taps, <String>['connectors']);
  });

  testWidgets('section headings are marked as headers', (tester) async {
    final handle = tester.ensureSemantics();
    _tallSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    for (final label in const [
      'ACCOUNT',
      'CHAT',
      'MODELS',
      'DATA CONTROL',
      'ADVANCED',
    ]) {
      final node = tester.getSemantics(find.text(label)).getSemanticsData();
      expect(
        node.flagsCollection.isHeader,
        isTrue,
        reason: '$label should be announced as a heading',
      );
    }
    handle.dispose();
  });

  testWidgets('rows show real values and never a placeholder', (tester) async {
    _tallSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          profile: const V2SettingsProfile(
            name: 'Aarav Sharma',
            email: 'aarav@gmail.com',
            planLabel: 'Plus',
          ),
          storageLabel: '1.2 of 15 GB',
          account: V2SettingsSection(
            title: 'Account',
            items: [
              V2SettingsItem(
                id: 'plan_billing',
                label: 'Plan & billing',
                icon: Icons.credit_card_rounded,
                onTap: () {},
              ),
            ],
          ),
          dataControl: V2SettingsSection(
            title: 'Data control',
            items: [
              V2SettingsItem(
                id: 'storage',
                label: 'Storage',
                icon: Icons.storage_rounded,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The plan pill and the plan row both name the real plan.
    expect(find.text('Plus'), findsNWidgets(2));
    expect(find.text('1.2 of 15 GB'), findsOneWidget);

    final row = tester
        .getSemantics(find.byKey(const ValueKey('settings-row-storage')))
        .getSemanticsData();
    expect(row.label, 'Storage, 1.2 of 15 GB');
  });

  testWidgets('an unknown value is left blank, not filled with a placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          dataControl: V2SettingsSection(
            title: 'Data control',
            items: [
              V2SettingsItem(
                id: 'storage',
                label: 'Storage',
                icon: Icons.storage_rounded,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('0 MB'), findsNothing);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('a profile without a destination is not a disabled control', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        const V2SettingsHubData(
          profile: V2SettingsProfile(
            name: 'Aarav Sharma',
            email: 'aarav@gmail.com',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final node = tester
        .getSemantics(find.text('Aarav Sharma'))
        .getSemanticsData();
    expect(node.label, 'Aarav Sharma, Free plan');
    // Informational identity, not a greyed-out button.
    expect(node.flagsCollection.isEnabled.toBoolOrNull(), isNull);
    expect(node.flagsCollection.isButton, isFalse);
    handle.dispose();
  });

  testWidgets('keeps the canonical row order', (tester) async {
    _tallSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    const titles = [
      'Plan & billing',
      'Usage',
      'Credentials',
      'Appearance',
      'Memory',
      'Show reasoning',
      'Connectors',
      'Agent presets',
      'Response wait limit',
      'Export or import',
      'Permissions',
      'Crash reports',
      'Storage',
      'Delete data',
      'Reset memory',
      'Notifications',
      'Account health',
      'About',
    ];

    var previous = -1.0;
    for (final title in titles) {
      final top = tester.getTopLeft(find.text(title)).dy;
      expect(top, greaterThan(previous), reason: '$title should come next');
      previous = top;
    }
  });

  testWidgets('restores the personalization order from any input order', (
    tester,
  ) async {
    _tallSize(tester);
    V2SettingsItem row(String id, String label, IconData icon) =>
        V2SettingsItem(id: id, label: label, icon: icon, onTap: () {});

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          onReasoningChanged: (_) {},
          chat: V2SettingsSection(
            title: 'Chat',
            items: [
              row(
                'show_reasoning',
                'Show reasoning',
                Icons.lightbulb_outline_rounded,
              ),
              row('memory_files', 'Memory files', Icons.folder_outlined),
              row('memory', 'Memory', Icons.psychology_outlined),
              row('shared_memory', 'Shared memory', Icons.hub_outlined),
              row('appearance', 'Appearance', Icons.palette_outlined),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const order = ['Appearance', 'Memory', 'Show reasoning'];
    var previous = -1.0;
    for (final label in order) {
      final top = tester.getTopLeft(find.text(label)).dy;
      expect(top, greaterThan(previous), reason: '$label should come next');
      previous = top;
    }
    expect(find.text('Shared memory'), findsNothing);
    expect(find.text('Memory files'), findsNothing);
  });

  testWidgets('show reasoning is on by default', (tester) async {
    expect(const V2SettingsHubData().showReasoning, isTrue);

    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets(
    'models card sits above data control and starts with connectors',
    (tester) async {
      _tallSize(tester);
      await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
      await tester.pumpAndSettle();

      final account = tester.getTopLeft(find.text('ACCOUNT')).dy;
      final chat = tester.getTopLeft(find.text('CHAT')).dy;
      final models = tester.getTopLeft(find.text('MODELS')).dy;
      final dataControl = tester.getTopLeft(find.text('DATA CONTROL')).dy;
      final advanced = tester.getTopLeft(find.text('ADVANCED')).dy;

      expect(account, lessThan(chat));
      expect(chat, lessThan(models));
      expect(models, lessThan(dataControl));
      expect(dataControl, lessThan(advanced));

      final connectors = tester.getTopLeft(find.text('Connectors')).dy;
      final presets = tester.getTopLeft(find.text('Agent presets')).dy;
      final wait = tester.getTopLeft(find.text('Response wait limit')).dy;
      expect(connectors, lessThan(presets));
      expect(presets, lessThan(wait));
      expect(wait, lessThan(dataControl));
    },
  );

  testWidgets('short wiring ids still land in the canonical models order', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          profile: const V2SettingsProfile(
            name: 'Aarav Sharma',
            email: 'aarav@gmail.com',
          ),
          models: V2SettingsSection(
            title: 'Models',
            items: [
              V2SettingsItem(
                id: 'response_wait',
                label: 'Response wait limit',
                icon: Icons.timer_outlined,
                onTap: () {},
              ),
              V2SettingsItem(
                id: 'presets',
                label: 'Agent presets',
                icon: Icons.tune_rounded,
                onTap: () {},
              ),
              V2SettingsItem(
                id: 'connectors',
                label: 'Connectors',
                icon: Icons.extension_outlined,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final connectors = tester.getTopLeft(find.text('Connectors')).dy;
    final presets = tester.getTopLeft(find.text('Agent presets')).dy;
    final wait = tester.getTopLeft(find.text('Response wait limit')).dy;
    expect(connectors, lessThan(presets));
    expect(presets, lessThan(wait));
  });

  testWidgets('empty state action fires', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          status: V2SettingsHubStatus.empty,
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No settings yet'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('empty state without a retry offers no dead button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        const V2SettingsHubData(status: V2SettingsHubStatus.empty),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No settings yet'), findsOneWidget);
    expect(find.text('Refresh'), findsNothing);
  });

  testWidgets('row tap calls the injected callback', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: taps)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Plan & billing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan & billing'));
    await tester.pump();

    expect(taps, contains('plan_billing'));
  });

  testWidgets('reasoning toggle calls the injected callback', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _hubData(taps: <String>[], onReasoningChanged: changes.add),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(changes, [false]);
  });

  testWidgets('the connectors row keeps one action: open connectors', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: taps)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Connectors'));
    await tester.pumpAndSettle();
    // Adding a connector lives on the Connectors page, not as a second action
    // inside a settings row.
    expect(find.byIcon(Icons.add_rounded), findsNothing);

    await tester.tap(find.text('Connectors'));
    await tester.pump();

    expect(taps, contains('connectors'));
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(
          dark ? OTheme.dark() : OTheme.light(),
          _hubData(taps: <String>[], onSignOut: () {}),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'content overflowed at 320 dp / 200 % text',
      );
    });
  }

  testWidgets('every state fits 320 dp at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final scenarios = <String, V2SettingsHubData>{
      'loading': const V2SettingsHubData(status: V2SettingsHubStatus.loading),
      'empty': const V2SettingsHubData(status: V2SettingsHubStatus.empty),
      'error': const V2SettingsHubData(
        status: V2SettingsHubStatus.error,
        errorMessage:
            'We could not load your settings. Check your connection and try again.',
      ),
      'ready but empty': const V2SettingsHubData(),
    };

    for (final entry in scenarios.entries) {
      await tester.pumpWidget(
        _app(
          OTheme.light(),
          entry.value,
          textScaler: const TextScaler.linear(2),
        ),
      );
      // The loading skeleton shimmers forever, so never wait for settle there.
      if (entry.key == 'loading') {
        await tester.pump(const Duration(milliseconds: 300));
      } else {
        await tester.pumpAndSettle();
      }
      expect(
        tester.takeException(),
        isNull,
        reason: '${entry.key} overflowed at 320 dp / 200 % text',
      );
    }
  });

  testWidgets('profile row and sign out call the injected callbacks', (
    tester,
  ) async {
    var profileTaps = 0;
    var signOuts = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _hubData(
          taps: <String>[],
          onProfileTap: () => profileTaps++,
          onSignOut: () => signOuts++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Aarav Sharma'));
    await tester.pump();
    expect(profileTaps, 1);

    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(signOuts, 1);
  });

  testWidgets('a disabled row does not fire and is announced disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          profile: const V2SettingsProfile(
            name: 'Aarav Sharma',
            email: 'aarav@gmail.com',
          ),
          account: V2SettingsSection(
            title: 'Account',
            items: [
              V2SettingsItem(
                id: 'plan_billing',
                label: 'Plan & billing',
                icon: Icons.credit_card_rounded,
                enabled: false,
                onTap: () => taps++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Plan & billing'));
    await tester.pump();
    expect(taps, 0);

    final data = tester
        .getSemantics(find.byKey(const ValueKey('settings-row-plan_billing')))
        .getSemanticsData();
    expect(data.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
    handle.dispose();
  });

  testWidgets('loading state shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        const V2SettingsHubData(status: V2SettingsHubStatus.loading),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('reduced motion still shows every row', (tester) async {
    await tester.pumpWidget(
      _app(OTheme.light(), _hubData(taps: <String>[]), disableAnimations: true),
    );
    await tester.pump();

    expect(find.text('About'), findsOneWidget);
    expect(
      find.byType(AnimatedOpacity),
      findsNothing,
      reason: 'reduced motion should skip the entrance fade, not hide content',
    );
  });

  testWidgets('error state retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          status: V2SettingsHubStatus.error,
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('That did not work'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });

  for (final width in <double>[320, 360, 412, 600, 800, 1024, 1280]) {
    testWidgets('content is centred and capped at $width dp', (tester) async {
      _tallSize(tester, width: width);
      await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
      await tester.pumpAndSettle();

      final row = tester.getRect(
        find.byKey(const ValueKey('settings-row-plan_billing')),
      );
      final limit = width >= 900
          ? 720.0
          : width >= 600
          ? 640.0
          : width;

      expect(row.width, lessThanOrEqualTo(limit));
      expect(row.width, lessThan(width), reason: 'rows must not stretch');
      expect(
        row.center.dx,
        moreOrLessEquals(width / 2, epsilon: 1),
        reason: 'content must be centred, not left aligned',
      );
    });
  }

  for (final dark in <bool>[false, true]) {
    for (final width in <double>[320, 600, 1280]) {
      testWidgets('fits $width dp at 200% text (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 2600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _app(
            dark ? OTheme.dark() : OTheme.light(),
            _hubData(taps: <String>[], onSignOut: () {}),
            textScaler: const TextScaler.linear(2),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: 'content overflowed at $width dp / 200 % text',
        );
      });
    }
  }
}

// The owner's card order: Account -> Personalization -> Connectors -> Models
// -> Data control -> Advanced. Models must sit ABOVE Data control, and
// Connectors gets its own card instead of hiding inside Models.
void _cardOrderContract() {
  test('the hub data exposes the spec card order', () {
    final data = V2SettingsHubData(
      account: const V2SettingsSection(title: 'Account'),
      chat: const V2SettingsSection(title: 'Personalization'),
      connectors: const V2SettingsSection(title: 'Connectors'),
      models: const V2SettingsSection(title: 'Models'),
      dataControl: const V2SettingsSection(title: 'Data control'),
      advanced: const V2SettingsSection(title: 'Advanced'),
    );
    expect(
      data.sections.map((s) => s.title).toList(),
      [
        'Account',
        'Personalization',
        'Connectors',
        'Models',
        'Data control',
        'Advanced',
      ],
    );
  });
}
