import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';

/// Comms integrations batch (NP4 Task 3, spec §4.1): declarative
/// [RestServiceDescriptor]s for Slack, Discord (×2), Telegram, Twilio,
/// Cal.com, and WhatsApp, plus the draft-only Email Drafts prompt
/// capability. Executed by [RestApiCapability]; registered via
/// [registerComms] (wired into `registerAllNativePlugins`).
///
/// Body-shape convention (forced by the engine: one map arg per body):
/// scalar path/query args keep their spec names (`channel`, `chat_id`,
/// `limit`, …); endpoints that need a JSON/form body take a single map
/// arg (`body` for JSON, `fields` for Twilio's form fields) whose shape
/// is documented on the tool. Slack `send_message` and Telegram
/// `send_message` keep pure scalars because both APIs honestly accept
/// the parameters as URL query arguments on the send call.
const List<RestServiceDescriptor> commsDescriptors = [
  RestServiceDescriptor(
    pluginName: 'Slack Notify',
    baseUrl: 'https://slack.com/api',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bearer ',
    credentialKey: 'bot_token',
    credentialLabel: 'Slack bot token',
    tools: [
      RestToolDef(
        name: 'send_message',
        description:
            'Post a message to a Slack channel (channel + text travel as '
            'request parameters, which Slack accepts on this method).',
        method: 'POST',
        path: '/chat.postMessage',
        inputSchema: {
          'type': 'object',
          'properties': {
            'channel': {'type': 'string'},
            'text': {'type': 'string'},
          },
          'required': ['channel', 'text'],
        },
        queryArgs: ['channel', 'text'],
        required: ['channel', 'text'],
      ),
      RestToolDef(
        name: 'list_channels',
        description: 'List the workspace channels (conversations.list).',
        method: 'GET',
        path: '/conversations.list',
        inputSchema: {'type': 'object'},
      ),
      RestToolDef(
        name: 'history',
        description: 'Read recent messages from a channel.',
        method: 'GET',
        path: '/conversations.history',
        inputSchema: {
          'type': 'object',
          'properties': {
            'channel': {'type': 'string'},
            'limit': {'type': 'number'},
          },
          'required': ['channel'],
        },
        queryArgs: ['channel', 'limit'],
        required: ['channel'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Discord MCP',
    baseUrl: 'https://discord.com/api/v10',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bot ',
    credentialKey: 'bot_token',
    credentialLabel: 'Discord bot token',
    tools: [
      RestToolDef(
        name: 'send_message',
        description:
            'Send a message to a Discord channel. body is the Discord '
            'message JSON, e.g. {"content": "hello"}.',
        method: 'POST',
        path: '/channels/{channel_id}/messages',
        inputSchema: {
          'type': 'object',
          'properties': {
            'channel_id': {'type': 'string'},
            'body': {'type': 'object'},
          },
          'required': ['channel_id', 'body'],
        },
        jsonBodyArg: 'body',
        required: ['channel_id', 'body'],
      ),
      RestToolDef(
        name: 'list_guilds',
        description: 'List the servers (guilds) the bot belongs to.',
        method: 'GET',
        path: '/users/@me/guilds',
        inputSchema: {'type': 'object'},
      ),
      RestToolDef(
        name: 'list_channels',
        description: 'List the channels of a guild (server).',
        method: 'GET',
        path: '/guilds/{guild_id}/channels',
        inputSchema: {
          'type': 'object',
          'properties': {
            'guild_id': {'type': 'string'},
          },
          'required': ['guild_id'],
        },
        required: ['guild_id'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Discord Bot Builder',
    baseUrl: 'https://discord.com/api/v10',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bot ',
    credentialKey: 'bot_token',
    credentialLabel: 'Discord bot token',
    tools: [
      RestToolDef(
        name: 'create_channel',
        description:
            'Create a guild channel. body is the Discord channel JSON, '
            'e.g. {"name": "announcements", "type": 0}.',
        method: 'POST',
        path: '/guilds/{guild_id}/channels',
        inputSchema: {
          'type': 'object',
          'properties': {
            'guild_id': {'type': 'string'},
            'body': {'type': 'object'},
          },
          'required': ['guild_id', 'body'],
        },
        jsonBodyArg: 'body',
        required: ['guild_id', 'body'],
      ),
      RestToolDef(
        name: 'create_role',
        description:
            'Create a guild role. body is the Discord role JSON, '
            'e.g. {"name": "mods"}.',
        method: 'POST',
        path: '/guilds/{guild_id}/roles',
        inputSchema: {
          'type': 'object',
          'properties': {
            'guild_id': {'type': 'string'},
            'body': {'type': 'object'},
          },
          'required': ['guild_id', 'body'],
        },
        jsonBodyArg: 'body',
        required: ['guild_id', 'body'],
      ),
      RestToolDef(
        name: 'send_message',
        description:
            'Send a message to a Discord channel. body is the Discord '
            'message JSON, e.g. {"content": "hello"}.',
        method: 'POST',
        path: '/channels/{channel_id}/messages',
        inputSchema: {
          'type': 'object',
          'properties': {
            'channel_id': {'type': 'string'},
            'body': {'type': 'object'},
          },
          'required': ['channel_id', 'body'],
        },
        jsonBodyArg: 'body',
        required: ['channel_id', 'body'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Telegram MCP',
    baseUrl: 'https://api.telegram.org',
    auth: RestAuthKind.none,
    credentialKey: 'bot_token',
    credentialLabel: 'Telegram bot token',
    tools: [
      RestToolDef(
        name: 'send_message',
        description:
            'Send a message via the Telegram Bot API (chat_id + text '
            'travel as request parameters, which Telegram accepts).',
        method: 'GET',
        path: '/bot{bot_token}/sendMessage',
        inputSchema: {
          'type': 'object',
          'properties': {
            'chat_id': {'type': 'string'},
            'text': {'type': 'string'},
          },
          'required': ['chat_id', 'text'],
        },
        queryArgs: ['chat_id', 'text'],
        required: ['chat_id', 'text'],
      ),
      RestToolDef(
        name: 'get_updates',
        description: 'Poll pending updates for the bot (getUpdates).',
        method: 'GET',
        path: '/bot{bot_token}/getUpdates',
        inputSchema: {'type': 'object'},
      ),
      RestToolDef(
        name: 'get_me',
        description: 'Return the bot identity (getMe).',
        method: 'GET',
        path: '/bot{bot_token}/getMe',
        inputSchema: {'type': 'object'},
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Twilio MCP',
    baseUrl: 'https://api.twilio.com/2010-04-01',
    auth: RestAuthKind.basic,
    authUsernameKey: 'account_sid',
    credentialKey: 'auth_token',
    credentialLabel: 'Twilio auth token',
    extraConfig: [
      NativePluginConfigField(
        key: 'account_sid',
        label: 'Twilio account SID',
        hint: 'The AC… account identifier (used as the basic-auth '
            'username and in request paths).',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'send_sms',
        description:
            'Send an SMS. fields carries the Twilio form fields '
            '{"From": "+…", "To": "+…", "Body": "…"} (Twilio is '
            'form-encoded).',
        method: 'POST',
        path: '/Accounts/{account_sid}/Messages.json',
        inputSchema: {
          'type': 'object',
          'properties': {
            'fields': {'type': 'object'},
          },
          'required': ['fields'],
        },
        formBodyArg: 'fields',
        required: ['fields'],
      ),
      RestToolDef(
        name: 'list_messages',
        description: 'List recent account messages (newest first).',
        method: 'GET',
        path: '/Accounts/{account_sid}/Messages.json',
        inputSchema: {
          'type': 'object',
          'properties': {
            'limit': {'type': 'number'},
          },
        },
        queryArgs: ['limit'],
      ),
      RestToolDef(
        name: 'list_calls',
        description: 'List recent account calls (newest first).',
        method: 'GET',
        path: '/Accounts/{account_sid}/Calls.json',
        inputSchema: {
          'type': 'object',
          'properties': {
            'limit': {'type': 'number'},
          },
        },
        queryArgs: ['limit'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Cal.com MCP',
    baseUrl: 'https://api.cal.com/v1',
    auth: RestAuthKind.queryKey,
    authQueryKey: 'apiKey',
    credentialKey: 'api_key',
    credentialLabel: 'Cal.com API key',
    tools: [
      RestToolDef(
        name: 'list_bookings',
        description: 'List bookings.',
        method: 'GET',
        path: '/bookings',
        inputSchema: {'type': 'object'},
      ),
      RestToolDef(
        name: 'list_event_types',
        description: 'List event types.',
        method: 'GET',
        path: '/event-types',
        inputSchema: {'type': 'object'},
      ),
      RestToolDef(
        name: 'get_booking',
        description: 'Fetch one booking by id.',
        method: 'GET',
        path: '/bookings/{id}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
        required: ['id'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'WhatsApp Bridge',
    baseUrl: 'https://graph.facebook.com/v21.0',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bearer ',
    credentialKey: 'access_token',
    credentialLabel: 'WhatsApp access token',
    extraConfig: [
      NativePluginConfigField(
        key: 'phone_number_id',
        label: 'Phone number ID',
        hint: 'The sender Phone Number ID from the WhatsApp Business '
            'dashboard (used in request paths).',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'send_text',
        description:
            'Send a WhatsApp text message. body is the Graph API message '
            'JSON, e.g. {"messaging_product": "whatsapp", "to": "1555…", '
            '"type": "text", "text": {"body": "hi"}}.',
        method: 'POST',
        path: '/{phone_number_id}/messages',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
      RestToolDef(
        name: 'list_templates',
        description:
            'List message templates for the configured phone number id.',
        method: 'GET',
        path: '/{phone_number_id}/message_templates',
        inputSchema: {'type': 'object'},
      ),
    ],
  ),
];

/// Registers the comms batch: one [RestApiCapability] per descriptor in
/// [commsDescriptors] plus the draft-only [EmailDraftsCapability].
void registerComms() {
  registerRestServices(commsDescriptors);
  NativePluginRegistry.I.register(EmailDraftsCapability());
}

// ---------------------------------------------------------------------------
// Email Drafts (prompt capability: draft-only, sending is out of scope)
// ---------------------------------------------------------------------------

/// Returns the trimmed non-empty string for [key] or throws [ArgumentError].
String _requireArg(Map<String, dynamic> args, String key) {
  final value = args[key]?.toString().trim() ?? '';
  if (value.isEmpty) {
    throw ArgumentError('Missing required argument: $key');
  }
  return value;
}

/// Draft-only email composer (NP4 Task 3, spec §4.1): the model writes the
/// full email text from `to`/`subject`/`context`. Sending is explicitly
/// out of scope — the tool never sends email; the user sends the draft
/// themselves. No network, no secrets; execution lives in
/// `AgentService.runPromptTool` like every other prompt capability.
class EmailDraftsCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Email Drafts';

  @override
  String get taskSystemPrompt =>
      'You are an expert email writer. Draft a complete, send-ready email '
      '(subject line, greeting, body, sign-off) from the given recipient, '
      'subject, and context. Output the draft text only.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'draft',
          description: 'Draft a complete email (to, subject, context). '
              'Draft-only: this tool never sends email — the user sends '
              'the draft themselves.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'to': {'type': 'string'},
              'subject': {'type': 'string'},
              'context': {'type': 'string'},
            },
            'required': ['to', 'subject'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'draft') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final to = _requireArg(args, 'to');
    final subject = _requireArg(args, 'subject');
    final context = args['context']?.toString().trim() ?? '';
    return 'Draft an email to "${boundInput(to, maxInputChars)}" with '
        'subject "${boundInput(subject, maxInputChars)}".\n'
        'Context:\n'
        '${boundInput(context.isEmpty ? '(none provided)' : context, maxInputChars)}\n'
        'This tool does not send email — output the draft text only so '
        'the user can review and send it themselves.';
  }
}
