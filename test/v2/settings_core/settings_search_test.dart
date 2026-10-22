import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/settings_hub.dart';
import 'package:ovid_ai/ui/v2/settings/settings_search.dart';

V2SettingsSearchData _data({
  V2SettingsSearchStatus status = V2SettingsSearchStatus.ready,
  String initialQuery = '',
  String? errorMessage,
  List<V2SettingsSection>? sections,
  bool Function(V2SettingsItem item)? canActivate,
}) {
  V2SettingsItem row(
    String id,
    String label,
    IconData icon, {
    String? subtitle,
    bool enabled = true,
  }) {
    return V2SettingsItem(
      id: id,
      label: label,
      subtitle: subtitle,
      icon: icon,
      enabled: enabled,
    );
  }

  return V2SettingsSearchData(
    status: status,
    initialQuery: initialQuery,
    errorMessage: errorMessage,
    canActivate: canActivate,
    sections:
        sections ??
        <V2SettingsSection>[
          V2SettingsSection(
            title: 'Account',
            items: [
              row(
                'account',
                'Account',
                Icons.manage_accounts_rounded,
                subtitle: 'Profile, email and region',
              ),
              row(
                'plan_billing',
                'Plan & billing',
                Icons.credit_card_rounded,
                subtitle: 'Free plan · 3 GB storage',
              ),
              row(
                'usage',
                'Usage',
                Icons.data_usage_rounded,
                subtitle: '12.4M of 50M tokens today',
              ),
            ],
          ),
          V2SettingsSection(
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
            ],
          ),
          V2SettingsSection(
            title: 'Data control',
            items: [
              row(
                'permissions',
                'Permissions',
                Icons.security_rounded,
                subtitle: 'Browser, files and connectors',
              ),
              row(
                'storage',
                'Storage',
                Icons.cloud_outlined,
                subtitle: '1.2 GB of 3 GB used',
              ),
            ],
          ),
          V2SettingsSection(
            title: 'Advanced',
            items: [
              row(
                'notifications',
                'Notifications',
                Icons.notifications_none_rounded,
                subtitle: 'Push and background alerts',
              ),
              row(
                'about',
                'About',
                Icons.info_outline_rounded,
                subtitle: 'Ovid Si v2.4.1 (Android)',
              ),
            ],
          ),
        ],
  );
}

