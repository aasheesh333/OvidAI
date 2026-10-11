import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ovid_ai/core/github_http_error.dart';
import 'package:ovid_ai/core/repo_cache.dart';

import 'package:ovid_ai/ui/studio_errors.dart';

/// Raw exception strings were shown verbatim to users at studio_screen.dart
/// :180, :439, :492, :699, :758, :883 (2026-09-30 audit). Users got
/// "Repo sync failed: Exception: tree fetch 404". These pins hold the
/// human-message / secondary-detail split.
void main() {
  group('StudioFailure keeps infra detail out of the headline', () {
    test('the detail is preserved verbatim for the secondary line', () {
      final f = StudioFailure.of(Exception('tree fetch 404'));
      expect(f.detail, contains('tree fetch 404'));
    });

    test('the headline is human, never the raw exception', () {
      final f = StudioFailure.of(Exception('tree fetch 404'));
      expect(f.message, isNot(contains('Exception')));
      expect(f.message, isNot(contains('tree fetch 404')));
      expect(f.message, isNot(equals(f.detail)));
      expect(f.message, endsWith('.'));
      expect(f.message.length, greaterThan(12));
    });

    test('a missing repo/branch reads as "not found"', () {
      final f = StudioFailure.of(Exception('tree fetch 404'));
      expect(f.message.toLowerCase(), contains('not find'));
    });

    test('an auth rejection points at signing in again', () {
      for (final e in [
        Exception('repos fetch failed: 401'),
        Exception('contents PUT x failed: 403'),
      ]) {
        final f = StudioFailure.of(e);
        expect(
          f.message.toLowerCase(),
          contains('sign in'),
          reason: '${f.message} should tell the user to sign in again',
        );
      }
    });

    test('a network failure reads as "no connection"', () {
      final f = StudioFailure.of(
        const SocketException('Failed host lookup', osError: null),
      );
      expect(f.message.toLowerCase(), contains('connection'));
      expect(f.detail, contains('Failed host lookup'));
    });

    test('a timeout reads as "took too long"', () {
      final f = StudioFailure.of(TimeoutException('after 20s'));
      expect(f.message.toLowerCase(), contains('too long'));
    });

    test('an unbound repo reads as "connect a repository first"', () {
      final f = StudioFailure.of(StateError('repo not bound'));
      expect(f.message.toLowerCase(), contains('connect'));
    });

    test('a clone failure reads as a clone problem', () {
      final f = StudioFailure.of(
        Exception('git clone o/r@main failed (exit 128): fatal: bad repo'),
      );
      expect(f.message.toLowerCase(), contains('clone'));
      expect(f.message, isNot(contains('exit 128')));
    });

    test('a vanished binding reads as a retry, not a crash', () {
      final f = StudioFailure.of(StateError('repository binding changed'));
      expect(f.message.toLowerCase(), contains('switched'));
    });

    test('an unknown error still gets a human fallback', () {
      final f = StudioFailure.of('weird raw string with 0xDEADBEEF');
      expect(f.message, isNot(contains('0xDEADBEEF')));
      expect(f.message.toLowerCase(), contains('went wrong'));
      expect(f.detail, contains('0xDEADBEEF'));
    });

    test('multi-line stack traces keep only the first line as detail', () {
      final f = StudioFailure.of(Exception('boom\n#0 foo()\n#1 bar()'));
      expect(f.detail, isNot(contains('#0')));
      expect(f.detail, contains('boom'));
    });
  });
  group('StudioFailure classifies by type, not by digits (F-175)', () {
    test(
      'a SHA, line number or path with 401/403/404 is not an HTTP status',
      () {
        for (final raw in [
          'commit a403f1c failed',
          'parse error at line 1401',
          'cannot open /tmp/x4040/y',
        ]) {
          final m = StudioFailure.of(Exception(raw)).message.toLowerCase();
          expect(m, isNot(contains('sign in')), reason: raw);
          expect(m, isNot(contains('could not find')), reason: raw);
        }
      },
    );

    test('a 403 rate limit reads as a rate limit with the reset time', () {
      final reset = DateTime(2026, 10, 11, 14, 5);
      final e = GitHubHttpException.fromResponse(
        'repos fetch',
        http.Response(
          '{"message":"API rate limit exceeded for user"}',
          403,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '${reset.millisecondsSinceEpoch ~/ 1000}',
          },
        ),
      );
      final f = StudioFailure.of(e);
      expect(f.message.toLowerCase(), contains('limit'));
      expect(f.message, contains('14:05'));
      expect(f.message.toLowerCase(), isNot(contains('sign in')));
    });

    test('"API rate limit exceeded" text maps to rate-limit copy', () {
      final f = StudioFailure.of(Exception('API rate limit exceeded (403)'));
      expect(f.message.toLowerCase(), contains('limit'));
      expect(f.message.toLowerCase(), isNot(contains('sign in')));
    });

    test('typed 401 maps to sign-in, 404 to not found', () {
      expect(
        StudioFailure.of(const GitHubHttpException('x', 401)).message,
        contains('sign in'),
      );
      expect(
        StudioFailure.of(const GitHubHttpException('x', 404)).message,
        contains('could not find'),
      );
    });

    test('file-system errors never mention GitHub', () {
      for (final e in [
        const FileSystemException(
          'Cannot open file',
          '/x/y',
          OSError('No such file or directory', 2),
        ),
        const FileSystemException(
          'Write failed',
          '/x/y',
          OSError('No space left on device', 28),
        ),
        Exception('OS Error: No such file or directory, errno = 2, x'),
      ]) {
        final m = StudioFailure.of(e).message;
        expect(m, isNot(contains('GitHub')), reason: '$e');
      }
      expect(
        StudioFailure.of(
          const FileSystemException('w', 'p', OSError('No space', 28)),
        ).message.toLowerCase(),
        contains('storage'),
      );
    });

    test('a sandbox command timeout is not blamed on GitHub', () {
      final m = StudioFailure.of('PTY command timed out (60s)').message;
      expect(m, isNot(contains('GitHub')));
    });

    test('commit failures map by kind', () {
      final stale = StudioFailure.of(
        const CommitFailure(CommitFailureKind.staleApproval, 'raw'),
      );
      expect(stale.message.toLowerCase(), contains('review'));
      final unknown = StudioFailure.of(
        const CommitFailure(CommitFailureKind.unknown, 'raw', intendedSha: 'a'),
      );
      expect(unknown.message.toLowerCase(), contains('check'));
    });

    test('tokens are redacted from the detail line', () {
      final f = StudioFailure.of(
        Exception('fatal: https://x-access-token:ghp_abc123@github.com/o/r'),
      );
      expect(f.detail, isNot(contains('ghp_abc123')));
      expect(f.detail, contains('[redacted]'));
    });
  });
}
