import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'repo_cache.dart';
import 'sandbox_service.dart';
import 'secure_store.dart';

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

/// GitHub Device Flow authentication — real implementation (RFC 8628).
///
/// Flow:
///   1. POST https://github.com/login/device/code  → user_code + verification_uri
///   2. User opens github.com/login/device and enters the code
///   3. Poll POST /login/oauth/access_token until authorized
///   4. Use token for API calls + git push/pull from Studio
///
/// No refresh token exists in this flow: GitHub's OAuth App device flow
/// returns only `access_token` in the token response (no `refresh_token` /
/// `expires_in` — those belong to GitHub Apps with expiring user tokens,
/// not this OAuth App), and the token does not expire unless the user
/// revokes it. So there is nothing to persist and no
/// `grant_type=refresh_token` exchange to attempt on 401 — the
/// confirm-before-wipe + background-retry path below is the whole story.
/// The outcome of a stored-token read: the value, plus whether exhausting the
/// retries meant the storage THREW (unknown) or the key was genuinely absent
/// (signed out). Those two facts need different handling and used to be
/// collapsed into `null`.
class TokenReadResult {
  const TokenReadResult(this.token, {required this.failed});
  final String? token;
  final bool failed;
}

class GitHubService extends ChangeNotifier {
  GitHubService._();
  static final GitHubService I = GitHubService._();

  // OAuth App "Ovid" — owned by aasheesh333
  static const clientId = 'Ov23lixZxZhJznvr1fcd';
  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const _apiBase = 'https://api.github.com';
  static const _tokenStorageKey = 'ovid_github_token';
  static final _secureStorage = ovidSecureStorage();
  static const _requestTimeout = Duration(seconds: 20);

  String? _token;
  Map<String, dynamic>? _user;
  int _authGeneration = 0;
  Future<void> _tokenWrite = Future<void>.value();
  bool _isInitializing = true;
  Timer? _profileRetryTimer;

  /// Delay before retrying a profile fetch that failed transiently. Exposed so
  /// tests can drive the background retry without waiting.
  @visibleForTesting
  Duration profileRetryDelay = const Duration(seconds: 30);

  bool get isLoggedIn => _token != null;
  bool get isInitializing => _isInitializing;
  String? get login => _user?['login'] as String?;
  String? get avatarUrl => _user?['avatar_url'] as String?;
  String? get name => _user?['name'] as String?;
  String? get token => _token;

  /// Single write point for the auth token: keeps the sandbox's git
  /// credential channel in lockstep. The token reaches spawned git only
  /// through `SandboxService._sandboxEnv`, and is never persisted there.
  void _setToken(String? value) {
    _token = value;
    SandboxService.I.gitCredentialToken = value;
  }

  /// Sign out — clear token + profile, disconnect repo cache.
  Future<void> signOut() async {
    _authGeneration++;
    _isInitializing = false;
    _cancelProfileRetry();
    _setToken(null);
    _user = null;
    RepoCache.I.unbind();
    notifyListeners();
    await _persistToken(null);
  }

  @override
  void dispose() {
    _cancelProfileRetry();
    super.dispose();
  }

  void _cancelProfileRetry() {
    _profileRetryTimer?.cancel();
    _profileRetryTimer = null;
  }

