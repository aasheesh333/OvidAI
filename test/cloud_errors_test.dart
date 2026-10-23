// Wave 1a — CH-019 / CH-031 / CH-012: every failure code reads as plain
// language with the action that helps; nothing raw reaches the user.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_errors.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';

void main() {
  const codes = <String>[
    'daily_limit_reached',
    'manual_model_not_allowed',
    'rate_limited',
    'unauthenticated',
    'timeout',
    'network',
    'unavailable',
    'internal',
    'key_not_minted',
    'model_unavailable',
    'model_no_vision',
    'model_terminal',
    'model_transient_exhausted',
    'run_lost',
    'run_queue_wait_timeout',
    'tool_rounds_exhausted',
    'hydrate_failed',
    'attachment_unavailable',
    'too_many_subscriptions',
    'some_future_code',
  ];

  test('no code renders as a snake_case identifier or provider text', () {
    for (final code in codes) {
      final copy = cloudErrorCopy(
        code,
        message: 'litellm.BadRequestError: upstream exploded\n    at x',
      );
      expect(copy.text, isNot(contains('_')), reason: code);
      expect(copy.text, isNot(contains('litellm')), reason: code);
      expect(copy.text, isNot(contains('Error:')), reason: code);
      expect(copy.text.trim(), isNotEmpty, reason: code);
    }
  });

  test('each failure carries the action that helps (CH-031)', () {
    expect(cloudErrorCopy('daily_limit_reached').action,
        CloudErrorAction.openPlans);
    expect(cloudErrorCopy('unauthenticated').action, CloudErrorAction.signIn);
    expect(cloudErrorCopy('timeout').action, CloudErrorAction.retry);
    expect(cloudErrorCopy('network').action, CloudErrorAction.retry);
    expect(cloudErrorCopy('rate_limited').action, CloudErrorAction.wait);
    expect(cloudErrorCopy('model_unavailable').action,
        CloudErrorAction.pickModel);
    expect(cloudErrorCopy('key_not_minted').action, CloudErrorAction.retry,
        reason: 'the key is minted server-side; Settings cannot fix it');
    expect(cloudErrorCopy('run_lost').action, CloudErrorAction.retry);
  });

  test('the 402 plan refusal is one plain sentence, never provider text', () {
    final copy = cloudErrorCopy(
      'manual_model_not_allowed',
      message: 'litellm.APIError: plan check failed upstream',
    );
    expect(copy.text, 'Your plan uses Auto only. Switch the model to Auto.');
    expect(copy.action, CloudErrorAction.pickModel);
    expect(copy.text, isNot(contains('litellm')));
    expect(copy.text, isNot(contains('upstream')));
  });

  test('the allowance 402 stays an allowance message, not a pick-Auto one', () {
    final copy = cloudErrorCopy(
      'daily_limit_reached',
      message: 'Daily Ovid allowance reached',
    );
    expect(copy.text, contains('plan allowance'));
    expect(copy.text, isNot(contains('Auto')));
    expect(copy.action, CloudErrorAction.openPlans);
  });

  test('the allowance reset reads as a clock time plus a span, not raw '
      'minutes', () {
    final now = DateTime(2026, 10, 19, 10, 48);
    final copy = cloudErrorCopy(
      'daily_limit_reached',
      resetsAt: DateTime(2026, 10, 19, 14, 0),
      now: now,
    );
    expect(copy.text, contains('at 14:00 (in 3 h 12 m)'));
  });

  test('short human server prose survives; the raw text stays as detail', () {
    final copy = cloudErrorCopy('bad_request',
        message: 'attachmentIds contains an unknown attachment id.');
    expect(copy.text, 'attachmentIds contains an unknown attachment id.');
    final provider = cloudErrorCopy('model_terminal', message: 'Upstream 500');
    expect(provider.detail, 'Upstream 500');
  });

  test('failure classes: transient keeps-and-retries, refused keeps-and-asks',
      () {
    CloudApiException e(int status, [String code = 'x']) =>
        CloudApiException(status: status, code: code, message: '');
    expect(classifyCloudFailure(e(0, 'timeout')), CloudFailureKind.transient);
    expect(classifyCloudFailure(e(429)), CloudFailureKind.transient);
    expect(classifyCloudFailure(e(503)), CloudFailureKind.transient);
    expect(classifyCloudFailure(const SocketException('dns')),
        CloudFailureKind.transient);
    expect(classifyCloudFailure(TimeoutException('t')),
        CloudFailureKind.transient);
    expect(classifyCloudFailure(e(401)), CloudFailureKind.refused);
    expect(classifyCloudFailure(e(402)), CloudFailureKind.refused);
    expect(classifyCloudFailure(e(400)), CloudFailureKind.refused);
    expect(classifyCloudFailure(e(409, 'run_conflict')),
        CloudFailureKind.alreadyAccepted);
    expect(cloudFailureCode(const SocketException('Failed host lookup')),
        'network');
  });
}
