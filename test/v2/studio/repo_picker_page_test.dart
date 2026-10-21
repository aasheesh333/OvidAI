import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/repo_picker_page.dart';

Widget _app(Widget child, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: child);

const _repos = <V2Repo>[
  V2Repo(
    id: '1',
    name: 'landing-page',
    owner: 'acme',
    description: 'Marketing site for Acme Cloud',
    language: 'TypeScript',
    updatedLabel: 'Updated 2h ago',
    isPrivate: true,
  ),
  V2Repo(
    id: '2',
    name: 'api-server',
    owner: 'acme',
    description: 'Public API and background jobs',
    language: 'Dart',
    updatedLabel: 'Updated yesterday',
  ),
];

void main() {
  testWidgets('renders repositories in light and dark', (tester) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(
          const V2RepoPickerPage(
            data: V2RepoPickerData(repos: _repos, accountLabel: 'Priya'),
          ),
          dark: dark,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('acme/landing-page'), findsOneWidget);
      expect(find.text('acme/api-server'), findsOneWidget);
      expect(find.text('Connected as Priya'), findsOneWidget);
    }
  });

  testWidgets('empty state connects GitHub', (tester) async {
    var connected = 0;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(
            status: V2RepoPickerStatus.empty,
            githubConnected: false,
          ),
          onConnectGithub: () => connected++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pick a repository to start'), findsOneWidget);
    expect(find.text('Enter a personal access token'), findsOneWidget);

    await tester.tap(find.text('Connect GitHub'));
    expect(connected, 1);
  });

  testWidgets('tapping a repository reports the selection', (tester) async {
    V2Repo? selected;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(repos: _repos),
          onSelectRepo: (repo) => selected = repo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/api-server'));
    expect(selected?.id, '2');
  });

  testWidgets('search filters the repository list', (tester) async {
    await tester.pumpWidget(
      _app(const V2RepoPickerPage(data: V2RepoPickerData(repos: _repos))),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'landing');
    await tester.pumpAndSettle();

    expect(find.text('acme/landing-page'), findsOneWidget);
    expect(find.text('acme/api-server'), findsNothing);
  });

  testWidgets('connected empty state refreshes', (tester) async {
    var refreshes = 0;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(
            repos: <V2Repo>[],
            accountLabel: 'Priya',
          ),
          onRetry: () => refreshes++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No repositories yet'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    expect(refreshes, 1);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(
            status: V2RepoPickerStatus.error,
            errorMessage: 'GitHub is not responding.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GitHub is not responding.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('loading state shows a skeleton', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2RepoPickerPage(
          data: V2RepoPickerData(status: V2RepoPickerStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('no search match clears the search', (tester) async {
    await tester.pumpWidget(
      _app(const V2RepoPickerPage(data: V2RepoPickerData(repos: _repos))),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nothing-matches');
    await tester.pumpAndSettle();
    expect(find.text('No matching repositories'), findsOneWidget);

    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('acme/landing-page'), findsOneWidget);
  });

  testWidgets('reduced motion keeps every row visible', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const V2RepoPickerPage(
              data: V2RepoPickerData(repos: _repos),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('acme/landing-page'), findsOneWidget);
    expect(find.text('acme/api-server'), findsOneWidget);
    expect(find.text('Enter a personal access token'), findsOneWidget);
  });

  testWidgets('repository rows announce their label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const V2RepoPickerPage(data: V2RepoPickerData(repos: _repos))),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(RegExp('acme/landing-page, private repository')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('acme/api-server, public repository')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('320 dp at 200% text lays out every state', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final scenarios = <String, Widget>{
      'content': const V2RepoPickerPage(
        data: V2RepoPickerData(
          repos: _repos,
          accountLabel: 'Priya Ramanathan',
        ),
      ),
      'disconnected': const V2RepoPickerPage(
        data: V2RepoPickerData(
          status: V2RepoPickerStatus.empty,
          githubConnected: false,
        ),
      ),
      'connected empty': const V2RepoPickerPage(
        data: V2RepoPickerData(repos: <V2Repo>[], accountLabel: 'Priya'),
      ),
      'error': const V2RepoPickerPage(
        data: V2RepoPickerData(
          status: V2RepoPickerStatus.error,
          errorMessage:
              'We could not load your repositories. Check your connection and try again.',
        ),
      ),
    };

    for (final entry in scenarios.entries) {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
              ),
              child: entry.value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: '${entry.key} overflowed at 320 dp / 200% text',
      );
    }
  });
}
