import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/states/state_tiles.dart';
import 'package:ovid_ai/ui/v2/states/system_states_page.dart';

void _noop() {}

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

Future<void> _tall(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('renders all four calm states in light', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage()));
    await tester.pumpAndSettle();

    expect(find.text('System states'), findsOneWidget);
    expect(find.text('Start with a hello'), findsOneWidget);
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Daily limit reached'), findsOneWidget);
    expect(find.text('Resets soon'), findsOneWidget);
    // No handler is supplied, so the action buttons stay hidden.
    expect(find.text('See plans'), findsNothing);
    expect(
      find.text(
        'Your chats and files stay safe in every state. Nothing is lost.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders all four states in dark', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage(), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Start with a hello'), findsOneWidget);
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Daily limit reached'), findsOneWidget);
  });

  testWidgets('every state action fires', (tester) async {
    await _tall(tester);
    var examples = 0;
    var retries = 0;
    var again = 0;
    var details = 0;
    var plans = 0;
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          onTryExample: () => examples++,
          onRetryConnection: () => retries++,
          onTryAgain: () => again++,
          onViewErrorDetails: () => details++,
          onSeePlans: () => plans++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Try an example prompt'));
    await tester.tap(find.text('Retry connection'));
    await tester.tap(find.text('Try again'));
    await tester.tap(find.text('View error details'));
    await tester.tap(find.text('See plans'));

    expect(examples, 1);
    expect(retries, 1);
    expect(again, 1);
    expect(details, 1);
    expect(plans, 1);
  });

  testWidgets('reset countdown comes from injected data', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(
      _app(
        const V2SystemStatesPage(
          data: V2SystemStatesData(limitResetLabel: 'Resets in 2h 05m'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Resets in 2h 05m'), findsOneWidget);
    expect(find.text('Resets soon'), findsNothing);
  });

  testWidgets('actions without callbacks are hidden, not left dead', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage()));
    await tester.pumpAndSettle();

    // Every tile still renders its copy…
    expect(find.text('Daily limit reached'), findsOneWidget);
    // …but no action button exists for a callback the host did not supply.
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('See plans'), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Restore'), findsNothing);
    handle.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets(
      '320 dp at 200% text lays out cleanly (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);

        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: const MediaQuery(
              data: MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: V2SystemStatesPage(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        for (final error in errors) {
          debugPrint(error.toString());
        }
        expect(errors, isEmpty);

        // The body scrolls, so every state and action stays reachable.
        await tester.scrollUntilVisible(
          find.text('Daily limit reached'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Daily limit reached'), findsOneWidget);
      },
    );
  }

  testWidgets('offline copy promises messages will send later', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage()));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No internet connection detected. Your messages will send when you reconnect.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders the six state-tile variants plus the empty prompt', (
    tester,
  ) async {
    await _tall(tester);
    var fired = 0;
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          onTryExample: () => fired++,
          onRetryConnection: () => fired++,
          onTryAgain: () => fired++,
          onViewErrorDetails: () => fired++,
          onSeePlans: () => fired++,
          onManageStorage: () => fired++,
          onGetHelp: () => fired++,
          onRestoreAccount: () => fired++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One custom tile for the empty prompt and one for each of the six
    // V2StateTile kinds.
    expect(find.byType(V2StateTile), findsNWidgets(7));
    expect(find.text('Try an example prompt'), findsOneWidget);
    expect(find.text('Retry connection'), findsOneWidget);
    expect(find.text('See plans'), findsOneWidget);
    expect(find.text('Manage storage'), findsOneWidget);
    expect(find.text('Get help'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('storage, suspension and deletion actions fire', (tester) async {
    await _tall(tester);
    var storage = 0;
    var help = 0;
    var restore = 0;
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          onManageStorage: () => storage++,
          onGetHelp: () => help++,
          onRestoreAccount: () => restore++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['Manage storage', 'Get help', 'Restore']) {
      await tester.ensureVisible(find.text(label));
      await tester.pump();
      await tester.tap(find.text(label));
    }

    expect(storage, 1);
    expect(help, 1);
    expect(restore, 1);
  });

  testWidgets('the newer state copy can be overridden', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          data: const V2SystemStatesData(
            storageTitle: 'Workspace is full',
            storageMessage: 'Delete a preview to free space.',
            storageActionLabel: 'Clean up',
            abuseTitle: 'Account on hold',
            abuseMessage: 'Support is reviewing this account.',
            abuseActionLabel: 'Contact support',
            deletionTitle: 'Account closing',
            deletionMessage: 'Sign in again within 24 hours to restore it.',
            deletionActionLabel: 'Restore now',
          ),
          onManageStorage: _noop,
          onGetHelp: _noop,
          onRestoreAccount: _noop,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Workspace is full'), findsOneWidget);
    expect(find.text('Delete a preview to free space.'), findsOneWidget);
    expect(find.text('Clean up'), findsOneWidget);
    expect(find.text('Account on hold'), findsOneWidget);
    expect(find.text('Contact support'), findsOneWidget);
    expect(find.text('Account closing'), findsOneWidget);
    expect(find.text('Restore now'), findsOneWidget);
  });
}
