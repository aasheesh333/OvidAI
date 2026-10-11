import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/content_report_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/content_report_sheet.dart';

void main() {
  http.Request? last;
  ContentReportService service({int status = 201, String? token = 'id-token'}) =>
      ContentReportService(
        baseUrl: 'https://api.example.test/ovid',
        idToken: () async => token,
        appCheck: () async => 'app-check',
        client: MockClient((request) async {
          last = request;
          return http.Response('{"id":"r1"}', status);
        }),
      );

  setUp(() => last = null);

  test('posts an authenticated, bounded report to /v1/reports', () async {
    await service().submit(
      ContentReport(
        kind: ContentReportKind.aiOutput,
        reason: ContentReportReason.hate,
        details: 'offensive',
        excerpt: 'x' * 5000,
        model: 'model-a',
        requestId: 'a' * 32,
      ),
    );
    expect(last!.method, 'POST');
    expect(last!.url.toString(), 'https://api.example.test/ovid/v1/reports');
    expect(last!.headers['Authorization'], 'Bearer id-token');
    expect(last!.headers['X-Firebase-AppCheck'], 'app-check');
    final body = jsonDecode(last!.body) as Map<String, dynamic>;
    expect(body['kind'], 'ai_output');
    expect(body['reason'], 'hate');
    expect(body['request_id'], 'a' * 32);
    expect((body['excerpt'] as String).length, ContentReport.maxExcerpt);
    expect(body.containsKey('reporter_uid'), isFalse);
  });

  test('explains signed-out, rate-limited and unconfigured states', () async {
    final report = ContentReport(
      kind: ContentReportKind.sharedConversation,
      reason: ContentReportReason.spam,
    );
    await expectLater(
      service(token: null).submit(report),
      throwsA(isA<ContentReportException>()),
    );
    expect(last, isNull);
    await expectLater(
      service(status: 429).submit(report),
      throwsA(
        predicate<ContentReportException>((e) => e.message.contains('Too many')),
      ),
    );
    final unconfigured = ContentReportService(
      baseUrl: '',
      idToken: () async => 't',
    );
    expect(unconfigured.available, isFalse);
    await expectLater(
      unconfigured.submit(report),
      throwsA(isA<ContentReportException>()),
    );
  });

  test('only finished assistant output is reportable', () {
    expect(isReportableAiMessage(Message(role: 'assistant', content: 'hi')), isTrue);
    expect(
      isReportableAiMessage(Message(role: 'assistant', kind: MsgKind.imageGen)),
      isTrue,
    );
    expect(isReportableAiMessage(Message(role: 'user', content: 'hi')), isFalse);
    expect(
      isReportableAiMessage(Message(role: 'assistant', kind: MsgKind.tool)),
      isFalse,
    );
    expect(
      isReportableAiMessage(Message(role: 'assistant', thinking: true)),
      isFalse,
    );
  });

  testWidgets('report sheet requires a reason and sends it in-app', (tester) async {
    contentReportServiceOverrideForTest = service();
    addTearDown(() => contentReportServiceOverrideForTest = null);
    bool? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                sent = await showContentReportSheet(
                  context,
                  kind: ContentReportKind.aiOutput,
                  excerpt: 'bad reply',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Report AI response'), findsOneWidget);
    final submit = find.byKey(const ValueKey('report-submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('report-reason-violence')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('report-details')), 'why');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(sent, isTrue);
    final body = jsonDecode(last!.body) as Map<String, dynamic>;
    expect(body['reason'], 'violence');
    expect(body['details'], 'why');
    expect(body['excerpt'], 'bad reply');
    expect(find.textContaining('safety team'), findsOneWidget);
  });
}
