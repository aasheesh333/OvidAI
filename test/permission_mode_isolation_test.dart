import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/grant_store.dart';

/// Per-mode permission isolation (2026-09-24).
///
/// The owner's requirement: each mode has its own set of allow / deny /
/// always-allow decisions, and **permissions must not conflict between modes**.
/// Before this, `PermissionGrant` had no mode dimension at all, so a path
/// granted while a session was in Studio stayed fully in force after the same
/// session switched to General — and a "global" grant applied to every session
/// in every mode. Denials were not recorded at all, so the user was re-asked for
/// the same path on every attempt.
void main() {
  const sid = 's1';

  GrantStore emptyStore() => GrantStore();

  group('a grant only applies in the mode it was made in', () {
    test('a Studio grant is invisible in General, and vice versa', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/repos/widget', mode: 'studio');

      expect(store.isPathGranted(sid, '/repos/widget/lib', mode: 'studio'),
          isTrue);
      expect(
        store.isPathGranted(sid, '/repos/widget/lib', mode: 'auto'),
        isFalse,
        reason: 'switching the same session to General must re-prompt',
      );
      expect(store.isPathGranted(sid, '/repos/widget/lib', mode: 'control'),
          isFalse);
      expect(
        store.isPathGranted(sid, '/repos/widget/lib', mode: 'safe'),
        isFalse,
      );

      store.addPathGrant(sid, '/session/ws', mode: 'auto');
      expect(store.isPathGranted(sid, '/session/ws/a', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/session/ws/a', mode: 'studio'), isFalse);
    });

    test('the same path in two modes is two separate decisions', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/shared', mode: 'studio');
      store.addPathGrant(sid, '/shared', mode: 'control');

      expect(store.isPathGranted(sid, '/shared/x', mode: 'studio'), isTrue);
      expect(store.isPathGranted(sid, '/shared/x', mode: 'control'), isTrue);
      expect(store.isPathGranted(sid, '/shared/x', mode: 'auto'), isFalse);
      expect(store.grantsFor(sid, mode: 'studio').length, 1);
      expect(store.grantsFor(sid, mode: 'control').length, 1);
    });

    test('hierarchical coverage still holds within a mode', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/a/b', mode: 'auto');

      expect(store.isPathGranted(sid, '/a/b', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/a/b/c/d.txt', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/a/bc', mode: 'auto'), isFalse,
          reason: 'segment boundary, not string prefix');
      expect(store.isPathGranted(sid, '/a', mode: 'auto'), isFalse);
    });

    test('legacy entries without a mode are honoured in General only', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/old/path'); // no mode tag

      expect(store.isPathGranted(sid, '/old/path/f', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/old/path/f', mode: 'studio'), isFalse);
      expect(store.isPathGranted(sid, '/old/path/f', mode: 'control'), isFalse);
    });
  });

  group('denials are persisted and win over allows', () {
    test('a recorded deny refuses the path and its children', () {
      final store = emptyStore();
      store.addPathDeny(sid, '/secret', mode: 'auto');

      expect(store.isPathDenied(sid, '/secret', mode: 'auto'), isTrue);
      expect(store.isPathDenied(sid, '/secret/keys.pem', mode: 'auto'), isTrue);
      expect(store.isPathGranted(sid, '/secret/keys.pem', mode: 'auto'), isFalse);
    });

    test('a deny recorded AFTER an allow overrides it', () {
      final store = emptyStore();
      store.addPathGrant(sid, '/data', mode: 'auto');
      expect(store.isPathGranted(sid, '/data/x', mode: 'auto'), isTrue);

      store.addPathDeny(sid, '/data', mode: 'auto');

      expect(
        store.isPathGranted(sid, '/data/x', mode: 'auto'),
        isFalse,
        reason: 'the later, more specific refusal must stand',
      );
      expect(store.isPathDenied(sid, '/data/x', mode: 'auto'), isTrue);
    });

    test('a deny in one mode does not bleed into another', () {
      final store = emptyStore();
      store.addPathDeny(sid, '/x', mode: 'auto');
      store.addPathGrant(sid, '/x', mode: 'studio');

      expect(store.isPathGranted(sid, '/x/y', mode: 'auto'), isFalse);
      expect(store.isPathGranted(sid, '/x/y', mode: 'studio'), isTrue);
    });

    test('hosts follow the same rules', () {
      final store = emptyStore();
      store.addHostGrant(sid, 'api.example.com', mode: 'studio');
      expect(store.isHostGranted(sid, 'api.example.com', mode: 'studio'), isTrue);
      expect(store.isHostGranted(sid, 'api.example.com', mode: 'auto'), isFalse);

      store.addHostDeny(sid, 'api.example.com', mode: 'studio');
      expect(store.isHostGranted(sid, 'api.example.com', mode: 'studio'), isFalse);
      expect(store.isHostDenied(sid, 'api.example.com', mode: 'studio'), isTrue);
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
      final allow = PermissionGrant.path('/a/b', sessionId: sid, mode: 'studio');
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
