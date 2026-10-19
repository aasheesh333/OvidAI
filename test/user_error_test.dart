import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/diag.dart';
import 'package:ovid_ai/l10n/l10n.dart';
import 'package:ovid_ai/ui/user_error.dart';
import 'package:ovid_ai/ui/widgets/error_views.dart';

/// Strings that must never reach a headline a user reads.
final _rawLeak = RegExp(
  r'Bad state|Exception|StateError|FormatException|TypeError|'
  r'is not a subtype|#\d+\s|HTTP \d{3}|\(\d{3}\)',
);

void main() {
  final l = appLocalizationsFallback;

  setUp(Diag.resetForTest);

  group('friendlyError table', () {
    final cases = <(String, Object, UserErrorKind, String)>[
      (
        'SocketException',
        const SocketException('Failed host lookup: api.x'),
        UserErrorKind.offline,
        l.errorOffline,
      ),
      (
        'ClientException',
        http.ClientException('Connection closed'),
        UserErrorKind.offline,
        l.errorOffline,
      ),
      (
        'TimeoutException',
        TimeoutException('t', const Duration(seconds: 15)),
        UserErrorKind.timeout,
        l.errorTimeout,
      ),
      (
        'StateError',
        StateError('Resume background execution first'),
        UserErrorKind.notNow,
        l.errorNotNow,
      ),
      (
        'FormatException',
        const FormatException('Unexpected character'),
        UserErrorKind.badResponse,
        l.errorBadResponse,
      ),
      (
        'PlatformException',
        PlatformException(code: 'read_external_storage_denied'),
        UserErrorKind.device,
        l.errorDevice,
      ),
      (
        'FileSystemException',
        const FileSystemException('Cannot open', '/x'),
        UserErrorKind.file,
        l.errorFile,
      ),
      (
        'HTTP 401',
        const HttpStatusException(401),
        UserErrorKind.unauthorized,
        l.errorUnauthorized,
      ),
      (
        'HTTP 403',
        const HttpStatusException(403),
        UserErrorKind.forbidden,
        l.errorForbidden,
      ),
      (
        'HTTP 404',
        const HttpStatusException(404),
        UserErrorKind.notFound,
        l.errorNotFound,
      ),
      (
        'HTTP 429',
        const HttpStatusException(429),
        UserErrorKind.rateLimited,
        l.errorRateLimited,
      ),
      (
        'HTTP 500',
        const HttpStatusException(500),
        UserErrorKind.server,
        l.errorServer,
      ),
      (
        'HTTP 503 string',
        Exception('HTTP 503 Service Unavailable'),
        UserErrorKind.server,
        l.errorServer,
      ),
      ('unknown', Exception('boom'), UserErrorKind.unknown, l.errorGeneric),
    ];
    for (final (name, error, kind, message) in cases) {
      test(name, () {
        final mapped = UserError.from(error);
        expect(mapped.kind, kind);
        expect(mapped.message, message);
        expect(friendlyError(error), message);
        expect(mapped.message, isNot(matches(_rawLeak)));
      });
    }

    test(
      'type error from a JSON-array body reads as an unexpected response',
      () {
        Object? caught;
        try {
          final dynamic j = <dynamic>[];
          // ignore: unused_local_variable
          final Map<String, dynamic> m = j as Map<String, dynamic>;
        } catch (e) {
          caught = e;
        }
        expect(UserError.from(caught!).kind, UserErrorKind.badResponse);
      },
    );

    test('status helper maps the 5xx range, 402 and leaves 418 unknown', () {
      expect(UserError.fromHttpStatus(502).kind, UserErrorKind.server);
      expect(UserError.fromHttpStatus(418).kind, UserErrorKind.unknown);
      expect(UserError.fromHttpStatus(401).message, l.errorUnauthorized);
      expect(UserError.fromHttpStatus(402).kind, UserErrorKind.quotaExceeded);
      expect(UserError.fromHttpStatus(402).message, l.errorQuotaExceeded);
    });
  });

  // The shapes CloudRestClient actually throws: every non-2xx gateway answer
  // arrives as a CloudApiException whose toString carries no `HTTP nnn`, so
  // these only classify through the typed status.
  group('CloudApiException (the gateway error shape)', () {
    final cases = <(String, CloudApiException, UserErrorKind, String)>[
      (
        '401 unauthenticated',
        CloudApiException(
          status: 401,
          code: 'unauthenticated',
          message: 'Sign in to use Ovid Cloud.',
        ),
        UserErrorKind.unauthorized,
        l.errorUnauthorized,
      ),
      (
        '402 daily_limit_reached',
        CloudApiException(
          status: 402,
          code: 'daily_limit_reached',
          message: 'Daily limit reached. Your allowance resets automatically.',
        ),
        UserErrorKind.quotaExceeded,
        l.errorQuotaExceeded,
      ),
      (
        '403 forbidden',
        CloudApiException(
          status: 403,
          code: 'forbidden',
          message: 'This account cannot use that feature.',
        ),
        UserErrorKind.forbidden,
        l.errorForbidden,
      ),
      (
        '404 not_found',
        CloudApiException(
          status: 404,
          code: 'not_found',
          message: 'Session not found.',
        ),
        UserErrorKind.notFound,
        l.errorNotFound,
      ),
      (
        '429 rate_limited',
        CloudApiException(
          status: 429,
          code: 'rate_limited',
          message: 'Too many requests. Slow down.',
        ),
        UserErrorKind.rateLimited,
        l.errorRateLimited,
      ),
      (
        '0 timeout (request cut off before any answer)',
        CloudApiException(
          status: 0,
          code: 'timeout',
          message: 'Ovid Cloud did not answer in time.',
        ),
        UserErrorKind.timeout,
        l.errorTimeout,
      ),
      (
        '500 internal',
        CloudApiException(
          status: 500,
          code: 'internal',
          message: 'Ovid Cloud request failed (HTTP 500).',
        ),
        UserErrorKind.server,
        l.errorServer,
      ),
    ];
    for (final (name, error, kind, message) in cases) {
      test(name, () {
        final mapped = UserError.from(error);
        expect(mapped.kind, kind);
        expect(mapped.statusCode, error.status);
        expect(mapped.message, message);
        expect(friendlyError(error), message);
        expect(mapped.message, isNot(matches(_rawLeak)));
      });
    }

    test('the server envelope message becomes the detail line', () {
      expect(
        UserError.from(
          CloudApiException(
            status: 402,
            code: 'daily_limit_reached',
            message: 'Daily limit reached.',
            resetsAt: DateTime.utc(2026, 10, 19),
          ),
        ).detail,
        'Daily limit reached.',
      );
      expect(
        UserError.from(const HttpStatusException(402)).detail,
        'HTTP 402',
      );
    });
  });

  test('detail drops Dart type prefixes and continuation lines', () {
    expect(
      UserError.from(StateError('Resume background execution first')).detail,
      'Resume background execution first',
    );
    expect(
      UserError.from(Exception('Bad state: nested\n#0 main (x.dart:1)')).detail,
      'nested',
    );
  });

  test('log tag records the raw error in Diag', () {
    final error = StateError('raw text');
    UserError.from(error, log: 'test.ctx');
    final entry = Diag.recent().single;
    expect(entry.context, 'test.ctx');
    expect(entry.error, contains('Bad state: raw text'));
  });

  testWidgets('ErrorRetryView hides details until asked and retries', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorRetryView(
            message: 'Couldn\'t load.',
            detail: 'socket closed',
            onRetry: () => retries++,
          ),
        ),
      ),
    );
    expect(find.text('socket closed'), findsNothing);
    await tester.tap(find.text(l.errorDetailsShow));
    await tester.pump();
    expect(find.text('socket closed'), findsOneWidget);
    expect(find.byTooltip(l.errorDetailsCopy), findsOneWidget);
    await tester.tap(find.text(l.actionRetry));
    expect(retries, 1);
  });

  testWidgets('release error widget shows copy instead of framework text', (
    tester,
  ) async {
    // The binding verifies the builder is restored before teardown runs.
    final previous = ErrorWidget.builder;
    late Widget widget;
    try {
      installReleaseErrorWidget(force: true);
      widget = ErrorWidget.builder(
        FlutterErrorDetails(exception: StateError('build blew up')),
      );
    } finally {
      ErrorWidget.builder = previous;
    }
    await tester.pumpWidget(widget);
    expect(find.text(l.errorWidgetFallback), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(Diag.recent().last.context, 'flutter.error_widget');
  });
}
