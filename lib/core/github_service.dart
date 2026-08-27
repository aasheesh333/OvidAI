import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'repo_cache.dart';

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
class GitHubService extends ChangeNotifier {
  GitHubService._();
  static final GitHubService I = GitHubService._();

  // OAuth App "Ovid" — owned by aasheesh333
  static const clientId = 'Ov23lixZxZhJznvr1fcd';
  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const _apiBase = 'https://api.github.com';
  static const _tokenStorageKey = 'ovid_github_token';
  static const _secureStorage = FlutterSecureStorage();
  static const _requestTimeout = Duration(seconds: 20);

  String? _token;
  Map<String, dynamic>? _user;
  int _authGeneration = 0;
  Future<void> _tokenWrite = Future<void>.value();
  bool _isInitializing = true;

  bool get isLoggedIn => _token != null;
  bool get isInitializing => _isInitializing;
  String? get login => _user?['login'] as String?;
  String? get avatarUrl => _user?['avatar_url'] as String?;
  String? get name => _user?['name'] as String?;
  String? get token => _token;

  /// Sign out — clear token + profile, disconnect repo cache.
  Future<void> signOut() async {
    _authGeneration++;
    _isInitializing = false;
    _token = null;
    _user = null;
    RepoCache.I.unbind();
    notifyListeners();
    await _persistToken(null);
  }

  Future<void> initialize({http.Client? client}) async {
    final generation = ++_authGeneration;
    _isInitializing = true;
    notifyListeners();
    final c = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final token = await _secureStorage.read(key: _tokenStorageKey);
      if (token == null || token.isEmpty || generation != _authGeneration) {
        return;
      }
      final user = await _fetchUser(token, c);
      if (generation != _authGeneration) return;
      _token = token;
      _user = user;
      notifyListeners();
    } on GitHubAuthException catch (error) {
      if (generation == _authGeneration && error.code == 'invalid_token') {
        _token = null;
        _user = null;
        await _persistToken(null);
      }
    } catch (_) {
      // Keep a stored token through transient network and decoding failures.
    } finally {
      if (ownsClient) c.close();
      if (generation == _authGeneration) {
        _isInitializing = false;
        notifyListeners();
      }
    }
  }

  Future<void> _persistToken(String? token, {int? generation}) {
    final write = _tokenWrite.then((_) async {
      if (generation != null && generation != _authGeneration) return;
      if (token == null || token.isEmpty) {
        await _secureStorage.delete(key: _tokenStorageKey);
      } else {
        await _secureStorage.write(key: _tokenStorageKey, value: token);
        if (generation != null && generation != _authGeneration) {
          await _secureStorage.delete(key: _tokenStorageKey);
        }
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

  /// List files of a repo at a branch/path (Studio file tree).
  /// Single file -> returns [{name, content, sha, type:'file'}]
  /// Directory  -> returns [{name, path, type:'dir'|'file'}, ...]
  Future<List<Map<String, dynamic>>> listRepoContent({
    required String owner,
    required String repo,
    String path = '',
    http.Client? client,
  }) async {
    final token = _requireToken();
    final uri = Uri.parse('$_apiBase/repos/$owner/$repo/contents/$path');
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
      '$_apiBase/repos/${parts[0]}/${parts[1]}/contents/$path',
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
