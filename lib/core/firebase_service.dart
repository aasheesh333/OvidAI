import 'dart:async';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'diag.dart';
import 'cloud_app_check.dart';
import 'account_service.dart';
import 'account_session.dart';
import 'state.dart';
import 'image_studio.dart';
import 'ovid_cloud_service.dart';
import 'auth_identity.dart';
import 'auth_phone_flow.dart';
import 'auth_providers.dart';

/// Firebase bootstrap + auth + consent-gated telemetry.
///
/// Design:
///  • Configured social/phone identity; LoginGate requires a nonanonymous account.
///  • Analytics & Crashlytics are OFF until the user explicitly opts in
///    (Play-policy: data collection requires consent). Consent is persisted.
///  • google-services.json is injected at build time via the
///    GOOGLE_SERVICES_JSON CI secret — never committed to the repo.
///  • If Firebase is not configured (debug/local without the file), readiness
///    reports initialization failure while all feature methods stay safe.
class FirebaseService extends ChangeNotifier {
  FirebaseService._({
    this._initializeApp,
    Future<void> Function()? configure,
    AuthIdentity? identity,
    User? initialUser,
    Stream<User?>? userChanges,
  }) : _configureForTest = configure,
       _userChangesForTest = userChanges,
       _authIdentity = identity,
       _user = initialUser {
    identity?.observeUser(initialUser);
  }

  static final FirebaseService I = FirebaseService._();

  @visibleForTesting
  FirebaseService.forTest({
    required Future<void> Function() initializeApp,
    required Future<void> Function() configure,
    AuthIdentity? identity,
    User? initialUser,
    Stream<User?>? userChanges,
  }) : this._(
         initializeApp: initializeApp,
         configure: configure,
         identity: identity,
         initialUser: initialUser,
         userChanges: userChanges,
       );

  static const _consentKey = 'ovid_telemetry_consent'; // 'yes' | 'no' | null

  bool _available = false;
  bool _consentGiven = false;
  bool _consentAsked = false;
  User? _user;

  bool get isAvailable => _available;

  /// True once Firebase is up and the first auth state was observed, which
  /// happens BEFORE that account's chat history has hydrated. LoginGate leaves
  /// the splash here and covers hydration with the account-not-ready screen,
  /// so cold start no longer grows with history size (F-045).
  bool get firstUserKnown => _firstUserKnown;
  bool _firstUserKnown = false;

  void _publishFirstUser() {
    if (_firstUserKnown) return;
    _firstUserKnown = true;
    notifyListeners();
  }
  bool get consentGiven => _consentGiven;
  bool get consentAsked => _consentAsked;
  bool get isSignedIn => _user != null && !_user!.isAnonymous;
  final _accountSession = AccountSession();
  bool get accountReady =>
      isSignedIn &&
      AppState.I.sessionAccountReady &&
      AppState.I.sessionAccountId == 'firebase:$uid' &&
      (!accountService.enabled || _accountSession.ready);
  String? get accountError => _accountSession.error;
  late final accountService = AccountService(
    idToken: (force) => getIdToken(forceRefresh: force),
    // OVID_APPCHECK off (default): no provider, no header, no requirement.
    appCheck: kOvidAppCheck ? () => FirebaseAppCheck.instance.getToken() : null,
    currentUid: () => uid,
  );
  AccountDeletion? lastDeletionReceipt;

  /// True when the last accepted deletion request could not erase this
  /// device's copy. The server request still stands; Data control → Delete
  /// data is the retry. Never reported as a clean device.
  bool deletionDeviceEraseFailed = false;

  /// Erases this device's copy of the account (transcripts, search index,
  /// drafts, cache, secure store and sign-in) once the server has accepted a
  /// deletion request. Registered by the settings owner, which owns the only
  /// verified all-store reset; null on hosts without one (tests, desktop).
  ///
  /// It runs BEFORE the sign-out so a failed store can still be reported and,
  /// when the failure precedes the reset's own sign-out store, the person stays
  /// signed in with Data control available to retry. The reset's account store
  /// performs the local sign-out when it succeeds.
  Future<void> Function()? eraseDeviceCopyOnDeletion;
  User? get user => _user;
  String? get email => _user?.email;
  String? get displayName => _user?.displayName;
  String? get photoUrl => _user?.photoURL;
  String? get uid => _user?.uid;
  bool get emailVerified => _user?.emailVerified ?? false;
  String? get phoneNumber => _user?.phoneNumber;

