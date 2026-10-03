import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/grant_store.dart';

void main() {
  for (final value in [null, '', ' \t\n ']) {
    test('persisted blank path $value cannot become a root grant', () {
      final json = <String, dynamic>{
        'kind': 'path',
        'scope': 'session',
        'sessionId': 's',
        'recursive': true,
        'value': value,
      };
      expect(() => PermissionGrant.fromJson(json), throwsFormatException);
      expect(PermissionGrant.listFromJson([json]), isEmpty);
    });
  }

  for (final value in ['', ' \t\n ']) {
    test('blank candidate never matches an exact root grant', () {
      expect(PermissionGrant.path('/').coversPath(value), isFalse);
    });

    test('blank path factory rejects $value before normalization', () {
      expect(() => PermissionGrant.path(value), throwsArgumentError);
    });

    test('blank path additions cannot authorize a subtree', () {
      final store = GrantStore();
      store.addPathGrant('s', value, recursive: true);
      store.addPathGrant(null, value, global: true, recursive: true);
      expect(store.isPathGranted('s', '/etc/passwd'), isFalse);
      expect(store.sessionGrantsJson('s'), isEmpty);
      expect(store.globalGrantsJson(), isEmpty);
      expect(pathCoveredBy(value, '/etc/passwd'), isFalse);
    });

    test('blank path operations do not match or replace an explicit root', () {
      final store = GrantStore();
      store.addPathGrant('s', '/', recursive: true);
      expect(store.isPathGranted('s', value), isFalse);
      expect(store.revokePathGrant('s', value), isFalse);
      store.addPathDeny('s', value, recursive: true);
      expect(store.isPathGranted('s', '/etc/passwd'), isTrue);
      expect(store.sessionGrantsJson('s'), hasLength(1));
    });
  }

  test('explicit persisted root remains valid and recursive only when specified', () {
    final grant = PermissionGrant.fromJson({
      'kind': 'path',
      'scope': 'session',
      'sessionId': 's',
      'value': ' / ',
      'recursive': true,
    });
    expect(grant.value, '/');
    expect(grant.coversPath('/etc/passwd'), isTrue);
    expect(PermissionGrant.path('/').coversPath('/etc/passwd'), isFalse);
  });
}
