import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/url_safety.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('url_safety', () {
    test('userinfo is stripped and flagged', () {
      final link = safeLinkFrom('https://bank.com@evil.tld/login?x=1')!;
      expect(link.hadUserInfo, isTrue);
      expect(link.asciiHost, 'evil.tld');
      expect(link.uri.toString(), 'https://evil.tld/login?x=1');
    });

    test('punycode hosts are decoded and flagged as IDN', () {
      final spoof = safeLinkFrom('https://xn--pple-43d.com/')!;
      expect(spoof.displayHost, '\u0430pple.com');
      expect(spoof.isIdn, isTrue);
      expect(decodeIdnHost('xn--mnchen-3ya.de'), 'münchen.de');
      expect(safeLinkFrom('https://example.com/')!.isIdn, isFalse);
      // Raw Unicode host (Dart percent-encodes it) is flagged too.
      expect(safeLinkFrom('https://\u0430pple.com/')!.isIdn, isTrue);
    });

    test('web-only rejects other schemes', () {
      expect(safeLinkFrom('javascript:alert(1)', webOnly: true), isNull);
      expect(safeLinkFrom('intent://x#Intent;end', webOnly: true), isNull);
      expect(safeLinkFrom('tel:123')!.isWeb, isFalse);
    });

    test('registrable domain', () {
      expect(registrableDomainOf('accounts.google.co.uk'), 'google.co.uk');
      expect(
        registrableDomainOf('accounts.google.com.evil.example'),
        'evil.example',
      );
      expect(registrableDomainOf('example.com'), 'example.com');
      expect(registrableDomainOf('192.168.1.1'), '192.168.1.1');
      expect(
        registrableDomainOf('netbanking.hdfcbank.co.in'),
        'hdfcbank.co.in',
      );
    });

    test('link text that names another site misleads', () {
      final evil = safeLinkFrom('https://evil.example/login')!;
      expect(linkTextMisleads('google.com', evil), isTrue);
      expect(linkTextMisleads('https://google.com/x', evil), isTrue);
      expect(linkTextMisleads('Sign in here', evil), isFalse);
      expect(linkTextMisleads('evil.example', evil), isFalse);
      expect(linkTextMisleads('www.evil.example/login', evil), isFalse);
    });
  });

  group('chat surfaces', () {
    final launched = <String>[];

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      app.seenWelcomeVersion = AppState.welcomeVersion;
      launched.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              if (call.method == 'launch') {
                launched.add((call.arguments as Map)['url'] as String);
                return true;
              }
              return true;
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null,
          );
      AppState.resetTestInstance();
    });

    Future<void> pumpChat(WidgetTester tester, List<Message> messages) async {
      tester.view.physicalSize = const Size(700, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = ChatSession(
        id: 'link-safety',
        title: 'Chat',
        model: 'm',
        messages: [
          Message(role: 'user', content: 'go'),
          ...messages,
        ],
      );
      AppState.I.sessions
        ..clear()
        ..add(session);
      AppState.I.activeSessionId = session.id;
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    bool hasNetworkImage(WidgetTester tester) => tester
        .widgetList<Image>(find.byType(Image))
        .any(
          (img) =>
              img.image is NetworkImage ||
              (img.image is ResizeImage &&
                  (img.image as ResizeImage).imageProvider is NetworkImage),
        );

    testWidgets('remote markdown image is not fetched until tapped', (
      tester,
    ) async {
      await pumpChat(tester, [
        Message(
          role: 'assistant',
          kind: MsgKind.text,
          content: 'Here:\n\n![x](https://example.com/a.png)',
        ),
      ]);
      expect(hasNetworkImage(tester), isFalse);
      final placeholder = find.byKey(
        const ValueKey('remote-image-placeholder'),
      );
      expect(placeholder, findsOneWidget);
      expect(find.textContaining('example.com · Tap to load'), findsOneWidget);
      await tester.tap(placeholder);
      await tester.pump();
      expect(hasNetworkImage(tester), isTrue);
    });

    testWidgets('absolute file images are refused', (tester) async {
      await pumpChat(tester, [
        Message(
          role: 'assistant',
          kind: MsgKind.text,
          content: '![secret](/data/data/com.dhanuk.ovidai/x.png)',
        ),
      ]);
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('Image not shown'), findsOneWidget);
    });

    testWidgets('tool-output URL asks first and opens the stripped URL', (
      tester,
    ) async {
      const url = 'https://bank.com@evil.tld/login';
      await pumpChat(tester, [
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'web_fetch',
          toolTitle: 'Fetch',
          toolSummary: 'page',
          toolDetail: 'Result: visit $url now',
          toolState: 'ok',
        ),
      ]);
      await tester.tap(find.byKey(const ValueKey('chat-tool-summary')));
      await tester.pumpAndSettle();

      TapGestureRecognizer? recognizer;
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan &&
              span.text == url &&
              span.recognizer is TapGestureRecognizer) {
            recognizer = span.recognizer as TapGestureRecognizer;
            return false;
          }
          return true;
        });
      }
      expect(recognizer, isNotNull);
      recognizer!.onTap!();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('link-confirm-sheet')), findsOneWidget);
      final host = tester.widget<Text>(
        find.byKey(const ValueKey('link-confirm-host')),
      );
      expect(host.textSpan!.toPlainText(), 'evil.tld');
      expect(find.textContaining('hid its real address'), findsOneWidget);
      expect(launched, isEmpty);

      await tester.tap(find.byKey(const ValueKey('link-confirm-open')));
      await tester.pumpAndSettle();
      expect(launched, ['https://evil.tld/login']);
    });

    testWidgets('cancel never launches', (tester) async {
      await pumpChat(tester, [
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'shell',
          toolTitle: 'Run',
          toolSummary: 'curl',
          toolDetail: 'see https://example.org/x',
          toolState: 'ok',
        ),
      ]);
      await tester.tap(find.byKey(const ValueKey('chat-tool-summary')));
      await tester.pumpAndSettle();
      TapGestureRecognizer? recognizer;
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
            recognizer = span.recognizer as TapGestureRecognizer;
            return false;
          }
          return true;
        });
      }
      recognizer!.onTap!();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(launched, isEmpty);
    });

    testWidgets('markdown link whose text names another site asks first', (
      tester,
    ) async {
      await pumpChat(tester, [
        Message(
          role: 'assistant',
          kind: MsgKind.text,
          content: 'Log in at [google.com](https://evil.example/login).',
        ),
      ]);
      TapGestureRecognizer? recognizer;
      final spans = <InlineSpan>[
        for (final w in tester.widgetList<SelectableText>(
          find.byType(SelectableText),
        ))
          if (w.textSpan != null) w.textSpan!,
        for (final w in tester.widgetList<RichText>(find.byType(RichText)))
          w.text,
      ];
      for (final root in spans) {
        root.visitChildren((span) {
          if (span is TextSpan &&
              span.text == 'google.com' &&
              span.recognizer is TapGestureRecognizer) {
            recognizer = span.recognizer as TapGestureRecognizer;
            return false;
          }
          return true;
        });
      }
      expect(recognizer, isNotNull);
      recognizer!.onTap!();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('link-confirm-sheet')), findsOneWidget);
      expect(
        find.textContaining('but it goes to evil.example'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(launched, isEmpty);
    });
  });
}
