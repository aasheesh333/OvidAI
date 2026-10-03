import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/grant_store.dart';

/// Approval decisions belong to the conversation, not its current mode.
void main() {
  const sid = 's1';

  GrantStore emptyStore() => GrantStore();

  group('grants are shared across modes within one session', () {
    test('a Studio grant is reused in General and Control', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/repos/widget', mode: 'studio', recursive: true);

      expect(
        store.isPathGranted(sid, '/repos/widget/lib', mode: 'studio'),
        isTrue,
      );
      expect(
        store.isPathGranted(sid, '/repos/widget/lib', mode: 'auto'),
        isTrue,
        reason: 'switching modes must reuse the session approval',
      );
      expect(
        store.isPathGranted(sid, '/repos/widget/lib', mode: 'control'),
        isTrue,
      );
      expect(
        store.isPathGranted(sid, '/repos/widget/lib', mode: 'safe'),
        isTrue,
      );

      store.addPathGrant(sid, '/session/ws', mode: 'auto', recursive: true);
      expect(store.isPathGranted(sid, '/session/ws/a', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/session/ws/a', mode: 'studio'), isTrue);
      expect(
        store.isPathGranted('other', '/session/ws/a', mode: 'studio'),
        isFalse,
      );
    });

    test('the same path in two modes is one session decision', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/shared', mode: 'studio', recursive: true);
      store.addPathGrant(sid, '/shared', mode: 'control', recursive: true);

      expect(store.isPathGranted(sid, '/shared/x', mode: 'studio'), isTrue);
      expect(store.isPathGranted(sid, '/shared/x', mode: 'control'), isTrue);
      expect(store.isPathGranted(sid, '/shared/x', mode: 'auto'), isTrue);
      expect(store.grantsFor(sid, mode: 'studio').length, 1);
      expect(store.grantsFor(sid, mode: 'control').length, 1);
    });

    test('hierarchical coverage still holds within a mode', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/a/b', mode: 'auto', recursive: true);

      expect(store.isPathGranted(sid, '/a/b', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/a/b/c/d.txt', mode: 'auto'), isTrue);
      expect(
        store.isPathGranted(sid, '/a/bc', mode: 'auto'),
        isFalse,
        reason: 'segment boundary, not string prefix',
      );
      expect(store.isPathGranted(sid, '/a', mode: 'auto'), isFalse);
    });

    test('legacy entries are reused within their owning session', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/old/path', recursive: true); // no mode tag

      expect(store.isPathGranted(sid, '/old/path/f', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/old/path/f', mode: 'studio'), isTrue);
      expect(store.isPathGranted(sid, '/old/path/f', mode: 'control'), isTrue);
    });
  });

  group('denials are persisted and win over allows', () {
    test('a recorded deny refuses the path and its children', () {
      final store = emptyStore();
      store.addPathDeny(sid, '/secret', mode: 'auto', recursive: true);

      expect(store.isPathDenied(sid, '/secret', mode: 'auto'), isTrue);
      expect(store.isPathDenied(sid, '/secret/keys.pem', mode: 'auto'), isTrue);
      expect(
        store.isPathGranted(sid, '/secret/keys.pem', mode: 'auto'),
        isFalse,
      );
    });

    test('a deny recorded AFTER an allow overrides it', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/data', mode: 'auto', recursive: true);
      expect(store.isPathGranted(sid, '/data/x', mode: 'auto'), isTrue);

      store.addPathDeny(sid, '/data', mode: 'auto', recursive: true);

      expect(
        store.isPathGranted(sid, '/data/x', mode: 'auto'),
        isFalse,
        reason: 'the later, more specific refusal must stand',
      );
      expect(store.isPathDenied(sid, '/data/x', mode: 'auto'), isTrue);
    });

    test('switching mode cannot bypass a refusal', () {
      final store = emptyStore();
      store.addPathDeny(sid, '/x', mode: 'auto', recursive: true);
      store.addPathGrant(sid, '/x', mode: 'studio', recursive: true);

      expect(store.isPathGranted(sid, '/x/y', mode: 'auto'), isFalse);
      expect(store.isPathGranted(sid, '/x/y', mode: 'studio'), isFalse);
      expect(store.isPathDenied('other', '/x/y', mode: 'studio'), isFalse);
    });

    test('hosts follow the same rules', () {
      final store = emptyStore();
      store.addHostGrant(sid, 'api.example.com', mode: 'studio');
      expect(
        store.isHostGranted(sid, 'api.example.com', mode: 'studio'),
        isTrue,
      );
      expect(store.isHostGranted(sid, 'api.example.com', mode: 'auto'), isTrue);

      store.addHostDeny(sid, 'api.example.com', mode: 'studio');
      expect(
        store.isHostGranted(sid, 'api.example.com', mode: 'studio'),
        isFalse,
      );
      expect(
        store.isHostDenied(sid, 'api.example.com', mode: 'studio'),
        isTrue,
      );
    });
  });

  group('the workspace root is real per mode', () {
    test('Full Access is the only unconfinable mode', () {
      expect(
        permissionWorkspaceRoot(modeName: 'drive', sessionWorkDir: '/ws'),
        isEmpty,
        reason: 'an empty root means "no jail", and callers must treat it so',
      );
    });

    test('General, Read-Only, Studio and Control are all jailed', () {
      for (final m in ['auto', 'safe', 'studio', 'control']) {
        expect(
          permissionWorkspaceRoot(modeName: m, sessionWorkDir: '/ws/$m'),
          '/ws/$m',
          reason: '$m must be confined to its session workspace',
        );
      }
    });
  });

  group('persistence round-trips mode and decision', () {
    test('toJson/fromJson preserve both', () {
      final allow = PermissionGrant.path(
        '/a/b',
        sessionId: sid,
        mode: 'studio',
      );
      final deny = PermissionGrant.path(
        '/a/b',
        sessionId: sid,
        mode: 'studio',
        decision: PermissionGrant.decisionDeny,
      );

      final a2 = PermissionGrant.fromJson(allow.toJson());
      expect(a2.mode, 'studio');
      expect(a2.decision, PermissionGrant.decisionAlways);
      expect(a2.isDeny, isFalse);

      final d2 = PermissionGrant.fromJson(deny.toJson());
      expect(d2.mode, 'studio');
      expect(d2.isDeny, isTrue);
    });

    test('an unknown decision is rejected, not silently accepted', () {
      expect(
        () => PermissionGrant.fromJson({
          'kind': 'path',
          'value': '/a',
          'scope': 'session',
          'sessionId': sid,
          'decision': 'maybe',
          'grantedAt': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing mode parses as legacy (empty), not as a wildcard', () {
      final g = PermissionGrant.fromJson({
        'kind': 'path',
        'value': '/a',
        'scope': 'session',
        'sessionId': sid,
        'grantedAt': DateTime.now().toIso8601String(),
      });
      expect(g.mode, isEmpty);
    });
  });
}
