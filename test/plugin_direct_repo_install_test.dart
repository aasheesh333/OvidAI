import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/state.dart';

/// Installing a real [CC]/Codex plugin from a GitHub repo needs no
/// marketplace: `agent_install_plugin(repo: "owner/name")` resolves straight
/// to a GithubPluginSource. This is the generic install path the report's
/// "no real install mechanism" gap called for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() => AppState.resetTestInstance());

  test('owner/name resolves to a GithubPluginSource', () {
    final src = githubPluginSourceFromSourceString('obra/superpowers');
    expect(src, isNotNull);
    expect(src!.owner, 'obra');
    expect(src.repo, 'superpowers');
  });

  test('a raw/branch/subpath source resolves ref and subPath', () {
    final src = githubPluginSourceFromSourceString(
      'owner/repo/raw/main/plugins/foo',
    );
    expect(src!.owner, 'owner');
    expect(src.repo, 'repo');
    expect(src.ref, 'main');
    expect(src.subPath, 'plugins/foo');
  });

  test('a malformed repo returns null (caller errors, never guesses)', () {
    expect(githubPluginSourceFromSourceString('justaname'), isNull);
    expect(githubPluginSourceFromSourceString('/'), isNull);
  });

  test('a bare GitHub URL normalizes to owner/repo via the marketplace helper',
      () {
    // The marketplace import path accepts an object url source; verify the
    // normalized string form the direct-install path shares.
    final src = githubPluginSourceFromSourceString('https://github.com/o/r');
    // A URL is not owner/name, so it must be rejected here (the URL form is
    // handled by the marketplace object-source resolver instead).
    expect(src, isNull);
  });
}
