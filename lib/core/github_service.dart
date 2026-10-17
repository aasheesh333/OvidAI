import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class GitHubDeviceAuthorization {
  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Duration expiresIn;
  final Duration interval;

  const GitHubDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });
}

class GitHubAuthException implements Exception {
  final String code;
  final String message;
  const GitHubAuthException(this.code, this.message);

  @override
  String toString() => message;
}

/// GitHub Device Flow authentication (RFC 8628) — thin client.
///
/// P8 Task 15 reconciliation: the plan pinned a SERVER-PROXIED GitHub OAuth
/// endpoint (spec §11) owned by P7, but the built gateway ships no such route.
/// The device flow therefore still runs directly against GitHub, with one
/// material change: **the access token is memory-only**. It is never written
/// to secure storage, SharedPreferences or any local file. The server-side
/// GitHub integration (MCP `GITHUB_TOKEN` secret, agent git tools) remains the
/// long-term owner; this client is only the interactive sign-in surface.
class GitHubService extends ChangeNotifier {
  GitHubService._();
  static final GitHubService I = GitHubService._();

  // OAuth App "Ovid" — owned by aasheesh333
  static const clientId = 'Ov23lixZxZhJznvr1fcd';
  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const _apiBase = 'https://api.github.com';

  String? _token;
  Map<String, dynamic>? _user;
  int _authGeneration = 0;
  bool _isInitializing = false;

  bool get isLoggedIn => _token != null;
  bool get isInitializing => _isInitializing;

  /// Always false now: there is no stored credential to fail reading. Kept so
  /// the Studio auth badge keeps its "checking" branch (and so a future
  /// server-proxied session can reuse it).
  bool restoreFailed = false;

  String? get login => _user?['login'] as String?;
  String? get avatarUrl => _user?['avatar_url'] as String?;
  String? get name => _user?['name'] as String?;

  /// The in-memory token. NOT persisted; a process restart signs the user out.
  String? get token => _token;

  /// Test seam: seeds the in-memory token without a device flow.
  @visibleForTesting
  void setTokenForTest(String? token) {
    _token = token;
    if (token == null) _user = null;
    notifyListeners();
  }

  /// No-op state reset (boot stage compatibility).
  Future<void> initialize({http.Client? client}) async {
    _isInitializing = false;
    notifyListeners();
  }

