// Worker D regression tests: grant_store hardening fixes.
//
// 1. IP-literal host grants match only themselves (docstring already
//    promised this; the code did a suffix match, so `evil.127.0.0.1`
//    rode on a loopback grant).
// 2. A grant on the filesystem root `/` covers every absolute path
//    (`startsWith('//')` used to make it cover nothing).
// 3. PermissionGrant.fromJson rejects unknown kind/scope and normalizes
//    values by kind (hand-edited persisted data can't smuggle junk in).
// 4. addPathGrant/addHostGrant refuse non-global grants with a null/empty
//    session id (they used to land in an unreachable '' bucket).
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/grant_store.dart';

void main() {
  group('IP literal host grants match only themselves', () {
    test('IPv4 grant does not cover attacker child names', () {
      expect(hostCoveredBy('127.0.0.1', '127.0.0.1'), isTrue);
      expect(hostCoveredBy('127.0.0.1', '127.0.0.1:8080'), isTrue);
      expect(hostCoveredBy('127.0.0.1', 'evil.127.0.0.1'), isFalse);
      expect(hostCoveredBy('127.0.0.1', '127.0.0.2'), isFalse);
    });

    test('IPv6 grant does not cover suffix lookalikes', () {
      expect(hostCoveredBy('::1', '::1'), isTrue);
      expect(hostCoveredBy('[::1]', '::1'), isTrue);
      expect(hostCoveredBy('::1', 'evil.::1'), isFalse);
    });

    test('DNS grants still cover child domains', () {
      expect(hostCoveredBy('example.com', 'api.example.com'), isTrue);
      expect(hostCoveredBy('example.com', 'example.com'), isTrue);
      expect(hostCoveredBy('example.com', 'notexample.com'), isFalse);
    });

    test('store-level: loopback grant is not exploitable via child name', () {
      final store = GrantStore();
      store.addHostGrant('s1', '127.0.0.1');
      expect(store.isHostGranted('s1', '127.0.0.1'), isTrue);
      expect(store.isHostGranted('s1', 'evil.127.0.0.1'), isFalse);
    });
  });

  group('root path grant covers everything', () {
    test('pathCoveredBy with a root grant', () {
      expect(pathCoveredBy('/', '/'), isTrue);
      expect(pathCoveredBy('/', '/etc/passwd'), isTrue);
      expect(pathCoveredBy('/', '/a/b/c'), isTrue);
      // Non-root behavior is unchanged.
      expect(pathCoveredBy('/a/b', '/a/bc'), isFalse);
      expect(pathCoveredBy('/a/b', '/a/b/c'), isTrue);
    });

    test('store-level root grant', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/');
      expect(store.isPathGranted('s1', '/anywhere/at/all.txt'), isTrue);
      expect(store.isPathGranted('other', '/anywhere/at/all.txt'), isFalse);
    });
  });

  group('fromJson validates persisted grants', () {
    test('unknown kind or scope entries are skipped', () {
      final grants = PermissionGrant.listFromJson([
        {'kind': 'path', 'value': '/a', 'scope': 'session'},
        {'kind': 'superuser', 'value': '/a', 'scope': 'session'},
        {'kind': 'path', 'value': '/a', 'scope': 'whenever'},
        {'kind': 'host', 'value': '', 'scope': 'global'},
      ]);
      expect(grants.length, 1);
      expect(grants.single.value, '/a');
    });

    test('values are re-normalized by kind on load', () {
      final grants = PermissionGrant.listFromJson([
        {
          'kind': 'path',
          'value': '/a/b/../c',
          'scope': 'session',
          'sessionId': 's1',
        },
        {'kind': 'host', 'value': 'EXAMPLE.com:443', 'scope': 'global'},
      ]);
      expect(grants.length, 2);
      expect(grants[0].value, '/a/c');
      expect(grants[1].value, 'example.com');
    });
  });

  group('session grants need a real session id', () {
    test('null/empty session id grants are refused, globals still work', () {
      final store = GrantStore();
      store.addPathGrant(null, '/secret');
      store.addPathGrant('', '/secret');
      store.addHostGrant(null, 'evil.example.com');
      store.addHostGrant('', 'evil.example.com');
      expect(store.sessionGrants, isEmpty);
      expect(store.isPathGranted('s1', '/secret/x'), isFalse);
      expect(store.isHostGranted('s1', 'evil.example.com'), isFalse);

      // Global grants with a null session id are legitimate.
      store.addPathGrant(null, '/shared', global: true);
      store.addHostGrant(null, 'cdn.example.com', global: true);
      expect(store.isPathGranted('s1', '/shared/f'), isTrue);
      expect(store.isHostGranted('s9', 'cdn.example.com'), isTrue);
    });
  });
}
