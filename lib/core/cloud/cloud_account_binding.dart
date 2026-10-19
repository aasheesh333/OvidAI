import 'dart:async';

import 'package:flutter/foundation.dart';

import '../diag.dart';

/// Binds the account-scoped cloud plumbing (push registration, the WS link,
/// session sync, Play billing state) to whichever account is ready — on
/// EVERY account change, not once per process (SH-003, SH-008, SH-013,
/// CT-006).
///
/// * An account becomes ready → [onBind] for it (after [onUnbind] for the
///   previous account when this is a switch without an observed sign-out).
/// * The user signs out → [onUnbind] for the account that was bound.
///
/// Transitions are serialised: a fast A → signed out → B never interleaves
/// A's teardown with B's setup.
class CloudAccountBinding {
  CloudAccountBinding({
    required this.auth,
    required this.readyUid,
    required this.signedIn,
    required this.onBind,
    required this.onUnbind,
  });

  /// Notifies on every auth / admission change (FirebaseService).
  final Listenable auth;

  /// The uid when that account is fully ready (signed in + admitted +
  /// session namespace bound), else null.
  final String? Function() readyUid;

  /// Whether any user is signed in (ready or not).
  final bool Function() signedIn;

  final Future<void> Function(String uid) onBind;
  final Future<void> Function(String previousUid) onUnbind;

  String? _bound;
  bool _started = false;
  Future<void> _chain = Future<void>.value();

  /// The uid the cloud plumbing is currently bound to.
  String? get boundUid => _bound;

  /// Completes when every queued transition has run (tests).
  @visibleForTesting
  Future<void> get idle => _chain;

  void start() {
    if (_started) return;
    _started = true;
    auth.addListener(_sync);
    _sync();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    auth.removeListener(_sync);
  }

  void _sync() {
    final ready = readyUid();
    final previous = _bound;
    if (ready != null && ready != previous) {
      _bound = ready;
      _enqueue(() async {
        if (previous != null) await onUnbind(previous);
        await onBind(ready);
      });
      return;
    }
    if (ready == null && previous != null && !signedIn()) {
      _bound = null;
      _enqueue(() => onUnbind(previous));
    }
  }

  void _enqueue(Future<void> Function() op) {
    _chain = _chain.then((_) async {
      try {
        await op();
      } catch (e, st) {
        Diag.swallow('cloud.account_binding', e, st);
      }
    });
  }
}