Widget _app(
  ThemeData theme,
  V2SettingsSearchData data, {
  ValueChanged<V2SettingsSearchResult>? onResultTap,
  VoidCallback? onRetry,
  TextScaler? textScaler,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => textScaler == null && !disableAnimations
          ? SettingsSearchPage(
              data: data,
              onResultTap: onResultTap,
              onRetry: onRetry,
            )
          : MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: textScaler,
                disableAnimations: disableAnimations,
              ),
              child: SettingsSearchPage(
                data: data,
                onResultTap: onResultTap,
                onRetry: onRetry,
              ),
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
  group('V2SettingsSearchData', () {
    test('matches row titles case-insensitively', () {
      final results = _data().search('STOR');

      expect(results.map((result) => result.item.id), <String>['storage']);
      expect(results.single.sectionTitle, 'Data control');
    });

    test('matches section titles and returns every row in that section', () {
      final results = _data().search('chat');

      expect(results.map((result) => result.item.id), <String>[
        'appearance',
        'memory',
      ]);
      expect(results.every((result) => result.sectionTitle == 'Chat'), isTrue);
    });

    test('ignores blank queries and surrounding whitespace', () {
      expect(_data().search('   '), isEmpty);
      expect(_data().search(' mem ').map((result) => result.item.id), <String>[
        'memory',
      ]);
    });

    test('keeps index order and groups by section', () {
      final groups = _data().groups('a');

      expect(groups.map((group) => group.sectionTitle), <String>[
        'Account',
        'Chat',
        'Data control',
        'Advanced',
      ]);
      expect(groups.first.results.map((result) => result.item.id), <String>[
        'account',
        'plan_billing',
        'usage',
      ]);
    });

    test('fromHub reuses the hub sections and state', () {
      final data = V2SettingsSearchData.fromHub(
        V2SettingsHubData(
          status: V2SettingsHubStatus.error,
          errorMessage: 'Offline',
          account: V2SettingsSection(
            title: 'Account',
            items: [
              V2SettingsItem(
                id: 'account',
                label: 'Account',
                icon: Icons.manage_accounts_rounded,
              ),
            ],
          ),
        ),
      );

      expect(data.status, V2SettingsSearchStatus.error);
      expect(data.errorMessage, 'Offline');
      expect(data.search('account').single.item.id, 'account');
    });
    test('fromHub only offers rows with a real destination', () {
      final data = V2SettingsSearchData.fromHub(
        V2SettingsHubData(
          account: V2SettingsSection(
            title: 'Account',
            items: [
              V2SettingsItem(
                id: 'account',
                label: 'Account',
                icon: Icons.manage_accounts_rounded,
                onTap: () {},
              ),
              const V2SettingsItem(
                id: 'ghost',
                label: 'Ghost',
                icon: Icons.help_outline_rounded,
              ),
            ],
          ),
          chat: const V2SettingsSection(
            title: 'Chat',
            items: [
              V2SettingsItem(
                id: 'show_reasoning',
                label: 'Show reasoning',
                icon: Icons.lightbulb_outline_rounded,
              ),
            ],
          ),
          onReasoningChanged: (_) {},
        ),
      );

      final account = data.sections.first.items;
      expect(
        data.isActionable(account.first, hasHostHandler: true),
        isTrue,
      );
      expect(
        data.isActionable(account.last, hasHostHandler: true),
        isFalse,
      );
      expect(
        data.isActionable(
          data.sections[1].items.first,
          hasHostHandler: true,
        ),
        isTrue,
      );
    });
  });

  testWidgets('browse state offers tappable section chips', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _data()));
    await tester.pumpAndSettle();

    expect(find.text('Search settings'), findsOneWidget);
    expect(find.text('SECTIONS'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.byType(OChip), findsNWidgets(4));
  });

  testWidgets('tapping a section chip filters without typing', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _data()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Data control'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Data control');
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Plan & billing'), findsNothing);
  });

  testWidgets('typing filters rows and reports the count', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _data()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bill');
    await tester.pumpAndSettle();

    expect(find.text('Plan & billing'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('Storage'), findsNothing);
  });

  testWidgets('section matches list every row in that section', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _data()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'data');
    await tester.pumpAndSettle();
    expect(find.text('DATA CONTROL'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Plan & billing'), findsNothing);
  });

  testWidgets('tapping a result reports it and dismisses the keyboard', (
    tester,
  ) async {
    _phoneSize(tester);
    final opened = <V2SettingsSearchResult>[];
    await tester.pumpWidget(
      _app(OTheme.light(), _data(), onResultTap: opened.add),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'plan');
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);

    await tester.tap(find.text('Plan & billing'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.item.id, 'plan_billing');
    expect(opened.single.sectionTitle, 'Account');
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('a result with no callback still uses the row callback', (
    tester,
  ) async {
    _phoneSize(tester);
    var rowTaps = 0;
    final data = _data(
      sections: <V2SettingsSection>[
        V2SettingsSection(
          title: 'Account',
          items: [
            V2SettingsItem(
              id: 'account',
              label: 'Account',
              icon: Icons.manage_accounts_rounded,
              onTap: () => rowTaps++,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_app(OTheme.light(), data));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'account');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Account'));
    await tester.pump();

    expect(rowTaps, 1);
  });

  testWidgets('no matches shows an empty state that clears the query', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _data()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('No settings found'), findsOneWidget);
    expect(find.textContaining('Nothing matches'), findsOneWidget);

    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();

    expect(find.text('SECTIONS'), findsOneWidget);
    expect(find.byType(OChip), findsNWidgets(4));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('a disabled row does not fire and is announced disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phoneSize(tester);
    var taps = 0;
    final data = _data(
      sections: <V2SettingsSection>[
        V2SettingsSection(
          title: 'Advanced',
          items: [
            V2SettingsItem(
              id: 'locked',
              label: 'Locked row',
              subtitle: 'Paid plan only',
              icon: Icons.lock_outline_rounded,
              enabled: false,
              onTap: () => taps++,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _app(OTheme.light(), data, onResultTap: (_) => taps++),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'locked');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Locked row'));
    await tester.pump();

    expect(taps, 0);
    final semantics = tester
        .getSemantics(find.byKey(const ValueKey('search-result-locked')))
        .getSemanticsData();
    expect(semantics.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
    handle.dispose();
  });

  testWidgets('a row the host cannot activate is not a tap target', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phoneSize(tester);
    final opened = <V2SettingsSearchResult>[];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        // The hub knows this row has nowhere to go.
        _data(canActivate: (item) => item.id != 'storage'),
        onResultTap: opened.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'storage');
    await tester.pumpAndSettle();

    final node = tester.getSemantics(
      find.byKey(const ValueKey('search-result-storage')),
    );
    expect(node, isSemantics(hasEnabledState: true, isEnabled: false));

    await tester.tap(find.text('Storage'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    handle.dispose();
  });

  testWidgets('loading state shows skeletons', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(OTheme.light(), _data(status: V2SettingsSearchStatus.loading)),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state retries', (tester) async {
    _phoneSize(tester);
    var retries = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _data(
          status: V2SettingsSearchStatus.error,
          errorMessage: 'Search is offline.',
        ),
        onRetry: () => retries++,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Search is offline.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('an empty index explains itself and can refresh', (tester) async {
    _phoneSize(tester);
    var retries = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _data(sections: const <V2SettingsSection>[]),
        onRetry: () => retries++,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No settings to search'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('fits 320 dp at 200% text (light results)', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _data(initialQuery: 'data'),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Permissions'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'results overflowed at 320 dp / 200 % text',
    );
  });

  testWidgets('fits 320 dp at 200% text (dark empty state)', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        OTheme.dark(),
        _data(initialQuery: 'zzz'),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No settings found'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'empty state overflowed at 320 dp / 200 % text',
    );
  });

  testWidgets('fits 320 dp at 200% text (browse chips)', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(OTheme.light(), _data(), textScaler: const TextScaler.linear(2)),
    );
    await tester.pumpAndSettle();

    expect(find.text('SECTIONS'), findsOneWidget);
    expect(find.byType(OChip), findsNWidgets(4));
    expect(
      tester.takeException(),
      isNull,
      reason: 'browse chips overflowed at 320 dp / 200 % text',
    );
  });

  testWidgets('renders results in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(OTheme.dark(), _data(initialQuery: 'storage')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('DATA CONTROL'), findsOneWidget);
  });

  testWidgets('reduced motion still shows every result', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(OTheme.light(), _data(initialQuery: 'a'), disableAnimations: true),
    );
    await tester.pump();

    expect(find.text('Plan & billing'), findsOneWidget);
    expect(find.byType(OCard), findsWidgets);
  });
}
