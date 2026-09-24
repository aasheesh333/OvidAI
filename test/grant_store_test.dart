import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/grant_store.dart';

void main() {
  group('path grants are hierarchical', () {
    test('parent folder covers descendants, not siblings or parents', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work');

      // The folder itself and everything beneath it.
      expect(store.isPathGranted('s1', '/data/work'), isTrue);
      expect(store.isPathGranted('s1', '/data/work/a.txt'), isTrue);
      expect(store.isPathGranted('s1', '/data/work/sub/deep/b.txt'), isTrue);

      // Siblings, parents and lookalike prefixes are NOT covered.
      expect(store.isPathGranted('s1', '/data/work2'), isFalse);
      expect(store.isPathGranted('s1', '/data/work2/x.txt'), isFalse);
      expect(store.isPathGranted('s1', '/data'), isFalse);
      expect(store.isPathGranted('s1', '/'), isFalse);
      expect(store.isPathGranted('s1', '/other'), isFalse);
    });

    test('dot segments and redundant slashes normalize before matching', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work/');
      expect(store.isPathGranted('s1', '/data/work/./sub/../f.txt'), isTrue);
      expect(store.isPathGranted('s1', '//data//work//f.txt'), isTrue);
      // Escaping above the grant root is not covered.
      expect(store.isPathGranted('s1', '/data/work/../../etc/passwd'), isFalse);
    });

    test('granting a file covers only that file', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work/notes.txt');
      expect(store.isPathGranted('s1', '/data/work/notes.txt'), isTrue);
      expect(store.isPathGranted('s1', '/data/work/other.txt'), isFalse);
      expect(store.isPathGranted('s1', '/data/work'), isFalse);
    });
  });

  group('host grants', () {
    test('loopback grant covers the host on any port/path', () {
      final store = GrantStore();
      store.addHostGrant('s1', '127.0.0.1');
      expect(store.isHostGranted('s1', '127.0.0.1'), isTrue);
      // Ports are not part of host matching — every path on the host.
      expect(store.isHostGranted('s1', '127.0.0.1:8080'), isTrue);
      expect(store.isHostGranted('s1', '127.0.0.2'), isFalse);
      expect(store.isHostGranted('s1', 'localhost'), isFalse);
    });

    test('domain grant covers child domains, not siblings or parents', () {
      final store = GrantStore();
      store.addHostGrant('s1', 'example.com');
      expect(store.isHostGranted('s1', 'example.com'), isTrue);
      expect(store.isHostGranted('s1', 'api.example.com'), isTrue);
      expect(store.isHostGranted('s1', 'deep.api.example.com'), isTrue);
      expect(store.isHostGranted('s1', 'notexample.com'), isFalse);
      expect(store.isHostGranted('s1', 'example.com.evil.org'), isFalse);
      expect(store.isHostGranted('s1', 'com'), isFalse);
    });

    test('host normalization: case, port, brackets, trailing dot', () {
      final store = GrantStore();
      store.addHostGrant('s1', 'Example.COM:8443');
      expect(store.isHostGranted('s1', 'example.com'), isTrue);
      expect(store.isHostGranted('s1', 'EXAMPLE.com.'), isTrue);
      final v6 = GrantStore();
      v6.addHostGrant('s1', '[::1]');
      expect(v6.isHostGranted('s1', '::1'), isTrue);
    });
  });

  group('deny is not persisted', () {
    test('denied path leaves no grant behind', () {
      final store = GrantStore();
      // A deny records nothing: the user said no, so no grant is added and
      // there is nothing to serialize or revoke later.
      expect(store.isPathGranted('s1', '/data/secret'), isFalse);
      expect(store.sessionGrantsJson('s1'), isEmpty);
      expect(store.isHostGranted('s1', 'evil.example'), isFalse);
      expect(store.globalGrantsJson(), isEmpty);
    });

    test('revoking removes the grant entirely', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work');
      expect(store.isPathGranted('s1', '/data/work/f'), isTrue);
      expect(store.revokePathGrant('s1', '/data/work'), isTrue);
      expect(store.isPathGranted('s1', '/data/work/f'), isFalse);
      expect(store.sessionGrantsJson('s1'), isEmpty);
      expect(store.revokePathGrant('s1', '/data/work'), isFalse);
    });
  });

  group('scoping: session vs global', () {
    test('session grant does not leak into other sessions', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work');
      store.addHostGrant('s1', 'example.com');
      expect(store.isPathGranted('s2', '/data/work/f'), isFalse);
      expect(store.isHostGranted('s2', 'api.example.com'), isFalse);
      expect(store.isPathGranted('s1', '/data/work/f'), isTrue);
    });

    test('global grant applies to every session', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work');
      store.addHostGrant(null, 'internal.corp', global: true);
      expect(store.isHostGranted('s1', 'db.internal.corp'), isTrue);
      expect(store.isHostGranted('s2', 'db.internal.corp'), isTrue);
      expect(store.isHostGranted(null, 'internal.corp'), isTrue);
      // ...but the session grant stays session-local.
      expect(store.isPathGranted('s2', '/data/work/f'), isFalse);
    });

    test('clearing a session drops only its grants', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/a');
      store.addPathGrant('s2', '/data/b');
      store.addHostGrant(null, 'example.com', global: true);
      store.clearSession('s1');
      expect(store.isPathGranted('s1', '/data/a/f'), isFalse);
      expect(store.isPathGranted('s2', '/data/b/f'), isTrue);
      expect(store.isHostGranted('s1', 'example.com'), isTrue);
    });
  });

  group('serialization round-trip', () {
    test('grants survive toJson/fromJson', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work');
      store.addHostGrant('s1', 'example.com');
      store.addHostGrant(null, 'internal.corp', global: true);

      final sessionJson = store.sessionGrantsJson('s1');
      final globalJson = store.globalGrantsJson();

      final restored = GrantStore(
        sessionGrants: {'s1': PermissionGrant.listFromJson(sessionJson)},
        globalGrants: PermissionGrant.listFromJson(globalJson),
      );
      expect(restored.isPathGranted('s1', '/data/work/f'), isTrue);
      expect(restored.isHostGranted('s1', 'api.example.com'), isTrue);
      expect(restored.isHostGranted('s2', 'x.internal.corp'), isTrue);
      expect(restored.isPathGranted('s2', '/data/work/f'), isFalse);
    });

    test('missing or malformed grant JSON is tolerated', () {
      expect(PermissionGrant.listFromJson(null), isEmpty);
      expect(PermissionGrant.listFromJson([]), isEmpty);
      final grants = PermissionGrant.listFromJson([
        {'kind': 'path', 'value': '/a', 'scope': 'session'},
        {'nope': true},
        'junk',
        {'kind': 'host', 'value': '', 'scope': 'global'},
      ]);
      // Only the well-formed non-empty entry survives.
      expect(grants.length, 1);
      expect(grants.single.value, '/a');
    });
  });

  group('combined multi-target grants', () {
    test('several path grants each cover their own subtree', () {
      // Mirrors a combined approval card ("Always allow" on several
      // paths): each granted path is checked independently.
      final store = GrantStore();
      store.addPathGrant('s1', '/data/a');
      store.addPathGrant('s1', '/data/b');
      expect(store.isPathGranted('s1', '/data/a/f.txt'), isTrue);
      expect(store.isPathGranted('s1', '/data/b/deep/f.txt'), isTrue);
      expect(store.isPathGranted('s1', '/data/c/f.txt'), isFalse);
      // Revoking one leaves the other intact.
      expect(store.revokePathGrant('s1', '/data/a'), isTrue);
      expect(store.isPathGranted('s1', '/data/a/f.txt'), isFalse);
      expect(store.isPathGranted('s1', '/data/b/f.txt'), isTrue);
    });

    test('path and host grants coexist independently', () {
      final store = GrantStore();
      store.addPathGrant('s1', '/data/work');
      store.addHostGrant('s1', 'example.com');
      expect(store.isPathGranted('s1', '/data/work/f'), isTrue);
      expect(store.isHostGranted('s1', 'api.example.com'), isTrue);
      expect(store.sessionGrantsJson('s1'), hasLength(2));
    });
  });

  group('workspace root resolution', () {
    test('general mode pins the session workspace', () {
      expect(
        permissionWorkspaceRoot(
          modeName: 'auto',
          sessionWorkDir: '/work/s1',
          sessionId: 's1',
        ),
        '/work/s1',
      );
    });

    test('studio falls back to the session workspace when unbound', () {
      // The bound-folder lookup itself lives in AgentService (async,
      // via GlobalRepoRegistry); this helper is the sync fallback both
      // modes share.
      expect(
        permissionWorkspaceRoot(
          modeName: 'studio',
          sessionWorkDir: '/work/s1',
          sessionId: 's1',
        ),
        '/work/s1',
      );
    });

    test('default allowlist is loopback only', () {
      expect(
        defaultAllowedHosts,
        containsAll(['localhost', '127.0.0.1', '::1']),
      );
      expect(defaultAllowedHosts, isNot(contains('example.com')));
    });
  });
}