  /// What to call the signed-in user (SH-024): display name, then email,
  /// then phone number, then "Ovid user" — never "Signed in / Signed in".
  String get accountLabel {
    for (final v in [displayName, email, phoneNumber]) {
      final t = v?.trim();
      if (t != null && t.isNotEmpty) return t;
    }
    return 'Ovid user';
  }

  /// The second line under [accountLabel]: the first identifier not already
  /// used as the label, else the sign-in method.
  String get accountDetail {
    final label = accountLabel;
    for (final v in [email, phoneNumber]) {
      final t = v?.trim();
      if (t != null && t.isNotEmpty && t != label) return t;
    }
    return phoneNumber != null ? 'Signed in with phone' : 'Signed in';
  }
  final authProviders = AuthProviders();
  AuthIdentity? _authIdentity;
  AuthIdentity get _identity => _authIdentity ??= AuthIdentity(
    auth: () => FirebaseAuth.instance,
    providers: authProviders,
    googleCredential: () async {
      final google = await GoogleSignIn().signIn();
      if (google == null) return null;
      final tokens = await google.authentication;
      return GoogleAuthProvider.credential(
        accessToken: tokens.accessToken,
        idToken: tokens.idToken,
      );
    },
  );
  Set<String> get linkedProviderIds =>
      _user?.providerData.map((p) => p.providerId).toSet() ?? {};
  List<AuthProviderCapability> get reauthProviders => authProviders.enabled
      .where((p) => linkedProviderIds.contains(p.id))
      .toList();
  int _authRevision = 0;
  Future<void>? _accountAdmission;
  String? _accountAdmissionUid;

  StreamSubscription<User?>? _authSub;
  Future<void>? _initialization;
  Future<void>? _appInitialization;
  final Future<void> Function()? _initializeApp;
  final Future<void> Function()? _configureForTest;
  final Stream<User?>? _userChangesForTest;

