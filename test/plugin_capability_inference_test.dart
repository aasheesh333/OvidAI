import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';

// P20: capability inference must have a single source of truth
// (`inferRequestedCapabilities`) and must never blanket-grant capabilities a
// manifest does not actually imply. `workspaceWrite`, `sessionRead`,
// `sessionWrite`, and `deviceControl` are NOT derivable from the manifest
// contribution shape (hooks and MCP declarations say nothing about a server's
// tool surface, session access, or device control), so they are only ever
// requested by explicit declaration. Inferring them unconditionally would also
// change adapter manifest digests and the grant gate's required set, breaking
// previously-approved installs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const notDerivable = {
    PluginCapability.workspaceWrite,
    PluginCapability.sessionRead,
    PluginCapability.sessionWrite,
    PluginCapability.deviceControl,
  };

  NormalizedPluginManifest manifest({
    Set<PluginCapability> requestedCapabilities = const {},
  }) => NormalizedPluginManifest(
    id: 'acme/probe-kit',
    name: 'Probe Kit',
    version: '1.0.0',
    format: PluginFormat.claudeCode,
    rootPath: '/tmp/acme/probe-kit',
    commands: [
      PluginCommand(
        pluginId: 'acme/probe-kit',
        name: 'run',
        path: 'commands/run.md',
      ),
    ],
    hooks: [
      PluginHook(
        pluginId: 'acme/probe-kit',
        event: 'pre_tool',
        type: 'command',
        payload: 'rm -rf build && echo done',
        path: 'hooks/hooks.json',
      ),
    ],
    mcpServers: [
      PluginMcpServer(
        pluginId: 'acme/probe-kit',
        name: 'filesystem',
        transport: 'stdio',
        command: 'node',
        path: '.mcp.json',
      ),
    ],
    requestedCapabilities: requestedCapabilities,
  );

  Directory adapterFixture() {
    final root = Directory.systemTemp.createTempSync('pci-adapter-');
    addTearDown(() => root.deleteSync(recursive: true));
    void write(String path, String content) {
      final file = File('${root.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    write(
      '.claude-plugin/plugin.json',
      jsonEncode({'name': 'Adapter Kit', 'author': 'acme', 'version': '1.0.0'}),
    );
    write('commands/run.md', '---\nname: Run\n---\nRun.');
    write(
      'hooks/hooks.json',
      jsonEncode({
        'hooks': {
          'PreToolUse': 'echo checking',
        },
      }),
    );
    write(
      '.mcp.json',
      jsonEncode({
        'mcpServers': {
          'filesystem': {'command': 'node', 'args': ['fs.js']},
        },
      }),
    );
    return root;
  }

  group('P20 single source of truth', () {
    test(
      'adapter requestedCapabilities match the public inference point exactly',
      () async {
        final manifest = await const PluginAdapterRegistry().inspect(
          adapterFixture(),
        );

        expect(manifest.requestedCapabilities, isNotEmpty);
        expect(
          manifest.requestedCapabilities,
          equals(inferRequestedCapabilities(manifest)),
        );
      },
    );
  });

  group('P20 conservative inference', () {
    test(
      'workspaceWrite/sessionRead/sessionWrite/deviceControl are never inferred from hooks or MCP declarations',
      () {
        final caps = inferRequestedCapabilities(manifest());

        expect(caps.intersection(notDerivable), isEmpty);
        expect(caps, contains(PluginCapability.workspaceRead));
        expect(caps, contains(PluginCapability.shellExecute));
        expect(caps, contains(PluginCapability.mcpRegister));
      },
    );

    test(
      'explicitly declared workspaceWrite/sessionRead/sessionWrite/deviceControl are retained',
      () {
        final caps = inferRequestedCapabilities(
          manifest(requestedCapabilities: notDerivable),
        );

        expect(caps.containsAll(notDerivable), isTrue);
      },
    );

    test(
      'adapter manifests keep the four out of the required set so existing grants stay effective',
      () async {
        SharedPreferences.setMockInitialValues({});
        final manifest = await const PluginAdapterRegistry().inspect(
          adapterFixture(),
        );

        expect(manifest.requestedCapabilities.intersection(notDerivable), isEmpty);

        final store = PluginPermissionStore();
        await store.save(
          PluginPermissionGrant(
            pluginId: manifest.id,
            manifestDigest: pluginManifestDigest(manifest),
            capabilities: inferRequestedCapabilities(manifest),
            approvedAt: DateTime.utc(2026, 9, 19),
          ),
        );

        expect(
          await store.effectiveRuntimeGrant(
            pluginId: manifest.id,
            manifest: manifest,
          ),
          isNotNull,
        );
      },
    );
  });
}
