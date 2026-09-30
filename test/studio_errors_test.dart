import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
        expect(f.message.toLowerCase(), contains('sign in'),
            reason: '${f.message} should tell the user to sign in again');
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
}
