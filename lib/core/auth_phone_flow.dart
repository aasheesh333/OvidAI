import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'auth_providers.dart';

class PhoneCallbacks {
  PhoneCallbacks({
    required this.completed,
    required this.failed,
    required this.codeSent,
    required this.timedOut,
  });
  final void Function(PhoneAuthCredential) completed;
  final void Function(FirebaseAuthException) failed;
  final void Function(String, int?) codeSent;
  final void Function(String) timedOut;
}

typedef PhoneVerifier =
    Future<void> Function(
      String number,
      int? resendToken,
      PhoneCallbacks callbacks,
    );

/// Owns one native OTP flow. Retrieval timeout is NOT code expiry. Firebase
/// determines actual SMS validity; the client additionally expires after 5 min.
class PhoneAuthFlow extends ChangeNotifier {
  PhoneAuthFlow({
    required this.verify,
    required this.apply,
    required this.currentUid,
    this.currentSession,
  });
  final PhoneVerifier verify;
  final Future<void> Function(AuthCredential) apply;
  final String? Function() currentUid;
  final int Function()? currentSession;
  int? _session;
  bool get _sameAccount =>
      currentUid() == _uid && currentSession?.call() == _session;
  Timer? _ticker;
  int _generation = 0;
  bool _disposed = false;
  String? _uid;
  String? _verificationId;
  int? _resendToken;
  int _remaining = 0;
  int _sends = 0;
  int _attempts = 0;
  String? number;
  String? error;
  bool sending = false;
  bool submitting = false;
  bool succeeded = false;
  int cooldown = 0;
  bool get hasCode => _verificationId != null && _remaining > 0;
  bool get canResend =>
      number != null &&
      !sending &&
      !submitting &&
      !succeeded &&
      cooldown == 0 &&
      _sends < 5;

  bool _live(int generation) =>
      !_disposed && generation == _generation && !succeeded;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> send(String value) async {
    if (sending || submitting || _disposed) return;
    final normalized = value.replaceAll(RegExp(r'[\s()-]'), '');
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(normalized)) {
      error = authError(FirebaseAuthException(code: 'invalid-phone-number'));
      _notify();
      return;
    }
    // A new number invalidates the old verification ID and Android resend token.
    if (number == normalized && cooldown > 0) return;
    _resendToken = null;
    number = normalized;
    _uid = currentUid();
    _session = currentSession?.call();
    await _request();
  }

  Future<void> resend() async {
    if (!canResend) return;
    if (!_sameAccount) {
      _accountChanged();
      return;
    }
    await _request();
  }

  Future<void> _request() async {
    if (_sends >= 5) {
      error = 'SMS request limit reached. Close this flow and try later.';
      _notify();
      return;
    }
    final generation = ++_generation;
    _ticker?.cancel();
    _verificationId = null;
    error = null;
    succeeded = false;
    sending = true;
    cooldown = 60;
    _remaining = 300;
    _attempts = 0;
    _sends++;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_live(generation)) return;
      // tick includes skipped intervals when the event loop was suspended.
      cooldown = timer.tick < 60 ? 60 - timer.tick : 0;
      _remaining = timer.tick < 300 ? 300 - timer.tick : 0;
      if (_remaining == 0 && !submitting) {
        _expire();
      } else if (cooldown == 0 && sending) {
        // Native verification may never call back (network/activity lost).
        sending = false;
        error = 'No SMS confirmation yet. You can request another code.';
      }
      _notify();
    });
    _notify();
    void code(String id, int? token) {
      if (!_live(generation) || submitting) return;
      if (!_sameAccount) {
        _accountChanged();
        return;
      }
      _verificationId = id;
      if (token != null) _resendToken = token;
      sending = false;
      error = null;
      _notify();
    }

    void failed(Object failure) {
      if (!_live(generation) || submitting) return;
      _generation++;
      _verificationId = null;
      sending = false;
      error = authError(failure);
      // Keep cooldown running even after a server rejection.
      _ticker?.cancel();
      final remainingCooldown = cooldown;
      _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
        cooldown = timer.tick < remainingCooldown
            ? remainingCooldown - timer.tick
            : 0;
        if (cooldown == 0) timer.cancel();
        _notify();
      });
      _notify();
    }

    try {
      await verify(
        number!,
        _resendToken,
        PhoneCallbacks(
          completed: (credential) {
            if (_live(generation)) unawaited(_complete(credential, generation));
          },
          failed: failed,
          codeSent: code,
          timedOut: (id) => code(id, null),
        ),
      );
    } catch (e) {
      failed(e);
    }
  }

  Future<void> submit(String code) async {
    if (submitting || succeeded || _disposed) return;
    if (!hasCode) {
      _expire();
      _notify();
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code.trim())) {
      error = 'Enter the six-digit SMS code.';
      _notify();
      return;
    }
    await _complete(
      PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: code.trim(),
      ),
      _generation,
    );
  }

  Future<void> _complete(PhoneAuthCredential credential, int generation) async {
    if (!_live(generation) || submitting) return;
    if (!_sameAccount) {
      _accountChanged();
      return;
    }
    if (_remaining <= 0 || _attempts >= 5) {
      _expire();
      _notify();
      return;
    }
    _attempts++;
    submitting = true;
    sending = false;
    error = null;
    _notify();
    try {
      // Listeners may synchronously cancel, dispose, or switch accounts.
      if (!_live(generation)) return;
      if (!_sameAccount) {
        _accountChanged();
        return;
      }
      await apply(credential);
      if (!_live(generation)) return;
      succeeded = true;
      _verificationId = null;
      _resendToken = null;
      _ticker?.cancel();
    } catch (e) {
      if (!_live(generation)) return;
      error = authError(e);
      if (_attempts >= 5 ||
          (e is FirebaseAuthException &&
              {
                'session-expired',
                'invalid-verification-id',
                'code-expired',
              }.contains(e.code))) {
        _expire();
      }
    } finally {
      submitting = false;
      _notify();
    }
  }

  void _expire() {
    _generation++;
    _verificationId = null;
    sending = false;
    submitting = false;
    _ticker?.cancel();
    cooldown = 0;
    error =
        'The verification code expired or the attempt limit was reached. Request a new code.';
  }

  void _accountChanged() {
    cancel();
    error = authError(FirebaseAuthException(code: 'account-changed'));
    _notify();
  }

  void cancel({bool notify = true}) {
    _generation++;
    _ticker?.cancel();
    _verificationId = null;
    _resendToken = null;
    number = null;
    sending = false;
    // An SDK credential submission already in flight cannot be cancelled.
    // Keep its lock until its Future settles, while invalidating its result.
    succeeded = false;
    error = null;
    if (notify) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
