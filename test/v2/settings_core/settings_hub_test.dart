import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/settings_hub.dart';
import 'package:ovid_ai/ui/v2/settings/settings_search.dart';

V2SettingsHubData _hubData({
  required List<String> taps,
  ValueChanged<bool>? onReasoningChanged,
  VoidCallback? onAddConnector,
  VoidCallback? onRetry,
  VoidCallback? onProfileTap,
  VoidCallback? onSignOut,
  bool showReasoning = true,
}) {
  V2SettingsItem row(
    String id,
    String label,
    IconData icon, {
    String? subtitle,
  }) {
    return V2SettingsItem(
      id: id,
      label: label,
      subtitle: subtitle,
      icon: icon,
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
        row(
          'usage',
          'Usage',
          Icons.data_usage_rounded,
          subtitle: '12.4M of 50M tokens today',
        ),
        row(
          'plan_billing',
          'Plan & billing',
          Icons.credit_card_rounded,
          subtitle: 'Free plan · 3 GB storage',
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
          subtitle: '30 seconds',
        ),
        row(
          'agent_presets',
          'Agent presets',
          Icons.tune_rounded,
          subtitle: 'Tone, speed and persona',
        ),
        row(
          'connectors',
          'Connectors',
          Icons.extension_outlined,
          subtitle: '3 connected · Add or manage',
        ),
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
        row(
          'storage',
          'Storage',
          Icons.cloud_outlined,
          subtitle: '1.2 GB of 3 GB used',
        ),
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
    onReasoningChanged: onReasoningChanged,
    onAddConnector: onAddConnector,
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

void main() {
  testWidgets('renders the profile and every section in light', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
    expect(find.text('aarav@gmail.com'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('MODELS'), findsOneWidget);
    expect(find.text('DATA CONTROL'), findsOneWidget);
    expect(find.text('ADVANCED'), findsOneWidget);
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
    expect(find.text('Response wait limit'), findsOneWidget);
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
    // The search field itself holds the query, so the result row is the last
    // `Storage` text on screen.
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

  testWidgets('a row with no handler is not offered as a result', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
          advanced: const V2SettingsSection(
            title: 'Advanced',
            items: [
              V2SettingsItem(
                id: 'ghost',
                label: 'Ghost row',
                icon: Icons.help_outline_rounded,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // On the hub the dead row is visibly disabled and carries no chevron.
    final rowNode = tester.getSemantics(find.text('Ghost row'));
    expect(rowNode, isSemantics(hasEnabledState: true, isEnabled: false));

    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ghost');
    await tester.pumpAndSettle();

    final result = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Ghost row, Advanced, disabled')),
    );
    expect(result, isSemantics(hasEnabledState: true, isEnabled: false));

    await tester.tap(find.text('Ghost row'));
    await tester.pumpAndSettle();
    // It neither closes search nor pretends to navigate.
    expect(find.byType(SettingsSearchPage), findsOneWidget);
    handle.dispose();
  });

  testWidgets('keeps the canonical row order', (tester) async {
    await tester.pumpWidget(_app(OTheme.light(), _hubData(taps: <String>[])));
    await tester.pumpAndSettle();

    const titles = [
      'Account',
      'Plan & billing',
      'Usage',
      'Credentials',
      'Appearance',
      'Memory',
      'Shared memory',
      'Memory files',
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
    V2SettingsItem row(String id, String label, IconData icon) =>
        V2SettingsItem(id: id, label: label, icon: icon);

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2SettingsHubData(
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

    const order = [
      'Appearance',
      'Memory',
      'Shared memory',
      'Memory files',
      'Show reasoning',
    ];
    var previous = -1.0;
    for (final label in order) {
      final top = tester.getTopLeft(find.text(label)).dy;
      expect(top, greaterThan(previous), reason: '$label should come next');
      previous = top;
    }
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
              ),
              V2SettingsItem(
                id: 'presets',
                label: 'Agent presets',
                icon: Icons.tune_rounded,
              ),
              V2SettingsItem(
                id: 'connectors',
                label: 'Connectors',
                icon: Icons.extension_outlined,
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
    await tester.tap(find.text('Refresh settings'));
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
    expect(find.text('Refresh settings'), findsNothing);
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

  testWidgets('connector add action calls the injected callback', (
    tester,
  ) async {
    var added = 0;
    final taps = <String>[];
    await tester.pumpWidget(
      _app(OTheme.light(), _hubData(taps: taps, onAddConnector: () => added++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();

    expect(added, 1);
    expect(
      taps,
      isNot(contains('connectors')),
      reason: 'the add button must not also open the row',
    );
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

  testWidgets('profile card and log out call the injected callbacks', (
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

    await tester.ensureVisible(find.text('Log out of Aarav Sharma'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out of Aarav Sharma'));
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
                id: 'account',
                label: 'Account',
                subtitle: 'Profile, email and region',
                icon: Icons.manage_accounts_rounded,
                enabled: false,
                onTap: () => taps++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Account'));
    await tester.pump();
    expect(taps, 0);

    final data = tester
        .getSemantics(
          find.bySemanticsLabel(RegExp('Account, Profile, email and region')),
        )
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

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });
}
