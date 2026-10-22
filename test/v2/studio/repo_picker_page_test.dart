import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/repo_picker_page.dart';

Widget _app(Widget child, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: textScale == 1
          ? null
          : (context, content) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: content!,
            ),
      home: child,
    );

void _noopConfirm(V2Repo repo, String branch) {}
void _noopSelect(V2Repo repo) {}

const _repos = <V2Repo>[
  V2Repo(
    id: '1',
    name: 'landing-page',
    owner: 'acme',
    description: 'Marketing site for Acme Cloud',
    language: 'TypeScript',
    updatedLabel: 'Updated 2h ago',
    isPrivate: true,
    defaultBranch: 'main',
    branches: <V2RepoBranch>[
      V2RepoBranch(name: 'main', isDefault: true, lastCommitLabel: '2h ago'),
      V2RepoBranch(name: 'develop', lastCommitLabel: 'Yesterday'),
      V2RepoBranch(name: 'feature/hero-revamp', lastCommitLabel: '3 days ago'),
    ],
  ),
  V2Repo(
    id: '2',
    name: 'api-server',
    owner: 'acme',
    description: 'Public API and background jobs',
    language: 'Dart',
    updatedLabel: 'Updated yesterday',
    defaultBranch: 'main',
    branches: <V2RepoBranch>[
      V2RepoBranch(name: 'main', isDefault: true),
      V2RepoBranch(name: 'release'),
    ],
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

      expect(find.text('Repositories'), findsOneWidget);
      expect(find.text('acme/landing-page'), findsOneWidget);
      expect(find.text('acme/api-server'), findsOneWidget);
      // One owner/name row, no meta line, never the description paragraph.
      expect(find.text('TypeScript · Updated 2h ago'), findsNothing);
      expect(find.text('Marketing site for Acme Cloud'), findsNothing);
      expect(find.textContaining('Connected as'), findsNothing);
    }
  });

  testWidgets('disconnected state connects GitHub', (tester) async {
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

    expect(find.text('Connect GitHub'), findsOneWidget);

    await tester.tap(find.text('Connect GitHub'));
    expect(connected, 1);
  });

  testWidgets('the token path stays reachable when disconnected', (
    tester,
  ) async {
    var tokens = 0;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(
            status: V2RepoPickerStatus.empty,
            githubConnected: false,
          ),
          onOpenToken: () => tokens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use a token'));
    expect(tokens, 1);
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

  testWidgets('requires a repository and branch before the primary enables', (
    tester,
  ) async {
    V2Repo? confirmedRepo;
    String? confirmedBranch;
    const noDefault = <V2Repo>[
      V2Repo(
        id: '3',
        name: 'no-default',
        owner: 'acme',
        branches: <V2RepoBranch>[
          V2RepoBranch(name: 'trunk'),
          V2RepoBranch(name: 'release'),
        ],
      ),
    ];

    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(repos: noDefault),
          onConfirm: (repo, branch) {
            confirmedRepo = repo;
            confirmedBranch = branch;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    OButton primary() =>
        tester.widget<OButton>(find.byKey(const Key('repo-picker-primary')));

    // Step one has no primary action: tapping a repository advances the step.
    expect(find.byKey(const Key('repo-picker-primary')), findsNothing);

    await tester.tap(find.text('acme/no-default'));
    await tester.pumpAndSettle();

    expect(find.text('trunk'), findsOneWidget);
    expect(find.text('release'), findsOneWidget);
    expect(primary().onPressed, isNull);
    expect(find.widgetWithText(OButton, 'Choose branch'), findsOneWidget);

    await tester.tap(find.byKey(const Key('repo-picker-branch-release')));
    await tester.pumpAndSettle();

    expect(primary().onPressed, isNotNull);
    expect(find.text('Start'), findsOneWidget);

    await tester.tap(find.byKey(const Key('repo-picker-primary')));
    await tester.pumpAndSettle();

    expect(confirmedRepo?.id, '3');
    expect(confirmedBranch, 'release');
  });

  testWidgets('preselects the default branch and reports it on confirm', (
    tester,
  ) async {
    V2Repo? confirmedRepo;
    String? confirmedBranch;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(repos: _repos),
          onConfirm: (repo, branch) {
            confirmedRepo = repo;
            confirmedBranch = branch;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/landing-page'));
    await tester.pumpAndSettle();

    // The header names the repository; the primary action is the gate.
    expect(find.text('acme/landing-page'), findsOneWidget);
    final primary = tester.widget<OButton>(
      find.byKey(const Key('repo-picker-primary')),
    );
    expect(primary.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('repo-picker-primary')));
    await tester.pumpAndSettle();

    expect(confirmedRepo?.id, '1');
    expect(confirmedBranch, 'main');
  });

  testWidgets('changing the branch changes what is confirmed', (tester) async {
    String? confirmedBranch;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(repos: _repos),
          onConfirm: (_, branch) => confirmedBranch = branch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/landing-page'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('repo-picker-branch-develop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('repo-picker-primary')));
    await tester.pumpAndSettle();

    expect(confirmedBranch, 'develop');
  });

  testWidgets('change repository returns to the repo list and re-gates', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(repos: _repos),
          onConfirm: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/landing-page'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('repo-picker-branch-develop')), findsOneWidget);

    await tester.tap(find.byKey(const Key('repo-picker-back-to-repos')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('repo-picker-branch-develop')), findsNothing);
    expect(find.text('acme/landing-page'), findsOneWidget);
    // Back on the repository step there is no primary action to press.
    expect(find.byKey(const Key('repo-picker-primary')), findsNothing);
  });

  testWidgets('a repo without branches cannot pass the gate', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2RepoPickerPage(
          data: V2RepoPickerData(
            repos: <V2Repo>[V2Repo(id: '4', name: 'empty', owner: 'acme')],
          ),
          onConfirm: _noopConfirm,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/empty'));
    await tester.pumpAndSettle();

    expect(find.text('No branches found'), findsOneWidget);
    final primary = tester.widget<OButton>(
      find.byKey(const Key('repo-picker-primary')),
    );
    expect(primary.onPressed, isNull);

    // The header back is the only way back to the repository list.
    expect(find.text('Change repository'), findsNothing);
    await tester.tap(find.byKey(const Key('repo-picker-back-to-repos')));
    await tester.pumpAndSettle();
    expect(find.text('acme/empty'), findsOneWidget);
  });

  testWidgets('loads real branches when the snapshot has none', (tester) async {
    V2Repo? confirmedRepo;
    String? confirmedBranch;
    var loads = 0;

    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(
            repos: <V2Repo>[V2Repo(id: 'acme/api', name: 'api', owner: 'acme')],
          ),
          onLoadBranches: (repo) async {
            loads++;
            return const <V2RepoBranch>[
              V2RepoBranch(name: 'main', isDefault: true),
              V2RepoBranch(name: 'release/1.2'),
            ];
          },
          onConfirm: (repo, branch) {
            confirmedRepo = repo;
            confirmedBranch = branch;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/api'));
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('release/1.2'), findsOneWidget);

    // The default branch is preselected, so the gate is open.
    final primary = tester.widget<OButton>(
      find.byKey(const Key('repo-picker-primary')),
    );
    expect(primary.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('repo-picker-primary')));
    await tester.pumpAndSettle();
    expect(confirmedRepo?.id, 'acme/api');
    expect(confirmedBranch, 'main');
  });

  testWidgets('a failed branch load offers a retry', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      _app(
        V2RepoPickerPage(
          data: const V2RepoPickerData(
            repos: <V2Repo>[V2Repo(id: 'acme/api', name: 'api', owner: 'acme')],
          ),
          onLoadBranches: (repo) async {
            loads++;
            if (loads == 1) throw StateError('offline');
            return const <V2RepoBranch>[V2RepoBranch(name: 'main')];
          },
          onConfirm: _noopConfirm,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/api'));
    await tester.pumpAndSettle();

    expect(find.text('Branches did not load'), findsOneWidget);
    await tester.ensureVisible(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('main'), findsOneWidget);
  });

  testWidgets('without a confirm handler the picker cannot pretend to start', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2RepoPickerPage(
          data: V2RepoPickerData(repos: _repos),
          onSelectRepo: _noopSelect,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('acme/landing-page'));
    await tester.pumpAndSettle();

    final primary = tester.widget<OButton>(
      find.byKey(const Key('repo-picker-primary')),
    );
    expect(primary.onPressed, isNull);
    expect(find.textContaining('not connected'), findsNothing);
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
    // Unwired advanced rows are removed, not shown disabled.
    expect(find.text('Personal access token'), findsNothing);
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
        data: V2RepoPickerData(repos: _repos, accountLabel: 'Priya Ramanathan'),
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
          errorMessage: 'Repositories did not load.',
        ),
      ),
    };

    for (final dark in <bool>[false, true]) {
      for (final entry in scenarios.entries) {
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: entry.value,
              ),
            ),
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason:
              '${entry.key} overflowed at 320 dp / 200% text '
              '(${dark ? 'dark' : 'light'})',
        );
      }
    }
  });

  testWidgets('320 dp at 200% text fits branch loading and error states', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const repoData = V2RepoPickerData(
      repos: <V2Repo>[V2Repo(id: 'acme/api', name: 'api', owner: 'acme')],
    );

    for (final dark in <bool>[false, true]) {
      // Loading: a future that never completes keeps the spinner on screen.
      final pending = Completer<List<V2RepoBranch>>();
      await tester.pumpWidget(
        _app(
          V2RepoPickerPage(
            key: ValueKey('branch-loading-$dark'),
            data: repoData,
            onLoadBranches: (_) => pending.future,
            onConfirm: _noopConfirm,
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('acme/api'));
      await tester.pump();
      expect(
        find.byKey(const Key('repo-picker-branches-loading')),
        findsOneWidget,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'branch loading overflowed (${dark ? 'dark' : 'light'})',
      );

      // Error: the retry copy must fit too.
      await tester.pumpWidget(
        _app(
          V2RepoPickerPage(
            key: ValueKey('branch-error-$dark'),
            data: repoData,
            onLoadBranches: (_) async => throw StateError('offline'),
            onConfirm: _noopConfirm,
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('acme/api'));
      await tester.pumpAndSettle();
      expect(find.text('Branches did not load'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'branch error overflowed (${dark ? 'dark' : 'light'})',
      );
    }
  });

  testWidgets('320 dp at 200% text lays out the branch step in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(
          const V2RepoPickerPage(
            data: V2RepoPickerData(
              repos: _repos,
              accountLabel: 'Priya Ramanathan',
            ),
            onConfirm: _noopConfirm,
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('acme/landing-page'));
      await tester.pumpAndSettle();

      expect(find.text('Start'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'branch step overflowed at 320 dp / 200% text '
            '(${dark ? 'dark' : 'light'})',
      );
    }
  });
}
