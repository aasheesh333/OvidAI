import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// GitHub Device Flow authentication — real implementation (RFC 8628).
///
/// Flow:
///   1. POST https://github.com/login/device/code  → user_code + verification_uri
///   2. User opens github.com/login/device and enters the code
///   3. Poll POST /login/oauth/access_token until authorized
///   4. Use token for API calls + git push/pull from Studio
class GitHubService {
  GitHubService._();
  static final GitHubService I = GitHubService._();

  // OAuth App "Ovid" — owned by aasheesh333
  static const clientId = 'Ov23lixZxZhJznvr1fcd';
  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const _apiBase = 'https://api.github.com';

  String? _token;
  Map<String, dynamic>? _user;

  bool get isLoggedIn => _token != null;
  String? get login => _user?['login'] as String?;
  String? get avatarUrl => _user?['avatar_url'] as String?;
  String? get name => _user?['name'] as String?;
  String? get token => _token;

  /// -------------------------------------------------------------------------
  /// STEP 1 — request device code.
  /// Returns (userCode, verificationUri, expiresInSec, intervalSec).
  /// -------------------------------------------------------------------------
  Future<(String, String, int, int)> startDeviceFlow({http.Client? client}) async {
    final res = await (client ?? http.Client()).post(
      Uri.parse(_deviceCodeUrl),
      headers: {'Accept': 'application/json'},
      body: {
        'client_id': clientId,
        'scope': 'repo read:user',
      },
    );
    if (res.statusCode != 200) {
      throw Exception('device flow failed: ${res.statusCode} ${res.body}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      j['user_code'] as String,
      j['verification_uri'] as String,
      (j['expires_in'] as num).toInt(),
      (j['interval'] as num? ?? 5).toInt(),
    );
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
  }) async {
    final c = client ?? http.Client();
    final deadline = DateTime.now().add(maxWait);
    var interval = Duration(seconds: intervalSec);
    var attempt = 0;

    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      onAttempt?.call(attempt);
      await Future<void>.delayed(interval);

      final res = await c.post(
        Uri.parse(_tokenUrl),
        headers: {'Accept': 'application/json'},
        body: {
          'client_id': clientId,
          'device_code': deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );

      if (res.statusCode != 200) continue;
      final j = jsonDecode(res.body) as Map<String, dynamic>;

      if (j['access_token'] != null) {
        _token = j['access_token'] as String;
        await fetchUser();
        return _token!;
      }

      switch (j['error'] as String?) {
        case 'authorization_pending':
          break; // keep polling at same interval
        case 'slow_down':
          interval += const Duration(seconds: 5); // per RFC 8628
          break;
        case 'expired_token':
          throw Exception('Device code expired — try again');
        default:
          throw Exception('OAuth error: ${j['error']}');
      }
    }
    throw Exception('Timed out waiting for authorization');
  }

  /// -------------------------------------------------------------------------
  /// STEP 3 — authenticated user profile.
  /// -------------------------------------------------------------------------
  Future<void> fetchUser() async {
    if (_token == null) return;
    final res = await http.get(
      Uri.parse('$_apiBase/user'),
      headers: {
        'Authorization': 'Bearer $_token',
        'Accept': 'application/vnd.github+json',
      },
    );
    if (res.statusCode == 200) {
      _user = jsonDecode(res.body) as Map<String, dynamic>;
    }
  }

  /// List repos accessible to the user (owns first).
  Future<List<Map<String, dynamic>>> listRepos({int limit = 30}) async {
    final res = await http.get(
      Uri.parse('$_apiBase/user/repos?per_page=$limit&sort=updated'),
      headers: {
        'Authorization': 'Bearer $_token',
        'Accept': 'application/vnd.github+json',
      },
    );
    if (res.statusCode != 200) {
      throw Exception('repos fetch failed: ${res.statusCode}');
    }
    return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
  }

  /// List files of a repo at a branch/path (Studio file tree).
  /// Single file -> returns [{name, content, sha, type:'file'}]
  /// Directory  -> returns [{name, path, type:'dir'|'file'}, ...]
  Future<List<Map<String, dynamic>>> listRepoContent(
      {required String owner,
      required String repo,
      String path = ''}) async {
    final uri = Uri.parse('$_apiBase/repos/$owner/$repo/contents/$path');
    final res = await http.get(uri, headers: {
      'Authorization': 'Bearer $_token',
      'Accept': 'application/vnd.github+json',
    });
    if (res.statusCode != 200) {
      throw Exception('content fetch failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body);
    if (body is List) return body.cast<Map<String, dynamic>>();
    return [body as Map<String, dynamic>]; // single file object
  }

  /// Create or update a file (commit) in the repo.
  Future<bool> writeFile({
    required String repoFull, // "owner/repo"
    required String path,
    required String content,
    required String message,
    String? sha, // null means create, else update
    String branch = 'main',
  }) async {
    final parts = repoFull.split('/');
    final uri =
        Uri.parse('$_apiBase/repos/${parts[0]}/${parts[1]}/contents/$path');
    final res = await http.put(uri, headers: {
      'Authorization': 'Bearer $_token',
      'Accept': 'application/vnd.github+json',
      'Content-Type': 'application/json',
    }, body: jsonEncode({
      'message': message,
      'content': base64Encode(utf8.encode(content)),
      'branch': branch,
      if (sha != null) 'sha': sha,
    }));
    return res.statusCode == 200 || res.statusCode == 201;
  }

  void signOut() {
    _token = null;
    _user = null;
  }
}
