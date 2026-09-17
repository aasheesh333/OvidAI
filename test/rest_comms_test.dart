import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';
import 'package:ovid_ai/core/native_plugins/rest_descriptors_comms.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Comms batch tests (NP4 Task 3): one MockClient-canned test per tool
/// asserting the REQUEST side (URL, method, auth header/query, secret
/// correctness), configure-first gating per service, one error
/// passthrough, the Email Drafts prompt contract, and roster halves.
///
/// HTTP never leaves the process: every capability runs over [MockClient].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    // Scrub any secret stored by an earlier test so the configure-first
    // tests below observe a genuinely empty store.
    for (final descriptor in commsDescriptors) {
      await NativePluginConfigStore.I.clear(
        pluginName: descriptor.pluginName,
        fields: RestApiCapability(descriptor).configFields,
      );
    }
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  /// Wraps the named comms descriptor in a [RestApiCapability] backed by
  /// [onRequest], configuring [secret] (+ [extras]) through the real
  /// config store (secure-storage + prefs mocks from setUp).
  Future<RestApiCapability> capFor(
    String pluginName,
    Future<http.Response> Function(http.Request) onRequest, {
    String? secret,
    Map<String, String> extras = const {},
  }) async {
    final descriptor = commsDescriptors.firstWhere(
      (d) => d.pluginName == pluginName,
      orElse: () => throw ArgumentError('No comms descriptor: $pluginName'),
    );
    final cap = RestApiCapability(
      descriptor,
      client: MockClient((request) async => onRequest(request)),
    );
    final values = <String, String>{...extras};
    if (secret != null && descriptor.credentialKey.isNotEmpty) {
      values[descriptor.credentialKey] = secret;
    }
    if (values.isNotEmpty) await cap.configure(values);
    return cap;
  }

  group('descriptors', () {
    test('batch exposes the 7 spec-exact REST plugin names', () {
      expect(
        commsDescriptors.map((d) => d.pluginName),
        containsAll([
          'Slack Notify',
          'Discord MCP',
          'Discord Bot Builder',
          'Telegram MCP',
          'Twilio MCP',
          'Cal.com MCP',
          'WhatsApp Bridge',
        ]),
      );
      expect(commsDescriptors, hasLength(7));
    });

    test('bases and auth schemes match spec §4.1', () {
      final byName = {for (final d in commsDescriptors) d.pluginName: d};
      expect(byName['Slack Notify']!.baseUrl, 'https://slack.com/api');
      expect(byName['Slack Notify']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Discord MCP']!.baseUrl, 'https://discord.com/api/v10');
      expect(byName['Discord MCP']!.auth, RestAuthKind.bearerHeader);
      expect(
        byName['Discord Bot Builder']!.baseUrl,
        'https://discord.com/api/v10',
      );
      expect(
        byName['Discord Bot Builder']!.auth,
        RestAuthKind.bearerHeader,
      );
      expect(byName['Telegram MCP']!.baseUrl, 'https://api.telegram.org');
      expect(byName['Telegram MCP']!.auth, RestAuthKind.none);
      expect(
        byName['Twilio MCP']!.baseUrl,
        'https://api.twilio.com/2010-04-01',
      );
      expect(byName['Twilio MCP']!.auth, RestAuthKind.basic);
      expect(byName['Cal.com MCP']!.baseUrl, 'https://api.cal.com/v1');
      expect(byName['Cal.com MCP']!.auth, RestAuthKind.queryKey);
      expect(
        byName['WhatsApp Bridge']!.baseUrl,
        'https://graph.facebook.com/v21.0',
      );
      expect(
        byName['WhatsApp Bridge']!.auth,
        RestAuthKind.bearerHeader,
      );
    });

    test('tool rosters match spec §4.1', () {
      Iterable<String> toolsOf(String name) => commsDescriptors
          .firstWhere((d) => d.pluginName == name)
          .tools
          .map((t) => t.name);
      expect(
        toolsOf('Slack Notify'),
        containsAll(['send_message', 'list_channels', 'history']),
      );
      expect(
        toolsOf('Discord MCP'),
        containsAll(['send_message', 'list_guilds', 'list_channels']),
      );
      expect(
        toolsOf('Discord Bot Builder'),
        containsAll(['create_channel', 'create_role', 'send_message']),
      );
      expect(
        toolsOf('Telegram MCP'),
        containsAll(['send_message', 'get_updates', 'get_me']),
      );
      expect(
        toolsOf('Twilio MCP'),
        containsAll(['send_sms', 'list_messages', 'list_calls']),
      );
      expect(
        toolsOf('Cal.com MCP'),
        containsAll(['list_bookings', 'list_event_types', 'get_booking']),
      );
      expect(
        toolsOf('WhatsApp Bridge'),
        containsAll(['send_text', 'list_templates']),
      );
    });
  });

  group('Slack Notify', () {
    test('send_message POSTs chat.postMessage with Bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Slack Notify',
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'xoxb-slack',
      );
      final out = await cap.callTool('send_message', {
        'channel': 'C123',
        'text': 'hello',
      });
      expect(out, contains('"ok":true'));
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        startsWith('https://slack.com/api/chat.postMessage'),
      );
      expect(seen!.headers['Authorization'], 'Bearer xoxb-slack');
      expect(seen!.url.queryParameters['channel'], 'C123');
      expect(seen!.url.queryParameters['text'], 'hello');
    });

    test('list_channels GETs conversations.list', () async {
      http.Request? seen;
      final cap = await capFor(
        'Slack Notify',
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'xoxb-slack',
      );
      await cap.callTool('list_channels', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://slack.com/api/conversations.list'),
      );
      expect(seen!.headers['Authorization'], 'Bearer xoxb-slack');
    });

    test('history GETs conversations.history with channel+limit', () async {
      http.Request? seen;
      final cap = await capFor(
        'Slack Notify',
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'xoxb-slack',
      );
      await cap.callTool('history', {'channel': 'C123', 'limit': 5});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://slack.com/api/conversations.history'),
      );
      expect(seen!.url.queryParameters['channel'], 'C123');
      expect(seen!.url.queryParameters['limit'], '5');
    });

    test('missing bot token names the label, never the secret', () async {
      final cap = await capFor(
        'Slack Notify',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('send_message', {
        'channel': 'C123',
        'text': 'hi',
      });
      expect(out, contains('Configure Slack bot token first'));
      expect(out, contains('"Slack Notify"'));
      expect(out, contains('bot_token'));
      expect(out.contains('xoxb-slack'), isFalse);
    });

    test('Slack error body passes through verbatim with status', () async {
      const body = '{"ok":false,"error":"channel_not_found"}';
      final cap = await capFor(
        'Slack Notify',
        (_) async => http.Response(body, 200),
        secret: 'xoxb-slack',
      );
      // 200s return verbatim; a real failure status keeps its status line.
      final failing = await capFor(
        'Slack Notify',
        (_) async => http.Response(body, 404),
        secret: 'xoxb-slack',
      );
      expect(await failing.callTool('history', {'channel': 'CX'}), contains('404'));
      expect(await failing.callTool('history', {'channel': 'CX'}), contains(body));
      expect(await cap.callTool('list_channels', {}), contains(body));
    });
  });

  group('Discord MCP', () {
    test('send_message POSTs channel messages with Bot auth + JSON', () async {
      http.Request? seen;
      final cap = await capFor(
        'Discord MCP',
        (request) async {
          seen = request;
          return http.Response('{"id":"1"}', 200);
        },
        secret: 'discord-tok',
      );
      await cap.callTool('send_message', {
        'channel_id': '999',
        'body': {'content': 'hi'},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://discord.com/api/v10/channels/999/messages',
      );
      expect(seen!.headers['Authorization'], 'Bot discord-tok');
      expect(
        jsonDecode(seen!.body) as Map,
        {'content': 'hi'},
      );
    });

    test('list_guilds GETs users/@me/guilds', () async {
      http.Request? seen;
      final cap = await capFor(
        'Discord MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        secret: 'discord-tok',
      );
      await cap.callTool('list_guilds', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://discord.com/api/v10/users/@me/guilds',
      );
      expect(seen!.headers['Authorization'], 'Bot discord-tok');
    });

    test('list_channels GETs guild channels', () async {
      http.Request? seen;
      final cap = await capFor(
        'Discord MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        secret: 'discord-tok',
      );
      await cap.callTool('list_channels', {'guild_id': '111'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://discord.com/api/v10/guilds/111/channels',
      );
      expect(seen!.headers['Authorization'], 'Bot discord-tok');
    });

    test('missing bot token gates before any request', () async {
      var called = false;
      final cap = await capFor('Discord MCP', (_) async {
        called = true;
        return http.Response('[]', 200);
      });
      final out = await cap.callTool('list_guilds', {});
      expect(out, contains('Configure Discord bot token first'));
      expect(called, isFalse);
    });
  });

  group('Discord Bot Builder', () {
    test('create_channel POSTs guild channels with the JSON body', () async {
      http.Request? seen;
      final cap = await capFor(
        'Discord Bot Builder',
        (request) async {
          seen = request;
          return http.Response('{"id":"5"}', 200);
        },
        secret: 'builder-tok',
      );
      await cap.callTool('create_channel', {
        'guild_id': '111',
        'body': {'name': 'announcements', 'type': 0},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://discord.com/api/v10/guilds/111/channels',
      );
      expect(seen!.headers['Authorization'], 'Bot builder-tok');
      expect(
        jsonDecode(seen!.body) as Map,
        {'name': 'announcements', 'type': 0},
      );
    });

    test('create_role POSTs guild roles', () async {
      http.Request? seen;
      final cap = await capFor(
        'Discord Bot Builder',
        (request) async {
          seen = request;
          return http.Response('{"id":"7"}', 200);
        },
        secret: 'builder-tok',
      );
      await cap.callTool('create_role', {
        'guild_id': '111',
        'body': {'name': 'mods'},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://discord.com/api/v10/guilds/111/roles',
      );
      expect(seen!.headers['Authorization'], 'Bot builder-tok');
      expect(jsonDecode(seen!.body) as Map, {'name': 'mods'});
    });

    test('send_message POSTs channel messages', () async {
      http.Request? seen;
      final cap = await capFor(
        'Discord Bot Builder',
        (request) async {
          seen = request;
          return http.Response('{"id":"9"}', 200);
        },
        secret: 'builder-tok',
      );
      await cap.callTool('send_message', {
        'channel_id': '222',
        'body': {'content': 'deployed'},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://discord.com/api/v10/channels/222/messages',
      );
      expect(seen!.headers['Authorization'], 'Bot builder-tok');
    });

    test('missing bot token gates before any request', () async {
      final cap = await capFor(
        'Discord Bot Builder',
        (_) async => http.Response('{}', 200),
      );
      expect(
        await cap.callTool('create_role', {
          'guild_id': '1',
          'body': {'name': 'x'},
        }),
        contains('Configure Discord bot token first'),
      );
    });
  });

  group('Telegram MCP', () {
    test('send_message hits /bot<token>/sendMessage, no auth header',
        () async {
      http.Request? seen;
      final cap = await capFor(
        'Telegram MCP',
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'tg-secret',
      );
      await cap.callTool('send_message', {
        'chat_id': '42',
        'text': 'hello',
      });
      expect(
        seen!.url.toString(),
        startsWith('https://api.telegram.org/bottg-secret/sendMessage'),
      );
      expect(seen!.url.queryParameters['chat_id'], '42');
      expect(seen!.url.queryParameters['text'], 'hello');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
    });

    test('get_updates hits /bot<token>/getUpdates', () async {
      http.Request? seen;
      final cap = await capFor(
        'Telegram MCP',
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'tg-secret',
      );
      await cap.callTool('get_updates', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://api.telegram.org/bottg-secret/getUpdates',
      );
    });

    test('get_me hits /bot<token>/getMe', () async {
      http.Request? seen;
      final cap = await capFor(
        'Telegram MCP',
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'tg-secret',
      );
      await cap.callTool('get_me', {});
      expect(
        seen!.url.toString(),
        'https://api.telegram.org/bottg-secret/getMe',
      );
    });

    test('missing bot token gates and never leaks the secret', () async {
      final cap = await capFor(
        'Telegram MCP',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('get_me', {});
      expect(out, contains('Configure Telegram bot token first'));
      expect(out, contains('bot_token'));
      expect(out.contains('tg-secret'), isFalse);
    });
  });

  group('Twilio MCP', () {
    test('send_sms POSTs form-encoded Fields with Basic auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Twilio MCP',
        (request) async {
          seen = request;
          return http.Response('{"sid":"SM1"}', 201);
        },
        secret: 'tw-token',
        extras: {'account_sid': 'ACsid'},
      );
      await cap.callTool('send_sms', {
        'fields': {'From': '+1001', 'To': '+1002', 'Body': 'hi'},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://api.twilio.com/2010-04-01/Accounts/ACsid/Messages.json',
      );
      expect(
        seen!.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('ACsid:tw-token'))}',
      );
      expect(
        seen!.headers['content-type'],
        contains('application/x-www-form-urlencoded'),
      );
      final form = Uri.splitQueryString(seen!.body);
      expect(
        form,
        {'From': '+1001', 'To': '+1002', 'Body': 'hi'},
      );
    });

    test('list_messages GETs account messages with limit', () async {
      http.Request? seen;
      final cap = await capFor(
        'Twilio MCP',
        (request) async {
          seen = request;
          return http.Response('{"messages":[]}', 200);
        },
        secret: 'tw-token',
        extras: {'account_sid': 'ACsid'},
      );
      await cap.callTool('list_messages', {'limit': 3});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith(
          'https://api.twilio.com/2010-04-01/Accounts/ACsid/Messages.json',
        ),
      );
      expect(seen!.url.queryParameters['limit'], '3');
      expect(
        seen!.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('ACsid:tw-token'))}',
      );
    });

    test('list_calls GETs account calls', () async {
      http.Request? seen;
      final cap = await capFor(
        'Twilio MCP',
        (request) async {
          seen = request;
          return http.Response('{"calls":[]}', 200);
        },
        secret: 'tw-token',
        extras: {'account_sid': 'ACsid'},
      );
      await cap.callTool('list_calls', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith(
          'https://api.twilio.com/2010-04-01/Accounts/ACsid/Calls.json',
        ),
      );
    });

    test('missing auth token gates on the secret label', () async {
      final cap = await capFor(
        'Twilio MCP',
        (_) async => http.Response('{}', 200),
        extras: {'account_sid': 'ACsid'},
      );
      final out = await cap.callTool('list_messages', {});
      expect(out, contains('Configure Twilio auth token first'));
      expect(out, contains('auth_token'));
      expect(out.contains('tw-token'), isFalse);
    });

    test('missing account SID gates on the username field', () async {
      final cap = await capFor(
        'Twilio MCP',
        (_) async => http.Response('{}', 200),
        secret: 'tw-token',
      );
      final out = await cap.callTool('list_messages', {});
      expect(out, contains('Configure Twilio account SID first'));
      expect(out, contains('account_sid'));
    });
  });

  group('Cal.com MCP', () {
    test('list_bookings appends the apiKey query param', () async {
      http.Request? seen;
      final cap = await capFor(
        'Cal.com MCP',
        (request) async {
          seen = request;
          return http.Response('{"bookings":[]}', 200);
        },
        secret: 'cal-key',
      );
      await cap.callTool('list_bookings', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://api.cal.com/v1/bookings'),
      );
      expect(seen!.url.queryParameters['apiKey'], 'cal-key');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
    });

    test('list_event_types hits /event-types with the key', () async {
      http.Request? seen;
      final cap = await capFor(
        'Cal.com MCP',
        (request) async {
          seen = request;
          return http.Response('{"event_types":[]}', 200);
        },
        secret: 'cal-key',
      );
      await cap.callTool('list_event_types', {});
      expect(
        seen!.url.toString(),
        startsWith('https://api.cal.com/v1/event-types'),
      );
      expect(seen!.url.queryParameters['apiKey'], 'cal-key');
    });

    test('get_booking substitutes the id path segment', () async {
      http.Request? seen;
      final cap = await capFor(
        'Cal.com MCP',
        (request) async {
          seen = request;
          return http.Response('{"id":9}', 200);
        },
        secret: 'cal-key',
      );
      await cap.callTool('get_booking', {'id': 9});
      expect(
        seen!.url.toString(),
        startsWith('https://api.cal.com/v1/bookings/9'),
      );
      expect(seen!.url.queryParameters['apiKey'], 'cal-key');
    });

    test('missing API key gates before any request', () async {
      var called = false;
      final cap = await capFor('Cal.com MCP', (_) async {
        called = true;
        return http.Response('{}', 200);
      });
      final out = await cap.callTool('list_bookings', {});
      expect(out, contains('Configure Cal.com API key first'));
      expect(called, isFalse);
    });
  });

  group('WhatsApp Bridge', () {
    test('send_text POSTs to the phone-number messages node', () async {
      http.Request? seen;
      final cap = await capFor(
        'WhatsApp Bridge',
        (request) async {
          seen = request;
          return http.Response('{"messages":[{"id":"w1"}]}', 200);
        },
        secret: 'wa-tok',
        extras: {'phone_number_id': '555'},
      );
      await cap.callTool('send_text', {
        'body': {
          'messaging_product': 'whatsapp',
          'to': '1555123',
          'type': 'text',
          'text': {'body': 'hi'},
        },
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://graph.facebook.com/v21.0/555/messages',
      );
      expect(seen!.headers['Authorization'], 'Bearer wa-tok');
      final payload = jsonDecode(seen!.body) as Map;
      expect(payload['to'], '1555123');
      expect((payload['text'] as Map)['body'], 'hi');
    });

    test('list_templates GETs the templates node', () async {
      http.Request? seen;
      final cap = await capFor(
        'WhatsApp Bridge',
        (request) async {
          seen = request;
          return http.Response('{"data":[]}', 200);
        },
        secret: 'wa-tok',
        extras: {'phone_number_id': '555'},
      );
      await cap.callTool('list_templates', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://graph.facebook.com/v21.0/555/message_templates',
      );
      expect(seen!.headers['Authorization'], 'Bearer wa-tok');
    });

    test('missing access token gates before any request', () async {
      final cap = await capFor(
        'WhatsApp Bridge',
        (_) async => http.Response('{}', 200),
        extras: {'phone_number_id': '555'},
      );
      final out = await cap.callTool('send_text', {
        'body': {'to': '1'},
      });
      expect(out, contains('Configure WhatsApp access token first'));
      expect(out.contains('wa-tok'), isFalse);
    });
  });

  group('Email Drafts (prompt capability)', () {
    test('registerComms registers the prompt capability', () {
      registerComms();
      final cap = NativePluginRegistry.I.capabilityFor('Email Drafts');
      expect(cap, isNotNull);
      expect(cap, isA<NativePromptCapability>());
      expect(cap!.tools.map((t) => t.name), contains('draft'));
    });

    test('draft prompt embeds to/subject/context + honest no-send note',
        () {
      registerComms();
      final cap = NativePluginRegistry.I.capabilityFor('Email Drafts')
          as NativePromptCapability;
      final prompt = cap.buildPrompt('draft', {
        'to': 'boss@example.com',
        'subject': 'Q3 report',
        'context': 'numbers are up',
      });
      expect(prompt, contains('boss@example.com'));
      expect(prompt, contains('Q3 report'));
      expect(prompt, contains('numbers are up'));
      expect(prompt.toLowerCase(), contains('does not send'));
    });

    test('draft tool description says sending is out of scope', () {
      registerComms();
      final cap = NativePluginRegistry.I.capabilityFor('Email Drafts')!;
      final draft = cap.tools.firstWhere((t) => t.name == 'draft');
      expect(draft.description.toLowerCase(), contains('never sends'));
    });

    test('unknown prompt tool throws ArgumentError', () {
      registerComms();
      final cap = NativePluginRegistry.I.capabilityFor('Email Drafts')
          as NativePromptCapability;
      expect(
        () => cap.buildPrompt('send', {'to': 'a', 'subject': 'b'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('registration + roster', () {
    test('registerComms registers all 7 REST services', () {
      registerComms();
      for (final name in [
        'Slack Notify',
        'Discord MCP',
        'Discord Bot Builder',
        'Telegram MCP',
        'Twilio MCP',
        'Cal.com MCP',
        'WhatsApp Bridge',
      ]) {
        expect(
          NativePluginRegistry.I.has(name),
          isTrue,
          reason: '$name registered',
        );
      }
    });

    test('roster half: plugin__slack_notify__send_message resolves', () {
      registerComms();
      const canonical = 'plugin__slack_notify__send_message';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'Slack Notify');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('roster half: plugin__discord_mcp__send_message resolves', () {
      registerComms();
      const canonical = 'plugin__discord_mcp__send_message';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'Discord MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('unknown tool still throws ArgumentError', () async {
      final cap = await capFor(
        'Slack Notify',
        (_) async => http.Response('{}', 200),
        secret: 'xoxb-slack',
      );
      await expectLater(
        cap.callTool('nope', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
