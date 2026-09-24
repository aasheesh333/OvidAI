import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';

/// Regression: GitHub API URLs used to interpolate owner/repo/path raw, so
/// repos or paths with spaces or special chars produced broken requests.
/// Every segment is now percent-encoded (slashes preserved).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await GitHubService.I.signOut();
  });

  tearDown(() async {
    await GitHubService.I.signOut();
  });

  /// Logs in via the mock storage, then runs [fn] with a client that captures
  /// the request URL and returns canned 200s.
  Future<Uri> captureUrl(
    Future<void> Function(http.Client client) fn,
  ) async {
    await storage.write(key: 'ovid_github_token', value: 'tok');
    Uri? seen;
    final client = MockClient((request) async {
      if (request.url.path == '/user') {
        return http.Response(jsonEncode({'login': 'octo'}), 200);
      }
      seen = request.url;
      return http.Response('[]', 200);
    });
    await GitHubService.I.initialize(client: client);
    await fn(client);
    client.close();
    return seen!;
  }

  test('listBranches encodes owner and repo with spaces', () async {
    final url = await captureUrl(
      (c) => GitHubService.I.listBranches('my owner', 'my repo', client: c),
    );
    expect(url.path, '/repos/my%20owner/my%20repo/branches');
    expect(url.queryParameters['per_page'], '100');
  });

  test('listRepoContent encodes path segments but preserves slashes', () async {
    final url = await captureUrl(
      (c) => GitHubService.I.listRepoContent(
        owner: 'owner',
        repo: 'repo',
        path: 'docs/my file.md',
        client: c,
      ),
    );
    expect(url.path, '/repos/owner/repo/contents/docs/my%20file.md');
  });

  test('writeFile encodes repoFull parts and path', () async {
    Uri? seen;
    await storage.write(key: 'ovid_github_token', value: 'tok');
    final client = MockClient((request) async {
      if (request.url.path == '/user') {
        return http.Response(jsonEncode({'login': 'octo'}), 200);
      }
      seen = request.url;
      return http.Response('{}', 201);
    });
    await GitHubService.I.initialize(client: client);
    final ok = await GitHubService.I.writeFile(
      repoFull: 'o wner/r epo',
      path: 'a b/c d.txt',
      content: 'hi',
      message: 'test',
      client: client,
    );
    client.close();
    expect(ok, isTrue);
    expect(seen!.path, '/repos/o%20wner/r%20epo/contents/a%20b/c%20d.txt');
  });
}