  /// Initialize Firebase if a config is present. Safe to call on all builds.
  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;
    late final Future<void> attempt;
    attempt = _initialize().catchError((Object error, StackTrace stack) {
      if (identical(_initialization, attempt)) _initialization = null;
      Error.throwWithStackTrace(error, stack);
    });
    _initialization = attempt;
    return attempt;
  }

  /// Initializes only the Firebase app, the stored consent flag and the
  /// Crashlytics handlers, before the first frame.
  ///
  /// [initialize] runs inside the readiness pipeline, after `runApp`, so a
  /// failure during startup would otherwise never reach Crashlytics. This does
  /// the minimum needed to report one. It is not a consent bypass: the Android
  /// manifest ships `firebase_crashlytics_collection_enabled=false` and
  /// [_applyTelemetryFlags] applies the stored choice, so Crashlytics drops
  /// every event until the user opts in.
  Future<void> initializeCrashReporting() async {
    try {
      await _ensureApp();
      _available = true;
    } catch (e) {
      debugPrint('Firebase unavailable: $e');
      return;
    }
    try {
      await _restoreConsent();
    } catch (e) {
      Diag.swallow('firebase.consent', e);
    }
    _attachCrashHandlers();
  }

  /// The Firebase app, initialized at most once. A failed attempt clears the
  /// cache so [initialize] can retry.
  Future<void> _ensureApp() {
    final existing = _appInitialization;
    if (existing != null) return existing;
    late final Future<void> attempt;
    attempt = (() async {
      if (_initializeApp != null) {
        await _initializeApp();
      } else {
        await Firebase.initializeApp();
      }
    })().catchError((Object error, StackTrace stack) {
      if (identical(_appInitialization, attempt)) _appInitialization = null;
      Error.throwWithStackTrace(error, stack);
    });
    _appInitialization = attempt;
    return attempt;
  }

  Future<void> _initialize() async {
    try {
      await _ensureApp();
      _available = true;
    } catch (e) {
      // Readiness reports the failure and may retry; the app remains usable.
      _available = false;
      debugPrint('Firebase unavailable: $e');
      rethrow;
    }

    if (_configureForTest != null) {
      try {
        await _configureForTest();
        _authSub ??= _userChangesForTest?.listen((user) {
          unawaited(_onUser(user));
        });
        final first = _onUser(_user);
        _publishFirstUser();
        await first;
        return;
      } catch (_) {
        _available = false;
        rethrow;
      }
    }
    try {
      await _restoreConsent();

      // Only a build with OVID_APPCHECK=true ever activates App Check.
      if (kOvidAppCheck && accountService.enabled) {
        await FirebaseAppCheck.instance.activate(
          androidProvider: AndroidProvider.playIntegrity,
        );
      }
      _authSub ??= FirebaseAuth.instance.userChanges().listen((user) {
        unawaited(_onUser(user));
      });
      // `_onUser` records the user synchronously, then awaits history
      // hydration; publish the known user before that wait.
      final first = _onUser(_identity.currentUser);
      _publishFirstUser();
      await first;

      // Handlers are installed regardless of consent: Crashlytics discards
      // every event while collection is disabled, so consent still gates the
      // data, but an early crash is not lost once the user opts in.
      _attachCrashHandlers();
      notifyListeners();
    } catch (_) {
      _available = false;
      rethrow;
    }
  }

  Future<void> _onUser(User? user, {AuthIntent? intent}) async {
    _identity.observeUser(user);
    final changed = _user?.uid != user?.uid;
    if (changed) {
      _authRevision++;
      _accountAdmission = null;
      _accountAdmissionUid = null;
    }
    // A successful reauthentication is a new image owner even for the same UID.
    // Keep the auth revision stable: an in-progress phone flow captures it.
    // Ordinary user/token refresh events have no intent and retain image work.
    if (changed ||
        user == null ||
        user.isAnonymous ||
        intent == AuthIntent.reauthenticate) {
      ImageStudio.I.bindAccount(null);
    }
    _user = user;
    if (changed || user == null) _accountSession.clear();
    final revision = _authRevision;
    // This boundary invalidates sessions/runs/search synchronously before any
    // auth listener can expose the replacement account.
    final transition = AppState.I.transitionSessionAccount(
      user == null || user.isAnonymous ? 'guest' : 'firebase:${user.uid}',
    );
    try {
      await transition;
    } catch (e) {
      Diag.swallow('account.sessions', e);
    }
    if (revision != _authRevision ||
        (intent != null && _identity.currentUser?.uid != user?.uid)) {
      return;
    }
    if (accountReady && ImageStudio.I.accountId != user?.uid) {
      ImageStudio.I.bindAccount(user!.uid);
      try {
        await ImageStudio.I.loadReceipts();
      } catch (e) {
        Diag.swallow('account.image_receipts', e);
      }
      if (revision != _authRevision) return;
    }
    notifyListeners();
    if (isSignedIn && accountService.enabled && !_accountSession.ready) {
      unawaited(retryAccountLogin());
    }
  }

  /// Retries account admission. With the server account feature on this
  /// re-runs the login acknowledgement; with it off the only admission step
  /// is the local session namespace transition, so that is retried instead
  /// (otherwise a failed local transition would leave no way forward).
  Future<void> retryAccountLogin() async {
    final u = _user;
    if (u == null || u.isAnonymous) return;
    if (!accountService.enabled) {
      return _admitAccount(u.uid, () async {
        final revision = _authRevision;
        await AppState.I.transitionSessionAccount('firebase:${u.uid}');
        if (revision != _authRevision || _user?.uid != u.uid) return;
        notifyListeners();
      });
    }
    return _admitAccount(u.uid, () => _retryAccountLogin(u));
  }

  /// True when the signed-in account's local session namespace failed to
  /// load, so the account-not-ready screen must offer Retry / Sign out.
  bool get accountTransitionFailed =>
      isSignedIn &&
      AppState.I.lastSessionPersistFailed &&
      !AppState.I.sessionAccountReady;

  /// Minimum gap between background account-state re-checks (app resume).
  static const accountRecheckInterval = Duration(minutes: 15);

  /// Minimum gap between forced re-checks (gateway 401/403), so a burst of
  /// rejected requests cannot become a burst of account calls.
  static const accountForcedRecheckInterval = Duration(minutes: 1);
  DateTime? _lastAccountCheck;
  Future<void>? _accountRecheck;

  /// Re-reads the server deletion state for an admitted account, so a
  /// deletion requested on another device is noticed without a cold start.
  /// Called on app resume (throttled to [accountRecheckInterval]) and with
  /// [force] when the gateway rejects this account (401/403).
  Future<void> recheckAccountState({bool force = false}) {
    final u = _user;
    if (u == null ||
        u.isAnonymous ||
        !accountService.enabled ||
        !_accountSession.ready) {
      return Future<void>.value();
    }
    final inFlight = _accountRecheck;
    if (inFlight != null) return inFlight;
    final now = DateTime.now();
    final last = _lastAccountCheck;
    final interval = force
        ? accountForcedRecheckInterval
        : accountRecheckInterval;
    if (last != null && now.difference(last) < interval) {
      return Future<void>.value();
    }
    _lastAccountCheck = now;
    late final Future<void> check;
    check = _recheckAccountState(u).whenComplete(() {
      if (identical(_accountRecheck, check)) _accountRecheck = null;
    });
    return _accountRecheck = check;
  }

  Future<void> _recheckAccountState(User u) async {
    final revision = _authRevision;
    try {
      final result = await accountService.acknowledgeLogin();
      if (revision != _authRevision || _user?.uid != u.uid) return;
      lastDeletionReceipt = result;
      if (result.allowsLogin) return;
      // Deletion was requested elsewhere: drop admission and re-run it so the
      // account-not-ready screen explains the state and offers Restore.
      _accountSession.clear();
      ImageStudio.I.bindAccount(null);
      notifyListeners();
      unawaited(retryAccountLogin().catchError((Object e) {
        Diag.swallow('account.recheck_admission', e);
      }));
    } catch (e) {
      // A transient failure keeps the current admission; the next resume or
      // gateway rejection checks again.
      Diag.swallow('account.recheck', e);
    }
  }

  Future<void> _retryAccountLogin(User u) async {
    final revision = _authRevision;
    _accountSession.clear();
    ImageStudio.I.bindAccount(null);
    await AppState.I.transitionSessionAccount('firebase:${u.uid}');
    if (revision != _authRevision ||
        _user?.uid != u.uid ||
        !AppState.I.sessionAccountReady) {
      return;
    }
    await _accountSession.bind(u.uid, () async {
      final result = await accountService.acknowledgeLogin();
      if (revision != _authRevision || _user?.uid != u.uid) return;
      lastDeletionReceipt = result;
      if (!result.allowsLogin) {
        throw AccountException(
          result.isPending
              ? 'Account deletion is pending. Choose Restore account to cancel it.'
              : 'This account cannot be admitted while deletion is in progress.',
        );
      }
    });
    if (revision != _authRevision) return;
    if (_accountSession.ready) _lastAccountCheck = DateTime.now();
    if (accountReady) {
      ImageStudio.I.bindAccount(u.uid);
      try {
        await ImageStudio.I.loadReceipts();
      } catch (e) {
        Diag.swallow('account.image_receipts', e);
      }
      if (revision != _authRevision) return;
    }
    notifyListeners();
  }

  Future<void> restoreAccount() async {
    final u = _user;
    if (u == null || u.isAnonymous || !accountService.enabled) return;
    return _admitAccount(u.uid, () async {
      final revision = _authRevision;
      final result = await accountService.cancelDeletion();
      if (revision != _authRevision || _user?.uid != u.uid) return;
      lastDeletionReceipt = result;
      if (result.state != 'cancelled') {
        throw const AccountException(
          'The server did not confirm account restoration.',
        );
      }
      await _retryAccountLogin(u);
    });
  }

  Future<void> _admitAccount(String uid, Future<void> Function() operation) {
    final existing = _accountAdmission;
    if (existing != null && _accountAdmissionUid == uid) return existing;
    late final Future<void> current;
    current = operation();
    _accountAdmission = current;
    _accountAdmissionUid = uid;
    current.then(
      (_) {
        if (identical(_accountAdmission, current)) {
          _accountAdmission = null;
          _accountAdmissionUid = null;
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_accountAdmission, current)) {
          _accountAdmission = null;
          _accountAdmissionUid = null;
        }
      },
    );
    return current;
  }

  Future<String?> authenticateSocial(
    String providerId,
    AuthIntent intent,
  ) async {
    if (!_available) return 'Sign-in is not configured in this build.';
    if (intent == AuthIntent.reauthenticate) _identity.invalidateProof();
    final error = await _identity.social(providerId, intent);
    if (error == null) {
      await _onUser(_identity.currentUser, intent: intent);
    }
    return error;
  }

  PhoneAuthFlow createPhoneFlow(AuthIntent intent) {
    final expectedUid = _identity.currentUser?.uid;
    if (intent == AuthIntent.reauthenticate) _identity.invalidateProof();
    return PhoneAuthFlow(
      currentUid: () => _identity.currentUser?.uid,
      currentSession: () => _authRevision,
      verify: (number, token, callbacks) async {
        if (!_available || !authProviders.isEnabled('phone')) {
          throw FirebaseAuthException(code: 'provider-not-configured');
        }
        if (_identity.currentUser?.uid != expectedUid) {
          throw FirebaseAuthException(code: 'account-changed');
        }
        if (intent == AuthIntent.link) _identity.requireLinkProof();
        if (intent == AuthIntent.reauthenticate && number != phoneNumber) {
          throw FirebaseAuthException(code: 'user-mismatch');
        }
        await _identity.auth().verifyPhoneNumber(
          phoneNumber: number,
          timeout: const Duration(seconds: 60),
          forceResendingToken: token,
          verificationCompleted: callbacks.completed,
          verificationFailed: callbacks.failed,
          codeSent: callbacks.codeSent,
          codeAutoRetrievalTimeout: callbacks.timedOut,
        );
      },
      apply: (credential) async {
        await _identity.phone(credential, intent, expectedUid);
        await _onUser(_identity.currentUser, intent: intent);
      },
    );
  }

  Future<AccountDeletion> requestAccountDeletion(String requestId) async {
    if (uid == null ||
        uid != _identity.currentUser?.uid ||
        !_identity.deletionAuthorized) {
      throw const AccountException(
        'Verify the current account before requesting deletion.',
      );
    }
    _identity.consumeDeletionProof();
    final revision = _authRevision;
    final result = await accountService.requestDeletion(requestId);
    if (revision != _authRevision) return result;
    if (result.isPending) {
      lastDeletionReceipt = result;
      // The server copy is scheduled; this device must not keep a readable
      // transcript, draft or key for an account that asked to be erased.
      final erase = eraseDeviceCopyOnDeletion;
      if (erase != null) {
        deletionDeviceEraseFailed = false;
        try {
          await erase();
        } catch (e) {
          // The server request stands. Stay signed in (when the failed store
          // was not the sign-out itself) so Data control can retry the erase;
          // never report a half-erased device as complete.
          deletionDeviceEraseFailed = true;
          Diag.swallow('account.erase_device_copy', e);
          return result;
        }
      }
      // The retained server request is the success criterion; signing out only
      // prevents this device's old session from continuing to use the account.
      try {
        await signOut();
      } catch (e) {
        // Server acceptance remains true even if local provider sign-out fails.
        Diag.swallow('account.signout_after_request', e);
      }
    }
    return result;
  }

  Future<void> _restoreConsent() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_consentKey);
    _consentAsked = v != null;
    _consentGiven = v == 'yes';
    await _applyTelemetryFlags();
  }

  /// Record the user's telemetry choice and apply it.
  Future<void> setConsent(bool allow) async {
    _consentGiven = allow;
    _consentAsked = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_consentKey, allow ? 'yes' : 'no');
    await _applyTelemetryFlags();
    if (allow) _attachCrashHandlers();
    notifyListeners();
  }

  Future<void> _applyTelemetryFlags() async {
    if (!_available) return;
    try {
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(
        _consentGiven,
      );
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
        _consentGiven,
      );
    } catch (e) {
      Diag.swallow('firebase_service', e);
    }
  }

  /// Installs the Crashlytics handlers.
  ///
  /// This is not the consent gate; collection is (see
  /// [initializeCrashReporting]). Installing them before `runApp` is what makes
  /// a crash before the first frame visible. The previous handler is kept so
  /// debug builds still print the error.
  bool _crashHandlersAttached = false;
  void _attachCrashHandlers() {
    if (_crashHandlersAttached || !_available) return;
    _crashHandlersAttached = true;
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      previousOnError?.call(details);
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  }

  /// Reports an uncaught asynchronous error from the guarded boot zone.
  ///
  /// Before Firebase is up there is nowhere to send it, so it is printed
  /// instead of swallowed.
  void recordZoneError(Object error, StackTrace stack) {
    if (!_available) {
      debugPrint('Uncaught boot error: $error\n$stack');
      return;
    }
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
  }

  /// The current user's Firebase ID token (JWT), or null when signed out.
  /// Used to authenticate to the Ovid Cloud mint endpoint, which verifies it
  /// against Google's public keys. [forceRefresh] re-mints a near-expiry token.
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final revision = _authRevision;
    final u = _user ?? FirebaseAuth.instance.currentUser;
    if (u == null) return null;
    try {
      final token = await u.getIdToken(forceRefresh);
      return revision == _authRevision && _user?.uid == u.uid ? token : null;
    } catch (e) {
      debugPrint('getIdToken failed: $e');
      return null;
    }
  }

  /// The current FCM registration token, or null when Firebase is not
  /// configured (debug/local without google-services.json) or the platform
  /// has no messaging support. Cloud push is best-effort: a missing token
  /// just means the gateway cannot wake this device.
  Future<String?> getFcmToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('getFcmToken failed: $e');
      return null;
    }
  }

  /// Update the signed-in user's display name (FAANG-style editable profile).
  /// Returns null on success, else an error message.
  Future<String?> updateDisplayName(String name) async {
    final u = _user ?? FirebaseAuth.instance.currentUser;
    if (u == null) return 'Not signed in.';
    try {
      await u.updateDisplayName(name.trim());
      await u.reload();
      _user = FirebaseAuth.instance.currentUser;
      notifyListeners();
      return null;
    } catch (e) {
      return 'Could not update your name. Check your connection and try again.';
    }
  }

  /// Sends the signed-in user a fresh email-verification link, then re-reads
  /// the account so [emailVerified] reflects Firebase.
  ///
  /// Returns null when Firebase accepted the request, else the Firebase error
  /// code (`too-many-requests`, `network-request-failed`, …). Never throws.
  Future<String?> resendEmailVerification() async {
    final u = _user ?? (_available ? FirebaseAuth.instance.currentUser : null);
    if (u == null) return 'no-user';
    if ((u.email ?? '').trim().isEmpty) return 'no-email';
    try {
      await u.sendEmailVerification();
      await u.reload();
      // Do not resurrect a user who signed out while the call was in flight.
      final current = _available ? FirebaseAuth.instance.currentUser : null;
      if (current?.uid == u.uid) {
        _user = current;
        notifyListeners();
      }
      return null;
    } on FirebaseAuthException catch (e) {
      return e.code;
    } catch (e) {
      debugPrint('sendEmailVerification failed: $e');
      return 'unknown';
    }
  }

  /// Google sign-in (B7): native Google account picker → Firebase credential.
  /// Returns null on success, else an error message; 'cancelled' means the
  /// user closed the picker (not an error to surface loudly).
  Future<String?> signInWithGoogle() async {
    return authenticateSocial('google.com', AuthIntent.signIn);
  }

  /// Work that must run while the outgoing account's ID token is still valid
  /// (DELETE /devices for its FCM token). Registered once by main.dart.
  final List<Future<void> Function()> _beforeSignOut = [];

  /// Registers [hook] to run before every sign-out / reset sign-out.
  void addBeforeSignOut(Future<void> Function() hook) {
    if (!_beforeSignOut.contains(hook)) _beforeSignOut.add(hook);
  }

  /// Runs the before-sign-out hooks, bounded so a hung network never blocks
  /// the sign-out itself. Never throws.
  Future<void> runBeforeSignOut({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    for (final hook in List.of(_beforeSignOut)) {
      try {
        await hook().timeout(timeout);
      } catch (e) {
        Diag.swallow('firebase.before_signout', e);
      }
    }
  }

  /// How long [signOut] waits for an in-flight credential submission to
  /// settle before signing out anyway (SH-018).
  @visibleForTesting
  static Duration authSettleTimeout = const Duration(seconds: 10);

  /// Signs out of Firebase and Google. Never silently does nothing: an auth
  /// operation in flight is cancelled and given [authSettleTimeout] to
  /// settle, then the sign-out proceeds (SH-018).
  Future<void> signOut() async {
    _identity.cancelPending();
    if (_identity.busy) {
      final deadline = DateTime.now().add(authSettleTimeout);
      while (_identity.busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    // Unregister this device's push token for the outgoing account while
    // its ID token still works (SE-002 / SH-003).
    await runBeforeSignOut();
    _identity.cancelPending();
    _authRevision++;
    _accountAdmission = null;
    _accountAdmissionUid = null;
    ImageStudio.I.bindAccount(null);
    // The managed Ovid Cloud key belongs to this account; never leave it for
    // the next one to use (and bill).
    OvidCloudService.I.clearAccountKey();
    if (!_available) return;
    _accountSession.clear();
    _user = null;
    final transition = AppState.I.transitionSessionAccount('guest');
    notifyListeners();
    await transition;
    await FirebaseAuth.instance.signOut();
    try {
      await GoogleSignIn().signOut();
    } catch (e) {
      Diag.swallow('firebase.google_signout', e);
    }
  }

  /// Barrier-safe local sign-out for the all-store reset.
  ///
  /// Clears the local account state (identity, user, account session, image
  /// ownership) and notifies listeners, but never awaits
  /// [AppState.transitionSessionAccount]. The public [signOut] cannot run inside
  /// the settings barrier: its guest transition captures the in-progress
  /// `_settingsOperation` and awaits the very barrier that is calling it, which
  /// deadlocks. The reset owner invokes this instead and wipes the AppState
  /// session namespace directly.
  Future<void> signOutLocal() async {
    _identity.cancelPending();
    _identity.observeUser(null);
    _authRevision++;
    _accountAdmission = null;
    _accountAdmissionUid = null;
    ImageStudio.I.bindAccount(null);
    OvidCloudService.I.clearAccountKey();
    _accountSession.clear();
    _user = null;
    notifyListeners();
  }

  /// Signs the Firebase and Google SDKs out after a reset (SE-001).
  ///
  /// [signOutLocal] only clears in-memory state; without this the SDK keeps
  /// its persisted credential and the next launch is signed in again with
  /// every cloud chat back. Safe inside the reset barrier: the SDK's
  /// `userChanges` listener runs `_onUser` unawaited, so its guest
  /// transition queues behind the barrier instead of deadlocking it.
  Future<void> signOutSdk() async {
    if (!_available) return;
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      Diag.swallow('firebase.sdk_signout', e);
    }
    try {
      await GoogleSignIn().signOut();
    } catch (e) {
      Diag.swallow('firebase.google_signout', e);
    }
  }

  /// True when the Firebase SDK holds no persisted user (readback for the
  /// reset's account store). Trivially true when Firebase is unavailable.
  bool get sdkSignedOut {
    if (!_available) return true;
    try {
      return FirebaseAuth.instance.currentUser == null;
    } catch (_) {
      return true;
    }
  }

  /// Lightweight analytics event — only fires when consent is given.
  Future<void> logEvent(String name, [Map<String, Object>? params]) async {
    if (!_available || !_consentGiven) return;
    try {
      await FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
    } catch (e) {
      Diag.swallow('firebase_service', e);
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
