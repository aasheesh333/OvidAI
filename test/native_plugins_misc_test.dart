import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/misc_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerMiscUtilities();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  group('registration', () {
    test('all seven leftover utilities are registered', () {
      for (final name in [
        'QR Generator',
        'SSH Key Manager',
        'Mermaid Diagrams',
        'Excalidraw Bridge',
        'Icon Library',
        'Font Preview',
        'Audio Notes',
      ]) {
        expect(NativePluginRegistry.I.has(name), isTrue, reason: name);
      }
      expect(
        NativePluginRegistry.I.capabilityForSlug('qr_generator'),
        isA<QrGeneratorCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('ssh_key_manager'),
        isA<SshKeyManagerCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('mermaid_diagrams'),
        isA<MermaidDiagramsCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('excalidraw_bridge'),
        isA<ExcalidrawBridgeCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('icon_library'),
        isA<IconLibraryCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('font_preview'),
        isA<FontPreviewCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('audio_notes'),
        isA<AudioNotesCapability>(),
      );
    });

    test('unknown tool names throw ArgumentError', () async {
      for (final slug in [
        'qr_generator',
        'ssh_key_manager',
        'mermaid_diagrams',
        'excalidraw_bridge',
        'icon_library',
        'font_preview',
        'audio_notes',
      ]) {
        final capability =
            NativePluginRegistry.I.capabilityForSlug(slug)!;
        await expectLater(
          capability.callTool('nope', {}),
          throwsA(isA<ArgumentError>()),
          reason: slug,
        );
      }
    });
  });

  group('QR Generator', () {
    test('generate returns PNG base64 with PNG magic header', () async {
      final qr = QrGeneratorCapability();
      final out = await qr.callTool('generate', {'text': 'hello'});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final base64Png = decoded['png_base64'] as String;
      // PNG magic bytes base64-encoded start with iVBOR.
      expect(base64Png.startsWith('iVBOR'), isTrue);
      final bytes = base64Decode(base64Png);
      expect(
        bytes.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      );
      expect(decoded['bytes'], bytes.length);
    });

    test('generate rejects empty text with ArgumentError', () async {
      final qr = QrGeneratorCapability();
      await expectLater(
        qr.callTool('generate', {'text': '   '}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validate honestly reports capacity overflow', () async {
      final qr = QrGeneratorCapability();
      final overlong = 'x' * 5000;
      final out = await qr.callTool('validate', {'text': overlong});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['fits'], isFalse);
      expect(decoded['length'], 5000);
      expect(
        (decoded['message'] as String).toLowerCase(),
        anyOf(contains('capacity'), contains('overflow'), contains('too long')),
      );

      final ok = await qr.callTool('validate', {'text': 'short'});
      expect((jsonDecode(ok) as Map)['fits'], isTrue);
    });

    test('generate refuses input beyond capacity instead of truncating',
        () async {
      final qr = QrGeneratorCapability();
      await expectLater(
        qr.callTool('generate', {'text': 'x' * 5000}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SSH Key Manager', () {
    test('generate ed25519 returns OpenSSH public key text', () async {
      final ssh = SshKeyManagerCapability();
      final out = await ssh.callTool('generate', {'type': 'ed25519'});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(
        (decoded['public_key'] as String).startsWith('ssh-ed25519 AAAA'),
        isTrue,
      );
      expect((decoded['private_key'] as String).isNotEmpty, isTrue);
      expect(decoded['type'], 'ed25519');
    });

    test('generate rejects unknown key types', () async {
      final ssh = SshKeyManagerCapability();
      await expectLater(
        ssh.callTool('generate', {'type': 'dsa'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('generate rejects rsa as unsupported on this device', () async {
      final ssh = SshKeyManagerCapability();
      await expectLater(
        ssh.callTool('generate', {'type': 'rsa'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('save/get/list round-trip through the vault', () async {
      final ssh = SshKeyManagerCapability();
      final gen = jsonDecode(
        await ssh.callTool('generate', {'type': 'ed25519'}),
      ) as Map<String, dynamic>;
      final saved = await ssh.callTool('save', {
        'name': 'laptop',
        'private_key': gen['private_key'],
        'public_key': gen['public_key'],
      });
      expect(saved, contains('laptop'));

      final got = await ssh.callTool('get', {'name': 'laptop'});
      final gotDecoded = jsonDecode(got) as Map<String, dynamic>;
      expect(gotDecoded['private_key'], gen['private_key']);

      final listed = jsonDecode(await ssh.callTool('list', {})) as List;
      expect(listed, contains('laptop'));
    });

    test('get of an unknown name throws ArgumentError', () async {
      final ssh = SshKeyManagerCapability();
      await expectLater(
        ssh.callTool('get', {'name': 'ghost'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fingerprint has the OpenSSH SHA256 shape', () async {
      final ssh = SshKeyManagerCapability();
      final gen = jsonDecode(
        await ssh.callTool('generate', {'type': 'ed25519'}),
      ) as Map<String, dynamic>;
      final out = await ssh.callTool('fingerprint', {
        'public_key': gen['public_key'],
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(
        decoded['fingerprint'],
        matches(RegExp(r'^SHA256:[A-Za-z0-9+/]+$')),
      );
    });

    test('fingerprint rejects malformed public keys', () async {
      final ssh = SshKeyManagerCapability();
      await expectLater(
        ssh.callTool('fingerprint', {'public_key': 'not-a-key'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Mermaid Diagrams', () {
    test('validate accepts a known diagram header', () async {
      final mermaid = MermaidDiagramsCapability();
      final out = await mermaid.callTool('validate', {
        'text': 'graph TD\n  A-->B',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['valid'], isTrue);
      expect((decoded['errors'] as List), isEmpty);
    });

    test('validate rejects an unknown diagram type', () async {
      final mermaid = MermaidDiagramsCapability();
      final out = await mermaid.callTool('validate', {
        'text': 'frobnicate the widgets',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['valid'], isFalse);
      expect((decoded['errors'] as List).join(' '), contains('diagram'));
    });

    test('render passes SVG through from kroki', () async {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>';
      final mermaid = MermaidDiagramsCapability(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.host, 'kroki.io');
          expect(request.body, contains('graph TD'));
          return http.Response(svg, 200);
        }),
      );
      final out = await mermaid.callTool('render', {
        'text': 'graph TD\n  A-->B',
      });
      expect(out, contains('<svg'));
    });

    test('render reports an honest offline message on network failure',
        () async {
      final mermaid = MermaidDiagramsCapability(
        client: MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      final out = await mermaid.callTool('render', {
        'text': 'graph TD\n  A-->B',
      });
      expect(out.toLowerCase(), contains('offline'));
      expect(out, contains('kroki.io'));
    });

    test('export returns text plus an honest char count', () async {
      final mermaid = MermaidDiagramsCapability();
      const text = 'graph TD\n  A-->B';
      final out = await mermaid.callTool('export', {'text': text});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['text'], contains('graph TD'));
      expect(decoded['chars'], (decoded['text'] as String).length);
    });
  });

  group('Excalidraw Bridge', () {
    const scene =
        '{"type":"excalidraw","elements":[{"id":"1","type":"rectangle"},'
        '{"id":"2","type":"ellipse"},{"id":"3","type":"rectangle"}]}';

    test('stats counts elements by type', () async {
      final bridge = ExcalidrawBridgeCapability();
      final out = await bridge.callTool('stats', {'json_text': scene});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['total'], 3);
      expect(decoded['by_type']['rectangle'], 2);
      expect(decoded['by_type']['ellipse'], 1);
    });

    test('add_text appends a text element', () async {
      final bridge = ExcalidrawBridgeCapability();
      final out = await bridge.callTool('add_text', {
        'json_text': scene,
        'text': 'hello',
        'x': 10,
        'y': 20,
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final elements = decoded['elements'] as List;
      expect(elements.length, 4);
      final added = elements.last as Map<String, dynamic>;
      expect(added['type'], 'text');
      expect(added['text'], 'hello');
    });

    test('merge concatenates two scenes', () async {
      final bridge = ExcalidrawBridgeCapability();
      const other =
          '{"type":"excalidraw","elements":[{"id":"9","type":"diamond"}]}';
      final out = await bridge.callTool('merge', {
        'a_json': scene,
        'b_json': other,
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['elements'] as List).length, 4);
    });

    test('malformed scene JSON throws FormatException', () async {
      final bridge = ExcalidrawBridgeCapability();
      await expectLater(
        bridge.callTool('stats', {'json_text': '{nope'}),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        bridge.callTool('add_text', {
          'json_text': '{"type":"excalidraw"}',
          'text': 'hi',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Icon Library', () {
    test('search parses Iconify hits with SVG urls', () async {
      final icons = IconLibraryCapability(
        client: MockClient((request) async {
          expect(request.url.host, 'api.iconify.design');
          expect(
            request.url.queryParameters['query'],
            'home',
          );
          return http.Response(
            '{"total":2,"icons":["mdi:home","mdi:house"]}',
            200,
          );
        }),
      );
      final out = await icons.callTool('search', {'query': 'home'});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final hits = decoded['icons'] as List;
      expect(hits.length, 2);
      expect((hits.first as Map)['name'], 'mdi:home');
      expect(
        (hits.first as Map)['svg_url'],
        'https://api.iconify.design/mdi:home.svg',
      );
    });

    test('search requires a query', () async {
      final icons = IconLibraryCapability();
      await expectLater(
        icons.callTool('search', {'query': '  '}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('search reports an honest message when offline', () async {
      final icons = IconLibraryCapability(
        client: MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      final out = await icons.callTool('search', {'query': 'home'});
      expect(out.toLowerCase(), contains('offline'));
    });
  });

  group('Font Preview', () {
    test('search matches families from the Google Fonts list', () async {
      final fonts = FontPreviewCapability(
        client: MockClient((request) async {
          expect(request.url.host, 'www.googleapis.com');
          return http.Response(
            '{"items":[{"family":"Inter","category":"sans-serif",'
            '"variants":["regular","700"]},{"family":"Roboto",'
            '"category":"sans-serif","variants":["regular"]}]}',
            200,
          );
        }),
      );
      final out = await fonts.callTool('search', {'query': 'inter'});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final matches = decoded['families'] as List;
      expect(matches.length, 1);
      expect((matches.first as Map)['family'], 'Inter');
    });

    test('preview_url returns a fonts.googleapis css2 URL', () async {
      final fonts = FontPreviewCapability();
      final out = await fonts.callTool('preview_url', {
        'family': 'Inter',
        'text': 'Hello',
      });
      expect(
        out.startsWith('https://fonts.googleapis.com/css2?family=Inter'),
        isTrue,
      );
      expect(out, contains('text=Hello'));
    });

    test('preview_url requires a family', () async {
      final fonts = FontPreviewCapability();
      await expectLater(
        fonts.callTool('preview_url', {'family': ' '}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('search reports an honest message when offline', () async {
      final fonts = FontPreviewCapability(
        client: MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      final out = await fonts.callTool('search', {'query': 'inter'});
      expect(out.toLowerCase(), contains('offline'));
    });
  });

  group('Audio Notes', () {
    test('transcribe without a key returns the configure-first message',
        () async {
      final audio = AudioNotesCapability();
      final out = await audio.callTool('transcribe', {
        'audio_url': 'https://example.com/note.mp3',
      });
      expect(out, contains('Configure'));
      expect(out, contains('openai_api_key'));
    });

    test('transcribe posts the URL to Whisper and returns text', () async {
      final audio = AudioNotesCapability(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://api.openai.com/v1/audio/transcriptions',
          );
          expect(request.headers['authorization'], 'Bearer sk-test');
          expect(request.body, contains('https://example.com/note.mp3'));
          return http.Response('{"text":"hello world"}', 200);
        }),
      );
      await audio.configure({'openai_api_key': 'sk-test'});
      final out = await audio.callTool('transcribe', {
        'audio_url': 'https://example.com/note.mp3',
      });
      expect(out, contains('hello world'));
    });

    test('transcribe rejects non-http URLs', () async {
      final audio = AudioNotesCapability(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await audio.configure({'openai_api_key': 'sk-test'});
      await expectLater(
        audio.callTool('transcribe', {'audio_url': 'not a url'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
