// SH-009 / EM-011: a persistent, actionable shell-level banner for
// account-level cloud failures (signed out, quota 402, unreachable,
// attestation).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_issues.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/ui/cloud_issue_banner.dart';

CloudApiException _e(int status, String code, {DateTime? resetsAt}) =>
    CloudApiException(
        status: status, code: code, message: 'm', resetsAt: resetsAt);

void main() {
  late CloudIssues issues;
  late List<String> actions;
  var offline = false;

  setUp(() {
    issues = CloudIssues();
    actions = [];
    offline = false;
  });

  Widget host() => MaterialApp(
        home: Scaffold(
          body: CloudIssueBanner(
            issues: issues,
            mintIssue: () => null,
            isOffline: () => offline,
            onSignInAgain: () async => actions.add('signin'),
            onOpenPlans: (_) async => actions.add('plans'),
            onRetry: () async => actions.add('retry'),
          ),
        ),
      );

  testWidgets('hidden with no issue', (tester) async {
    await tester.pumpWidget(host());
    expect(find.byKey(const ValueKey('cloud-issue-banner')), findsNothing);
  });

  testWidgets('signed out: Sign in again', (tester) async {
    await tester.pumpWidget(host());
    issues.reportFailure(_e(401, 'unauthenticated'));
    await tester.pump();
    expect(find.byKey(const ValueKey('cloud-issue-banner')), findsOneWidget);
    expect(find.textContaining('session has expired'), findsOneWidget);
    await tester.tap(find.text('Sign in again'));
    await tester.pump();
    expect(actions, ['signin']);
    expect(issues.value, isNull);
  });

  testWidgets('quota: View plans, and stays until acted on', (tester) async {
    await tester.pumpWidget(host());
    issues.reportFailure(_e(402, 'daily_limit_reached'));
    await tester.pump();
    expect(find.textContaining('allowance'), findsOneWidget);
    issues.reportSuccess(); // a read succeeding does not clear it
    await tester.pump();
    expect(find.text('View plans'), findsOneWidget);
    await tester.tap(find.text('View plans'));
    await tester.pump();
    expect(actions, ['plans']);
  });

  testWidgets('unreachable: Retry', (tester) async {
    await tester.pumpWidget(host());
    issues.reportFailure(_e(0, 'unreachable'));
    await tester.pump();
    expect(find.textContaining("Can't reach Ovid Cloud"), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(actions, ['retry']);
  });

  testWidgets('unreachable defers to the offline banner', (tester) async {
    offline = true;
    await tester.pumpWidget(host());
    issues.reportFailure(_e(0, 'timeout'));
    await tester.pump();
    expect(find.byKey(const ValueKey('cloud-issue-banner')), findsNothing);
  });

  testWidgets('attestation failure explains and offers Retry', (tester) async {
    await tester.pumpWidget(host());
    issues.reportFailure(_e(403, 'app_check_unavailable'));
    await tester.pump();
    expect(find.textContaining('verify this copy'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  test('mint failures map onto the same issue kinds', () {
    CloudIssueKind? kind(MintStatus s) => issueFromConnection(
          CloudConnectionState(CloudConnectionStatus.failed,
              mintStatus: s, error: 'x'),
        )?.kind;
    expect(kind(MintStatus.freeLimitReached), CloudIssueKind.quota);
    expect(kind(MintStatus.sessionExpired), CloudIssueKind.signedOut);
    expect(kind(MintStatus.notSignedIn), CloudIssueKind.signedOut);
    expect(kind(MintStatus.deviceUnverified), CloudIssueKind.unverified);
    expect(kind(MintStatus.unavailable), CloudIssueKind.unreachable);
    expect(kind(MintStatus.rejected), isNull);
    expect(
      issueFromConnection(
          const CloudConnectionState(CloudConnectionStatus.ready)),
      isNull,
    );
  });
}