  /// Reads the stored auth token, retrying up to 3 times with a short
  /// backoff. Cold starts right after the process was killed can hit
  /// Keystore / EncryptedSharedPreferences hiccups that surface as
  /// transient read failures — without the retry the app concludes "no
  /// login" and the user lands signed out on every process death. After
  /// the attempts are exhausted the read is treated as absent, exactly as
  /// a clean miss would be.
  /// One read attempt's outcome. Returned per-call rather than through the
  /// shared [lastReadFailedForTest] static, because concurrent callers used to
  /// clobber each other's signal: a successful read from `initialize()` reset the
  /// flag while a resume-triggered retry was mid-flight, so the retry concluded
  /// "no token stored" instead of "the read failed", skipped its own retry, and
  /// Studio sat signed out for the whole launch.
  static Future<TokenReadResult> readTokenResult(
    Future<String?> Function() read,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
      }
      try {
        return TokenReadResult(await read(), failed: false);
      } catch (_) {
        // Transient secure-storage failure — back off and try again.
      }
    }
    return const TokenReadResult(null, failed: true);
  }

  @visibleForTesting
  static Future<String?> readTokenWithRetriesForTest(
    Future<String?> Function() read,
  ) async {
    final r = await readTokenResult(read);
    lastReadFailedForTest = r.failed;
    return r.token;
  }

  /// True when the most recent [readTokenWithRetriesForTest] exhausted its
  /// attempts by THROWING rather than by reading an empty key. Mirrored onto the
  /// instance as [restoreFailed].
  @visibleForTesting
  static bool lastReadFailedForTest = false;

  /// The login state is UNKNOWN because secure storage could not be read, not
  /// because the user is signed out. The UI must not latch a "please sign in"
  /// prompt on this, and [retryRestoreIfNotLoggedIn] keeps trying.
  bool restoreFailed = false;

  /// Test seam: true while a background profile retry is armed.
  @visibleForTesting
  bool get hasProfileRetryScheduledForTest => _profileRetryTimer != null;

  Timer? _restoreRetryTimer;
  int _restoreRetryIndex = 0;

  /// Backoff for re-reading secure storage after a FAILED read. A read that
  /// fails during cold-start contention usually succeeds seconds later; without
  /// a retry the app reported "signed out" for the whole launch while the token
  /// sat intact on disk — which is exactly the intermittent "Studio logs me out
  /// after reopening Ovid" report.
  static const _restoreRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 2),
  ];

  void _scheduleRestoreRetry(int generation) {
    _restoreRetryTimer?.cancel();
    if (_restoreRetryIndex >= _restoreRetryDelays.length) return;
    final delay = _restoreRetryDelays[_restoreRetryIndex++];
    _restoreRetryTimer = Timer(delay, () {
      if (generation != _authGeneration || isLoggedIn) return;
      unawaited(retryRestoreIfNotLoggedIn());
    });
  }

  /// Re-read the stored token after a restore FAILURE (not after finding no
  /// token). Invoked by the backoff timer and on app resume.
  ///
  /// A successful retry restores the login without any user action. A failed one
  /// keeps [restoreFailed] true and re-arms the backoff, so the UI can decline
  /// to latch a "please sign in" prompt on a state that may still resolve.
  /// A UI-initiated restore (opening Studio, returning to the app).
  ///
  /// Restarts the automatic backoff first: the 5s/30s/2min window is only ~2.5
  /// minutes long, and once it is exhausted nothing re-arms it. A secure-storage
  /// hiccup lasting longer than that — cold-start contention, an OS update — left
  /// Studio signed out for the rest of the process with no way to recover short
  /// of a full app kill. An explicit retry should always get a fresh window.
  Future<void> retryRestoreFromUi() async {
    _restoreRetryIndex = 0;
    await retryRestoreIfNotLoggedIn();
  }

  Future<void> retryRestoreIfNotLoggedIn() async {
    if (isLoggedIn) {
      restoreFailed = false;
      return;
    }
    final generation = _authGeneration;
    final read = await readTokenResult(
      () => _secureStorage.read(key: _tokenStorageKey),
    );
    if (generation != _authGeneration) return;
    final token = read.token;
    if (token == null || token.isEmpty) {
      restoreFailed = read.failed;
      if (restoreFailed) _scheduleRestoreRetry(generation);
      return;
    }
    restoreFailed = false;
    _restoreRetryIndex = 0;
    _setToken(token);
    notifyListeners();
    // The profile is cosmetic; loading it must never put the restored token at
    // risk, so failures are swallowed rather than treated as a suspect token.
    try {
      final user = await _fetchUser(token, http.Client());
      if (generation == _authGeneration) {
        _user = user;
        notifyListeners();
      }
    } catch (_) {
      if (generation == _authGeneration) _scheduleProfileRetry(generation, null);
    }
  }

  Future<void> initialize({http.Client? client}) async {
    final generation = ++_authGeneration;
    _cancelProfileRetry();
    _isInitializing = true;
    notifyListeners();
    final c = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final read = await readTokenResult(
        () => _secureStorage.read(key: _tokenStorageKey),
      );
      if (generation != _authGeneration) return;
      final token = read.token;
      if (token == null || token.isEmpty) {
        // "No token stored" and "storage could not be read" are DIFFERENT
        // facts. Only the second is retryable, and it must never be presented
        // to the user as a sign-out. Read per-call, not from the shared static:
        // a concurrent retry used to reset that flag mid-flight and this caller
        // would then conclude "signed out" and skip its own retry.
        restoreFailed = read.failed;
        if (restoreFailed) {
          _isInitializing = false;
          notifyListeners();
          _scheduleRestoreRetry(generation);
        }
        return;
      }
      restoreFailed = false;
      _restoreRetryIndex = 0;
      // The stored token is trusted immediately so `isLoggedIn` is true across
      // restarts; the profile is loaded (and retried) separately.
      _setToken(token);
      notifyListeners();
      final user = await _fetchUser(token, c);
      if (generation != _authGeneration) return;
      _user = user;
      notifyListeners();
    } on GitHubAuthException catch (error) {
      if (generation != _authGeneration) return;
      if (error.code == 'invalid_token') {
        // A 401 alone is NEVER proof the token died — a proxy, WAF or edge
        // error page can 401 a request the token would have passed. Confirm
        // GitHub's own `Bad credentials` JSON before even thinking about
        // deleting the stored token. (`token` is not safely readable here —
        // the throw may predate its assignment — but `_token` is only set
        // when a real stored token existed, so it is the right suspect.)
        final suspect = _token;
        if (suspect != null && suspect.isNotEmpty) {
          await _handleSuspectToken(
            generation,
            suspect,
            confirmationClient: c,
            retryClient: client,
          );
        }
      } else {
        _scheduleProfileRetry(generation, client);
      }
    } catch (_) {
      // Transient network/decoding failures keep the token; retry in the
      // background rather than signing the user out.
      if (generation == _authGeneration) {
        _scheduleProfileRetry(generation, client);
      }
    } finally {
      if (ownsClient) c.close();
      if (generation == _authGeneration) {
        _isInitializing = false;
        notifyListeners();
      }
    }
  }

  /// Retries a transient profile failure without ever clearing the stored
  /// token. Only a CONFIRMED bad-credentials 401 (see [_handleSuspectToken])
  /// signs the user out -- a lone 401 just re-arms this retry.
  void _scheduleProfileRetry(int generation, http.Client? client) {
    final token = _token;
    if (token == null) return;
    _cancelProfileRetry();
    _profileRetryTimer = Timer(profileRetryDelay, () async {
      _profileRetryTimer = null;
      if (generation != _authGeneration || _token != token) return;
      final c = client ?? http.Client();
      final ownsClient = client == null;
      try {
        final user = await _fetchUser(token, c);
        if (generation != _authGeneration || _token != token) return;
        _user = user;
        notifyListeners();
      } on GitHubAuthException catch (error) {
        if (generation == _authGeneration && error.code == 'invalid_token') {
          // Even the retry's 401 can be an edge/proxy artifact -- confirm
          // before deleting; inconclusive keeps the token and re-arms.
          // The confirmation uses this attempt's client `c`; the re-armed
          // retry uses the ORIGINAL `client` (possibly null) so it never
          // reuses `c` after this block's finally closes it.
          await _handleSuspectToken(
            generation,
            token,
            confirmationClient: c,
            retryClient: client,
          );
        }
      } catch (_) {
        // Still authenticated-but-unknown; keep the token.
      } finally {
        if (ownsClient) c.close();
      }
    });
  }

  /// Handles a profile fetch that came back 401: the token is deleted only
  /// when a second, dedicated fetch confirms GitHub's own JSON
  /// `Bad credentials` response. Anything inconclusive (proxy/WAF 401s,
  /// HTML error pages, timeouts, offline) KEEPS the token and falls back
  /// to the background retry instead of signing the user out.
  ///
  /// [confirmationClient] performs the second-chance check; [retryClient]
  /// is the client the re-armed retry should use (null = create+own one).
  /// They are separate because callers often own+close the confirmation
  /// client in a `finally` -- handing it to the retry would make the retry
  /// reuse a closed client.
  Future<void> _handleSuspectToken(
    int generation,
    String token, {
    required http.Client confirmationClient,
    required http.Client? retryClient,
  }) async {
    if (generation != _authGeneration) return;
    final confirmed = await _confirmTokenInvalid(token, confirmationClient);
    if (generation != _authGeneration) return;
    if (confirmed) {
      _setToken(null);
      _user = null;
      notifyListeners();
      await _persistToken(null);
    } else {
      // Not confirmed dead -- keep the token; the profile retry re-checks
      // in the background without touching the stored secret.
      _scheduleProfileRetry(generation, retryClient);
    }
  }

  /// Second-chance check that the stored token is REALLY dead: issues one
  /// more `GET /user` and returns true only when the response is 401 with
  /// GitHub's JSON `{"message": "Bad credentials", ...}` body. Returns
  /// false (inconclusive -- keep the token) for any other status, any
  /// non-JSON or differently-worded body, and any transport failure.
  Future<bool> _confirmTokenInvalid(String token, http.Client client) async {
    try {
      final res = await client
          .get(
            Uri.parse('$_apiBase/user'),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 401) return false;
      try {
        final body = jsonDecode(res.body);
        if (body is Map<String, dynamic>) {
          final message = (body['message'] as String?) ?? '';
          return message.toLowerCase().contains('bad credentials');
        }
      } catch (_) {
        return false;
      }
      return false;
    } catch (_) {
      // The confirmation fetch itself failed -- inconclusive, keep token.
      return false;
    }
  }

  /// Persist (or clear) the token. Writes are serialized on [_tokenWrite] so
  /// the last queued operation always wins.
  ///
  /// LOGIN-LOSS FIX (2026-09-24): this used to re-check [generation] *inside*
  /// the queued closure — skipping the write, and then DELETING the token it had
  /// just written, whenever a concurrent `initialize()` had bumped the
  /// generation while the write sat in the queue. A successful device-flow
  /// sign-in therefore survived only for that process lifetime: logged in now,
  /// logged out after the next restart, with nothing on screen to explain it.
  ///
  /// A newly issued token is the newest fact about the account, so it is always
  /// written. Staleness is already gated at the call site by `ensureCurrent()`
  /// before this is reached, and a queued `signOut()` clear always runs AFTER
  /// the write it supersedes, so ordering — not a generation re-check — is what
  /// keeps a sign-out from being undone.
  Future<void> _persistToken(String? token, {int? generation}) {
    final write = _tokenWrite.then((_) async {
      if (token == null || token.isEmpty) {
        await _secureStorage.delete(key: _tokenStorageKey);
      } else {
        await _secureStorage.write(key: _tokenStorageKey, value: token);
      }
    });
    _tokenWrite = write.then<void>((_) {}, onError: (_) {});
    return write;
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
  /// STEP 2 — poll for the access token until user authorizes.
  /// Handles slow_down + expired_token per spec.
  /// -------------------------------------------------------------------------
  Future<String> pollForToken({
    required String deviceCode,
    int intervalSec = 5,
    Duration maxWait = const Duration(minutes: 14),
    http.Client? client,
    void Function(int attempt)? onAttempt,
    bool Function()? isCancelled,
  }) async {
    final c = client ?? http.Client();
    final ownsClient = client == null;
    final deadline = DateTime.now().add(maxWait);
    var interval = Duration(seconds: intervalSec.clamp(1, 60));
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
        if (remaining <= Duration.zero || interval > remaining) break;
        await Future<void>.delayed(interval);
        ensureCurrent();
        if (!DateTime.now().isBefore(deadline)) break;
        attempt++;
        onAttempt?.call(attempt);

        final res = await c
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

        if (res.statusCode != 200) {
          throw GitHubAuthException(
            'token_request_failed',
            'GitHub sign-in failed (${res.statusCode}).',
          );
        }
        final j = jsonDecode(res.body) as Map<String, dynamic>;

        final accessToken = j['access_token'];
        if (accessToken is String && accessToken.isNotEmpty) {
          final user = await _fetchUser(accessToken, c);
          ensureCurrent();
          await _persistToken(accessToken, generation: generation);
          ensureCurrent();
          _setToken(accessToken);
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
        'The stored GitHub authorization is no longer valid.',
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

  String _requireToken() {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const GitHubAuthException(
        'not_authenticated',
        'Connect GitHub before accessing repositories.',
      );
    }
    return token;
  }

  /// List repos accessible to the user (owns first).
  Future<List<Map<String, dynamic>>> listRepos({
    int limit = 30,
    http.Client? client,
  }) async {
    final token = _requireToken();
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            Uri.parse('$_apiBase/user/repos?per_page=$limit&sort=updated'),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(_requestTimeout);
      if (res.statusCode != 200) {
        throw Exception('repos fetch failed: ${res.statusCode}');
      }
      return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    } finally {
      if (client == null) c.close();
    }
  }

  /// Percent-encodes each path segment for GitHub API URLs (repo names and
  /// file paths with spaces or special chars broke requests when interpolated
  /// raw). Slashes are preserved as separators.
  static String _encodeApiPath(String p) =>
      p.split('/').map(Uri.encodeComponent).join('/');

  /// List branch names of a repo (Studio branch picker).
  ///
  /// Capped at GitHub's maximum 100 branches per page; pagination is not
  /// followed, so repos with more branches expose only the first page.
  Future<List<String>> listBranches(
    String owner,
    String repo, {
    http.Client? client,
  }) async {
    final token = _requireToken();
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            Uri.parse(
              '$_apiBase/repos/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(repo)}/branches?per_page=100',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(_requestTimeout);
      if (res.statusCode != 200) {
        throw Exception('branches fetch failed: ${res.statusCode}');
      }
      return (jsonDecode(res.body) as List)
          .map((e) => (e as Map<String, dynamic>)['name'] as String?)
          .whereType<String>()
          .where((name) => name.isNotEmpty)
          .toList();
    } finally {
      if (client == null) c.close();
    }
  }

  /// List files of a repo at a branch/path (Studio file tree).
  /// Single file -> returns [{name, content, sha, type:'file'}]
  /// Directory  -> returns [{name, path, type:'dir'|'file'}, ...]
  Future<List<Map<String, dynamic>>> listRepoContent({
    required String owner,
    required String repo,
    String path = '',
    String? branch,
    http.Client? client,
  }) async {
    final token = _requireToken();
    final uri = Uri.parse(
      '$_apiBase/repos/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(repo)}/contents/${_encodeApiPath(path)}'
      '${branch == null || branch.isEmpty ? '' : '?ref=${Uri.encodeQueryComponent(branch)}'}',
    );
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(_requestTimeout);
      if (res.statusCode != 200) {
        throw Exception('content fetch failed: ${res.statusCode}');
      }
      final body = jsonDecode(res.body);
      if (body is List) return body.cast<Map<String, dynamic>>();
      return [body as Map<String, dynamic>]; // single file object
    } finally {
      if (client == null) c.close();
    }
  }

  /// Create or update a file (commit) in the repo.
  Future<bool> writeFile({
    required String repoFull, // "owner/repo"
    required String path,
    required String content,
    required String message,
    String? sha, // null means create, else update
    String branch = 'main',
    http.Client? client,
  }) async {
    final token = _requireToken();
    final parts = repoFull.split('/');
    if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
      throw ArgumentError.value(repoFull, 'repoFull', 'Expected owner/repo');
    }
    final uri = Uri.parse(
      '$_apiBase/repos/${Uri.encodeComponent(parts[0])}/${Uri.encodeComponent(parts[1])}/contents/${_encodeApiPath(path)}',
    );
    final c = client ?? http.Client();
    try {
      final res = await c
          .put(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github+json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'message': message,
              'content': base64Encode(utf8.encode(content)),
              'branch': branch,
              'sha': ?sha,
            }),
          )
          .timeout(_requestTimeout);
      return res.statusCode == 200 || res.statusCode == 201;
    } finally {
      if (client == null) c.close();
    }
  }
}
