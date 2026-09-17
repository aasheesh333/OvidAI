import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerAllNativePlugins();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  test('NP4 completeness audit: every catalog plugin seed maps to native capability or documented exclusion', () async {
    final app = AppState.createForTest();
    final seeds = app.plugins;

    // Documented exclusions in spec & rulings:
    const documentedExclusions = {
      // Direct core tool backings handled in AgentService
      'Web Search',
      'DeepThink Reasoning',
      'Image Studio',
      'File Reader',
      'Sandbox Runtime',
      'Web Fetch & Reader',
      'Voice Input',
      'RAG Memory',
      'Code Runner',

      // Mapped to backing MCP servers via npx / stdio
      'Puppeteer MCP',
      'Postgres Tools',
      'Playwright MCP',

      // Management UI
      'MCP Server Hub',

      // Deferred in spec (requires composer screenshot attach flow)
      'Screen Awareness',
    };

    final missing = <String>[];

    for (final p in seeds) {
      if (documentedExclusions.contains(p.name)) {
        continue;
      }
      if (!NativePluginRegistry.I.has(p.name)) {
        missing.add('${p.name} (${p.category})');
      }
    }

    expect(
      missing,
      isEmpty,
      reason: 'The following seeded plugins are missing native capabilities: ${missing.join(', ')}',
    );
  });
}
