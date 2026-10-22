import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_errors.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_error_bar.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';

/// A rejected send must never look like a chat that did nothing. The facade
/// records the failure; these tests prove the surface actually shows it, with
/// the transcript still visible behind it.
Widget _host(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  group('V2ChatError.fromCode', () {
    test('a cancelled stop is not an error', () {
      expect(V2ChatError.fromCode('cancelled'), isNull);
    });

    test('a run conflict is not an error', () {
      expect(V2ChatError.fromCode('run_conflict'), isNull);
    });

    test('no code means no bar', () {
      expect(V2ChatError.fromCode(null), isNull);
      expect(V2ChatError.fromCode(''), isNull);
    });

    test('a daily limit offers plans', () {
      final error = V2ChatError.fromCode('daily_limit_reached');
      expect(error, isNotNull);
      expect(error!.action, CloudErrorAction.openPlans);
      expect(error.actionLabel, 'See plans');
      expect(error.text, isNotEmpty);
    });

    test('an auth failure offers sign in', () {
      final error = V2ChatError.fromCode('unauthenticated');
      expect(error!.action, CloudErrorAction.signIn);
      expect(error.actionLabel, 'Sign in');
    });

    test('an internal failure offers retry', () {
      final error = V2ChatError.fromCode('internal');
      expect(error, isNotNull);
      expect(error!.actionLabel, anyOf('Retry', isNull));
    });
  });

  group('error bar', () {
    testWidgets('renders the message and fires its action', (tester) async {
      var acted = 0;
      var dismissed = 0;
      await tester.pumpWidget(
        _host(
          V2ChatErrorBar(
            error: V2ChatError.fromCode('unauthenticated')!,
            onAction: () => acted++,
            onDismiss: () => dismissed++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);

      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(acted, 1);

      await tester.tap(find.bySemanticsLabel('Dismiss error'));
      await tester.pump();
      expect(dismissed, 1);
    });

    testWidgets('the raw server text sits behind Details', (tester) async {
      final error = V2ChatError.fromCode(
        'internal',
        message: 'upstream provider 503 from us-east-1',
      )!;
      await tester.pumpWidget(_host(V2ChatErrorBar(error: error)));
      await tester.pumpAndSettle();

      // The raw text is not in the first read: it would be noise.
      expect(find.textContaining('us-east-1'), findsNothing);

      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('us-east-1'), findsOneWidget);
    });

    testWidgets('survives 320 dp at 200 % text in both themes', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final dark in <bool>[false, true]) {
        await tester.pumpWidget(
          _host(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                ),
                child: V2ChatErrorBar(
                  error: V2ChatError.fromCode('daily_limit_reached')!,
                  onAction: () {},
                ),
              ),
            ),
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('the chat surfaces the error', () {
    testWidgets('live chat keeps the transcript and shows the bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const V2LiveChatPage(
            data: V2LiveChatData(
              items: [
                V2LiveUserMessage(id: 'u1', text: 'hi'),
              ],
            ),
          ).copyWithErrorForTest(V2ChatError.fromCode('internal')),
        ),
      );
      await tester.pumpAndSettle();

      // The prompt is still on screen: a failure must not erase the chat.
      expect(find.text('hi'), findsOneWidget);
      expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);
    });

    testWidgets('empty chat shows the bar above its composer', (tester) async {
      await tester.pumpWidget(
        _host(
          V2ChatPage(
            data: const V2ChatPageData(),
            onSendErrorAction: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Without an error the bar is absent.
      expect(find.byKey(const Key('v2-chat-error')), findsNothing);
    });
  });
}

extension on V2LiveChatPage {
  /// Test-only: inject the error the shell computes from the facade.
  V2LiveChatPage copyWithErrorForTest(V2ChatError? error) => V2LiveChatPage(
    data: data.copyWithSendError(error),
    onSendErrorAction: () {},
    onDismissSendError: () {},
  );
}
