import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_errors.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_error_bar.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';

/// A rejected send must never look like a chat that did nothing. The facade
/// records the failure and the shell maps it; these tests prove the surface
/// shows it with the transcript still visible behind it.
Widget _host(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  group('error copy mapping', () {
    test('a daily limit offers plans', () {
      final copy = cloudErrorCopy('daily_limit_reached');
      expect(copy.action, CloudErrorAction.openPlans);
      expect(copy.text, isNotEmpty);
    });

    test('an auth failure offers sign in', () {
      final copy = cloudErrorCopy('unauthenticated');
      expect(copy.action, CloudErrorAction.signIn);
    });

    test('a provider failure reads as a retry', () {
      final copy = cloudErrorCopy('model_terminal');
      expect(copy.text, contains('provider'));
      expect(copy.action, CloudErrorAction.retry);
    });

    test('a raw message becomes optional detail, not the headline', () {
      final copy = cloudErrorCopy(
        'internal',
        message: 'upstream 503 from us-east-1',
      );
      expect(copy.text, isNot(contains('us-east-1')));
      expect(copy.detail, contains('us-east-1'));
    });
  });

  group('error bar', () {
    testWidgets('renders the message and fires its action', (tester) async {
      var acted = 0;
      var dismissed = 0;
      await tester.pumpWidget(
        _host(
          V2ChatErrorBar(
            error: const V2ChatError(text: 'Sign in again.', actionLabel: 'Sign in'),
            onAction: () => acted++,
            onDismiss: () => dismissed++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(acted, 1);

      await tester.tap(find.bySemanticsLabel('Dismiss error'));
      await tester.pump();
      expect(dismissed, 1);
    });

    testWidgets('the raw server text sits behind Details', (tester) async {
      await tester.pumpWidget(
        _host(
          const V2ChatErrorBar(
            error: V2ChatError(
              text: 'Ovid had a problem.',
              actionLabel: 'Retry',
              detail: 'upstream provider 503 from us-east-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The raw text is not in the first read: it would be noise.
      expect(find.textContaining('us-east-1'), findsNothing);

      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('us-east-1'), findsOneWidget);
    });

    testWidgets('a read-only error has no action button', (tester) async {
      await tester.pumpWidget(
        _host(const V2ChatErrorBar(error: V2ChatError(text: 'Ovid is busy.'))),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
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
                child: const V2ChatErrorBar(
                  error: V2ChatError(
                    text:
                        'You have used your plan allowance. It resets in 3 '
                        'hours. Upgrade for more.',
                    actionLabel: 'See plans',
                    detail: 'daily_limit_reached',
                  ),
                  // ignore: avoid_redundant_argument_values
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
      const page = V2LiveChatPage(
        data: V2LiveChatData(
          items: [V2LiveUserMessage(id: 'u1', text: 'hi')],
        ),
      );
      await tester.pumpWidget(
        _host(
          V2LiveChatPage(
            data: page.data.copyWithSendError(
              const V2ChatError(text: 'Provider failed.', actionLabel: 'Retry'),
            ),
            onSendErrorAction: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The prompt is still on screen: a failure must not erase the chat.
      expect(find.text('hi'), findsOneWidget);
      expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);
    });

    testWidgets('empty chat has no bar until something fails', (tester) async {
      await tester.pumpWidget(
        _host(V2ChatPage(data: const V2ChatPageData())),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('v2-chat-error')), findsNothing);
    });

    testWidgets('empty chat shows the bar when the send failed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          V2ChatPage(
            data: const V2ChatPageData().copyWithSendError(
              const V2ChatError(text: 'Sign in again.', actionLabel: 'Sign in'),
            ),
            onSendErrorAction: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('v2-chat-error')), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });
}