  /// No-op: there is no persisted credential to restore. Opening Studio is
  /// still an explicit retry point, so the profile (if any) is refreshed.
  Future<void> retryRestoreFromUi() async {
    if (!isLoggedIn) return;
    _isInitializing = true;
    notifyListeners();
    try {
      await fetchUser();
    } catch (_) {
      // Profile is cosmetic; the in-memory token remains authoritative.
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  /// Sign out — clear the in-memory token + profile.
  Future<void> signOut() async {
    _authGeneration++;
    _isInitializing = false;
    _token = null;
    _user = null;
    notifyListeners();
  }

  /// -------------------------------------------------------------------------
  /// STEP 1 — request device code.
  /// Returns both the human-readable user code and the private polling code.
  /// -------------------------------------------------------------------------
  Future<GitHubDeviceAuthorization> startDeviceFlow({
    http.Client? client,
  }) async {
    _authGeneration++;
    _isInitializing = false;
    final c = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final res = await c
          .post(
            Uri.parse(_deviceCodeUrl),
            headers: {'Accept': 'application/json'},
            body: {'client_id': clientId, 'scope': 'repo read:user'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw GitHubAuthException(
          'device_request_failed',
          'GitHub sign-in could not start (${res.statusCode}).',
        );
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final deviceCode = j['device_code'] as String?;
      final userCode = j['user_code'] as String?;
      final verificationUri = Uri.tryParse(
        j['verification_uri'] as String? ?? '',
      );
      if (deviceCode == null ||
          deviceCode.isEmpty ||
          userCode == null ||
          userCode.isEmpty ||
          verificationUri == null ||
          !verificationUri.hasScheme ||
          !verificationUri.hasAuthority) {
        throw const GitHubAuthException(
          'invalid_device_response',
          'GitHub returned an invalid device sign-in response.',
        );
      }
      final expiresIn = (j['expires_in'] as num? ?? 900).toInt();
      final interval = (j['interval'] as num? ?? 5).toInt();
      if (expiresIn <= 0 || interval <= 0) {
        throw const GitHubAuthException(
          'invalid_device_response',
          'GitHub returned invalid sign-in timing values.',
        );
      }
      return GitHubDeviceAuthorization(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: verificationUri,
        expiresIn: Duration(seconds: expiresIn),
        interval: Duration(seconds: interval),
      );
    } finally {
      if (ownsClient) c.close();
    }
  }

  /// -------------------------------------------------------------------------
  /// STEP 2 — poll for the access token until the user authorizes.
  /// Handles slow_down + expired_token per spec.
  /// -------------------------------------------------------------------------
  Future<String> pollForToken({
    required String deviceCode,
    int intervalSec = 5,
    Duration maxWait = const Duration(minutes: 14),
    http.Client? client,
    void Function(int attempt)? onAttempt,
    bool Function()? isCancelled,
    Future<void> Function(Duration interval)? waitForNextPoll,
  }) async {
    final c = client ?? http.Client();
    final ownsClient = client == null;
    final deadline = DateTime.now().add(maxWait);
    var interval = Duration(seconds: intervalSec.clamp(1, 60));
    // Transport trouble (no network while the app is backgrounded during
    // browser approval, a 5xx, a captive-portal HTML page) must not abandon a
    // still-valid device code: it is treated like `authorization_pending`
    // with a growing backoff on top of the protocol interval, until the
    // code's own expiry.
    var transientBackoff = Duration.zero;
    final wait = waitForNextPoll ?? (d) => Future<void>.delayed(d);
    var attempt = 0;
    final generation = ++_authGeneration;

    void ensureCurrent() {
      if (generation != _authGeneration || (isCancelled?.call() ?? false)) {
        throw const GitHubAuthException(
          'cancelled',
          'GitHub sign-in was cancelled.',
        );
      }
    }

    try {
      while (DateTime.now().isBefore(deadline)) {
        ensureCurrent();
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) break;
        var delay = interval + transientBackoff;
        if (delay > remaining) {
          // A backoff never skips the last chance to poll before expiry.
          if (transientBackoff == Duration.zero) break;
          delay = remaining - const Duration(milliseconds: 1);
          if (delay < interval) break;
        }
        await wait(delay);
        ensureCurrent();
        if (!DateTime.now().isBefore(deadline)) break;
        attempt++;
        onAttempt?.call(attempt);

        final http.Response res;
        final Map<String, dynamic> j;
        try {
          res = await c
              .post(
                Uri.parse(_tokenUrl),
                headers: {'Accept': 'application/json'},
                body: {
                  'client_id': clientId,
                  'device_code': deviceCode,
                  'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
                },
              )
              .timeout(const Duration(seconds: 20));
          ensureCurrent();
          if (res.statusCode >= 500 || res.statusCode == 429) {
            throw http.ClientException('token poll HTTP ${res.statusCode}');
          }
          if (res.statusCode != 200) {
            throw GitHubAuthException(
              'token_request_failed',
              'GitHub sign-in failed (${res.statusCode}).',
            );
          }
          final decoded = jsonDecode(res.body);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('token poll returned non-object');
          }
          j = decoded;
        } on GitHubAuthException {
          rethrow;
        } catch (e) {
          if (!_isTransientPollError(e)) rethrow;
          final next = transientBackoff == Duration.zero
              ? const Duration(seconds: 2)
              : transientBackoff * 2;
          transientBackoff = next > const Duration(seconds: 60)
              ? const Duration(seconds: 60)
              : next;
          continue;
        }
        transientBackoff = Duration.zero;

        final accessToken = j['access_token'];
        if (accessToken is String && accessToken.isNotEmpty) {
          final user = await _fetchUser(accessToken, c);
          ensureCurrent();
          // Memory only — never persisted client-side.
          _token = accessToken;
          _user = user;
          notifyListeners();
          return accessToken;
        }
        if (accessToken != null) {
          throw const GitHubAuthException(
            'oauth_error',
            'GitHub returned an invalid access token.',
          );
        }

        switch (j['error'] as String?) {
          case 'authorization_pending':
            break;
          case 'slow_down':
            interval += const Duration(seconds: 5);
            break;
          case 'expired_token':
            throw const GitHubAuthException(
              'expired_token',
              'The GitHub device code expired. Try again.',
            );
          case 'access_denied':
            throw const GitHubAuthException(
              'access_denied',
              'GitHub sign-in was denied.',
            );
          default:
            throw GitHubAuthException(
              'oauth_error',
              (j['error_description'] ?? 'GitHub sign-in failed.').toString(),
            );
        }
      }
      throw const GitHubAuthException(
        'timeout',
        'Timed out waiting for GitHub authorization.',
      );
    } finally {
      if (ownsClient) c.close();
    }
  }

  static bool _isTransientPollError(Object e) =>
      e is TimeoutException ||
      e is http.ClientException ||
      e is FormatException ||
      e is SocketException ||
      e is HandshakeException;

  /// -------------------------------------------------------------------------
  /// STEP 3 — authenticated user profile.
  /// -------------------------------------------------------------------------
  Future<void> fetchUser() async {
    final token = _token;
    if (token == null) return;
    final client = http.Client();
    try {
      final user = await _fetchUser(token, client);
      if (_token != token) return;
      _user = user;
      notifyListeners();
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _fetchUser(
    String token,
    http.Client client,
  ) async {
    final res = await client
        .get(
          Uri.parse('$_apiBase/user'),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) {
      throw const GitHubAuthException(
        'invalid_token',
        'The GitHub authorization is no longer valid.',
      );
    }
    if (res.statusCode != 200) {
      throw GitHubAuthException(
        'profile_failed',
        'GitHub connected, but the user profile could not be loaded.',
      );
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
