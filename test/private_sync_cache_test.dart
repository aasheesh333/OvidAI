import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/cache.dart';

void main() {
  group('PrivateSyncCache', () {
    test('stores and retrieves projections by account and record', () {
      final cache = PrivateSyncCache<String, String>();

      cache.put('account-a', 'record-1', 'projection');

      expect(cache.get('account-a', 'record-1'), 'projection');
      expect(cache.get('account-a', 'missing'), isNull);
      expect(cache.get('account-b', 'record-1'), isNull);
    });

    test('replaces an existing projection for the same record', () {
      final cache = PrivateSyncCache<String, String>();

      cache.put('account-a', 'record-1', 'old');
      cache.put('account-a', 'record-1', 'new');

      expect(cache.get('account-a', 'record-1'), 'new');
    });

    test('record invalidation removes only the matching projection', () {
      final cache = PrivateSyncCache<String, String>();
      cache.put('account-a', 'record-1', 'one');
      cache.put('account-a', 'record-2', 'two');
      cache.put('account-b', 'record-1', 'other-account');

      cache.invalidateRecord('account-a', 'record-1');

      expect(cache.get('account-a', 'record-1'), isNull);
      expect(cache.get('account-a', 'record-2'), 'two');
      expect(cache.get('account-b', 'record-1'), 'other-account');
    });

    test('tombstone invalidation removes the targeted projection', () {
      final cache = PrivateSyncCache<String, String>();
      cache.put('account-a', 'record-1', 'projection');

      cache.invalidateTombstone('account-a', 'record-1');

      expect(cache.get('account-a', 'record-1'), isNull);
    });

    test('account clear removes all projections for that account only', () {
      final cache = PrivateSyncCache<String, String>();
      cache.put('account-a', 'record-1', 'one');
      cache.put('account-a', 'record-2', 'two');
      cache.put('account-b', 'record-1', 'other-account');

      cache.clearAccount('account-a');

      expect(cache.get('account-a', 'record-1'), isNull);
      expect(cache.get('account-a', 'record-2'), isNull);
      expect(cache.get('account-b', 'record-1'), 'other-account');
    });

    test('clear disposes every projection and allows reuse', () {
      final cache = PrivateSyncCache<String, String>();
      cache.put('account-a', 'record-1', 'projection');

      cache.clear();

      expect(cache.get('account-a', 'record-1'), isNull);
      cache.put('account-a', 'record-1', 'reused');
      expect(cache.get('account-a', 'record-1'), 'reused');
    });
  });
}
