import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

/// Enabling an MCP server must ASK for required credentials instead of
/// silently flipping to a needsSetup label: no missing creds → connect
/// directly; missing creds → credential sheet; GitHub-native servers offer
/// the GitHub login as the first-class path.
void main() {
  McpServer server({String name = 'Custom', String? envHint}) => McpServer(
    name: name,
    author: 'test',
    description: 'test server',
    category: 'Custom',
    command: 'npx',
    envHint: envHint,
  );

  test('no missing credentials connects directly', () {
    expect(
      mcpCredentialAskForTest(missing: const []),
      McpCredentialAsk.connectDirectly,
    );
  });

  test('missing credentials ask first', () {
    expect(
      mcpCredentialAskForTest(missing: const ['GITHUB_TOKEN']),
      McpCredentialAsk.askCredentials,
    );
    expect(
      mcpCredentialAskForTest(missing: const ['DATABASE_URL', 'DB_KEY']),
      McpCredentialAsk.askCredentials,
    );
  });

  test('GitHub-native servers offer the GitHub login path', () {
    expect(
      mcpOffersGithubLoginForTest(server(name: 'GitHub')),
      isTrue,
    );
    expect(
      mcpOffersGithubLoginForTest(
        server(name: 'My Proxy', envHint: 'GITHUB_TOKEN'),
      ),
      isTrue,
    );
  });

  test('non-GitHub servers do not offer the GitHub login path', () {
    expect(
      mcpOffersGithubLoginForTest(
        server(name: 'Postgres', envHint: 'DATABASE_URL'),
      ),
      isFalse,
    );
    expect(mcpOffersGithubLoginForTest(server(name: 'Fetch')), isFalse);
  });
}
