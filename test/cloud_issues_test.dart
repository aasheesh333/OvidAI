// EM-011 / CT-011 / CH-012 / SH-001 / SH-009: every auth, attestation,
// quota or transport failure on a cloud call becomes a typed
// CloudApiException AND a shell-visible CloudIssue.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_issues.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';

CloudApiException _e(int status, String code) =>
    CloudApiException(status: status, code: code, message: 'm');

void main() {
  group('CloudIssue.classify', () {
    test('401 / unauthenticated is a signed-out session', () {
      expect(CloudIssue.classify(_e(401, 'unauthenticated'))!.kind,
          CloudIssueKind.signedOut);
    });
    test('402 daily_limit_reached is quota', () {
      final at = DateTime.utc(2026, 10, 20);
      final issue = CloudIssue.classify(CloudApiException(
          status: 402,
          code: 'daily_limit_reached',
          message: 'limit',
          resetsAt: at))!;
      expect(issue.kind, CloudIssueKind.quota);
      expect(issue.resetsAt, at);
    });
    test('a 402 plan refusal is not the allowance', () {
      // 402 serves both a plan refusal and a spent allowance. Only the second
      // is the shell banner's business; the first is the chat row's sentence.
      for (final code in [
        'manual_model_not_allowed',
        'pro_required',
        'tier_required',
      ]) {
        expect(CloudIssue.classify(_e(402, code)), isNull, reason: code);
      }
    });
    test('transport failures and gateway 5xx are unreachable', () {
      for (final e in [
        _e(0, 'timeout'),
        _e(0, 'unreachable'),
        _e(502, 'internal'),
        _e(503, 'unavailable'),
        _e(504, 'internal'),
      ]) {
        expect(CloudIssue.classify(e)!.kind, CloudIssueKind.unreachable,
            reason: '$e');
      }
    });
    test('attestation failure is unverified', () {
      expect(CloudIssue.classify(_e(403, 'app_check_unavailable'))!.kind,
          CloudIssueKind.unverified);
    });
    test('request-level errors are not shell issues', () {
      for (final e in [
        _e(400, 'invalid_request'),
        _e(403, 'forbidden'),
        _e(404, 'not_found'),
        _e(409, 'conflict'),
        _e(429, 'rate_limited'),
      ]) {
        expect(CloudIssue.classify(e), isNull, reason: '$e');
      }
    });
  });

  group('CloudIssues notifier', () {
    test('success clears session/transport issues but not quota', () {
      final issues = CloudIssues();
      issues.reportFailure(_e(0, 'unreachable'));
      expect(issues.value!.kind, CloudIssueKind.unreachable);
      issues.reportSuccess();
      expect(issues.value, isNull);

      issues.reportFailure(_e(402, 'daily_limit_reached'));
      issues.reportSuccess();
      expect(issues.value!.kind, CloudIssueKind.quota,
          reason: 'a GET succeeding says nothing about the allowance');
      issues.reportSuccess(billable: true);
      expect(issues.value, isNull);
    });

    test('a signed-out issue outranks transport noise', () {
      final issues = CloudIssues();
      issues.reportFailure(_e(401, 'unauthenticated'));
      issues.reportFailure(_e(0, 'timeout'));
      expect(issues.value!.kind, CloudIssueKind.signedOut);
    });

    test('dismiss clears', () {
      final issues = CloudIssues()
        ..reportFailure(_e(402, 'daily_limit_reached'));
      expect(issues.value, isNotNull);
      issues.dismiss();
      expect(issues.value, isNull);
    });
  });

  group('CloudRestClient reports to CloudIssues', () {
    CloudRestClient client(http.Client mock, CloudIssues issues,
            {CloudHeaders? headers}) =>
        CloudRestClient(
          httpClient: mock,
          headers: headers ?? CloudHeaders.forTest(),
          restBase: 'https://cloud.test',
          issues: issues,
        );

    test('signed out: no request, typed 401, signedOut issue', () async {
      final issues = CloudIssues();
      final rest = client(
        MockClient((_) async => http.Response('{}', 200)),
        issues,
        headers: CloudHeaders(idToken: () async => null),
      );
      await expectLater(
          rest.getJson('/sessions'), throwsA(isA<CloudApiException>()));
      expect(issues.value!.kind, CloudIssueKind.signedOut);
    });

    test('402 from the server raises a quota issue with resetsAt', () async {
      final issues = CloudIssues();
      final rest = client(
        MockClient((_) async => http.Response(
            '{"error":{"code":"daily_limit_reached","message":"Limit"}}', 402,
            headers: {'x-ovid-resets-at': '1760918400000'})),
        issues,
      );
      await expectLater(rest.postJson('/sessions/s/messages', body: const {}),
          throwsA(isA<CloudApiException>()));
      expect(issues.value!.kind, CloudIssueKind.quota);
      expect(issues.value!.resetsAt, isNotNull);
    });

    test('only an accepted message send clears a quota issue', () async {
      final issues = CloudIssues()
        ..reportFailure(CloudApiException(
            status: 402, code: 'daily_limit_reached', message: 'x'));
      final rest = client(
        MockClient((request) async => http.Response(
            request.url.path.endsWith('/auth/ticket')
                ? '{"ticket":"t"}'
                : '{"runId":"r","messageId":"m","queued":false}',
            200)),
        issues,
      );
      await rest.postJson('/auth/ticket');
      expect(issues.value?.kind, CloudIssueKind.quota,
          reason: 'a WS ticket mint is not a billable success');
      await rest.postJson('/sessions/s/messages', body: const {});
      expect(issues.value, isNull);
    });

    test('unreachable then recovered clears the issue', () async {
      final issues = CloudIssues();
      var fail = true;
      final rest = client(
        MockClient((_) async {
          if (fail) throw http.ClientException('refused');
          return http.Response('{"sessions":[]}', 200);
        }),
        issues,
      );
      await expectLater(
          rest.getJson('/sessions'), throwsA(isA<CloudApiException>()));
      expect(issues.value!.kind, CloudIssueKind.unreachable);
      fail = false;
      await rest.getJson('/sessions');
      expect(issues.value, isNull);
    });

    test('a 404 is the caller\'s business, not a shell banner', () async {
      final issues = CloudIssues();
      final rest = client(
        MockClient((_) async => http.Response(
            '{"error":{"code":"not_found","message":"x"}}', 404)),
        issues,
      );
      await expectLater(
          rest.getJson('/sessions/x'), throwsA(isA<CloudApiException>()));
      expect(issues.value, isNull);
    });
  });
}
