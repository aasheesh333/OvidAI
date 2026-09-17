# Native API Integrations & Remaining Utilities (NP4) Spec

**Date:** 2026-09-16
**Author:** opencode
**Status:** Approved for implementation (user waived review gates; rulings in NP4 ledger)
**Scope:** 45 external-service integrations (REST-curated) + 7 leftover NP2b utilities. OUT: `Puppeteer MCP` / `Postgres Tools` / `Playwright MCP` (already work via npx server mapping — verify-only), `MCP Server Hub` (management UI, working), `Screen Awareness` (needs composer attach-flow project — stays honestly unsupported with a note).

---

## 1. Executive Summary

Every remaining catalog row that names a real third-party service gets a real native backing. Rule agreed with user: **whichever integration asks for a key/secret, the user pastes it** (Configure sheet / `catalog_configure_plugin`); until then tools fail with an exact `configure <KEY> first` message — never a fake success.

Two mechanisms:
- **(A) Declarative REST descriptors** (bulk of NP4): one `RestServiceDescriptor` per service (base URL + auth scheme + credential fields + 2–4 curated tools). A single `RestApiCapability` engine executes them. Curated subsets, not full API coverage — the useful 20% per service.
- **(B) Special engines** (5): S3 SigV4 signer (pure Dart `crypto`), Redis RESP minimal client (dart:io Socket), MongoDB via Atlas Data API (plain HTTPS), Docker/K8s bearer-TCP/HTTPS with honest unavailability, Obsidian vault files (dart:io).
- **(C) Prompt patterns** (3, reuse `NativePromptCapability` — no new framework): LangChain MCP, AutoGPT Bridge, Email Drafts (draft-only; sending explicitly out).
- **(D) NP2b utilities** (7): QR Generator (`qr` pkg), SSH Key Manager (`cryptography` pkg), Mermaid Diagrams (validate + .mmd export + kroki render, honest offline note), Excalidraw Bridge (local .excalidraw JSON ops), Icon Library (Iconify search API, no key), Font Preview (Google Fonts API, no key), DB Designer — ALREADY DONE in NP2 (excluded), Audio Notes (Whisper transcription with user key).

New pubspec deps (both pure-Dart, no native code, no build impact beyond Dart compile): `qr`, `cryptography`. Everything else uses existing deps (`http`, `crypto`).

---

## 2. Framework Contract (`lib/core/native_plugins/rest_engine.dart`)

```dart
enum RestAuthKind { none, bearerHeader, apiKeyHeader, queryKey, basic }

class RestToolDef {
  final String name;
  final String description;
  final String method; // GET/POST/PUT/PATCH/DELETE
  final String path;   // '/channels.list' with {arg} substitution from args
  final Map<String, dynamic> inputSchema;
  final List<String> queryArgs; // arg names → URL query params
  final String? jsonBodyArg;    // arg name holding the JSON body map (else {})
  final List<String> required;
}

class RestServiceDescriptor {
  final String pluginName;      // seed-exact
  final String baseUrl;
  final RestAuthKind auth;
  final String? authHeader;     // e.g. 'Authorization', 'X-Figma-Token'
  final String authPrefix;      // e.g. 'Bearer ', 'token ', ''
  final String authQueryKey;    // for queryKey kind (e.g. 'api_key')
  final String credentialKey;   // config key holding the secret
  final String credentialLabel; // human label for the Configure sheet
  final List<NativePluginConfigField> extraConfig; // host/project/ids (non-secret)
  final List<RestToolDef> tools;
}

class RestApiCapability implements NativePluginCapability {
  RestApiCapability(this.descriptor, {http.Client? client});
  // configFields = [secret credential] + extras
  // callTool: creds missing → 'Configure <credentialLabel> first: ...'
  //   else substitute path, attach auth, http call (timeout_seconds,
  //   default 30, clamp 5..300), truncate 6000 + notice, non-2xx verbatim.
}
```

- `registerRestServices(List<RestServiceDescriptor>)` — one capability per descriptor; called per batch (`registerComms()`, `registerDevPlatforms()`, …) from `registerAllNativePlugins()`.
- Tests use `package:http/testing.dart` `MockClient` (established pattern) — never real network.
- Secret values NEVER appear in error strings (redact credential echoes; HTTP 401 body passes through — bodies don't contain our key).

---

## 3. NP2b Utilities (`lib/core/native_plugins/misc_utilities.dart` + `registerMiscUtilities()`)

- **QR Generator** (`qr` pkg): `generate(text, size=512, margin=4)` → PNG bytes base64 + byte count (cap input 2000 chars); `validate` honestly reports capacity overflow instead of truncating silently.
- **SSH Key Manager** (`cryptography` pkg): `generate(type=ed25519|rsa)` → OpenSSH `private` + `*.pub` text (returned, never stored unless `save` called); `save(name, private_pem)` / `get(name)` / `list()` via secure storage (vault pattern); `fingerprint(pub)` SHA-256.
- **Mermaid Diagrams**: `validate(text)` (balanced fences/braces, known diagram headers); `export(text, path?)` writes `.mmd` to sandbox-prefixed path? NO sandbox dep — return text + char count honestly (no file plumbing invented); `render(text)` → kroki.io POST, returns SVG text (network failure → honest message, offline note in description).
- **Excalidraw Bridge**: `stats(json_text)` (element counts by type); `add_text(json_text, text, x, y)`; `merge(a_json, b_json)`; all pure JSON ops, `FormatException` on malformed scene.
- **Icon Library**: `search(query, limit=20)` → Iconify API (`https://api.iconify.design/search?query=`), returns `prefix:name` hits + SVG URLs. No key. Failure → honest message.
- **Font Preview**: `search(query)` → Google Fonts list API (no key) family/style matches; `preview_url(family, text)` → fonts.googleapis css2 URL string (agent/user opens it). No binary download.
- **Audio Notes**: `transcribe(audio_url)` — NO local binary handling: posts the http(s)-reachable audio URL to Whisper `audio/transcriptions` with user `openai_api_key` (secret config); returns text. Honest scope in description (URL-based; on-device mic dictation already exists via Voice Input).

---

## 4. Service Catalog (all: base URL | auth | credential fields | curated tools)

Conventions: `timeout_seconds` on every tool (default 30, clamp 5..300); `{x}` path substitution from required args; 6000-char truncation; missing creds → `Configure <label> first…`.

### 4.1 Comms (`registerComms()`)

- **Slack Notify** | `https://slack.com/api` | bearer `Authorization: Bearer <bot_token>` (secret `bot_token`) | `send_message(channel, text)`, `list_channels()`, `history(channel, limit=20)`.
- **Discord MCP** | `https://discord.com/api/v10` | `Authorization: Bot <bot_token>` (secret) | `send_message(channel_id, content)`, `list_guilds()`, `list_channels(guild_id)`.
- **Discord Bot Builder** | same base/auth | `create_channel(guild_id, name, type?)`, `create_role(guild_id, name)`, `send_message(channel_id, content)`.
- **Telegram MCP** | `https://api.telegram.org` | path-segment `bot<bot_token>` (secret) | `send_message(chat_id, text)`, `get_updates()`, `get_me()`.
- **Twilio MCP** | `https://api.twilio.com/2010-04-01` | basic `<account_sid>:<auth_token>` (both secret-ish: sid non-secret field, token secret) | `send_sms(from, to, body)`, `list_messages(limit=20)`, `list_calls(limit=20)`.
- **Cal.com MCP** | `https://api.cal.com/v1` | queryKey `apiKey` (secret `api_key`) | `list_bookings()`, `list_event_types()`, `get_booking(id)`.
- **WhatsApp Bridge** | `https://graph.facebook.com/v21.0` | bearer `<access_token>` (secret) + extra `phone_number_id` | `send_text(to, body)`, `list_templates()`.
- **Email Drafts** | prompt capability (reuse framework): `draft(to, subject, context)` → full email text. Sending explicitly out (description says so).

### 4.2 Dev platforms (`registerDevPlatforms()`)

- **GitLab MCP** | `https://gitlab.com/api/v4` + extra `host` override | header `PRIVATE-TOKEN: <token>` (secret) | `list_projects(search?)`, `list_merge_requests(project_id, state?)`, `create_issue(project_id, title, description?)`.
- **Bitbucket MCP** | `https://api.bitbucket.org/2.0` | basic `<username>:<app_password>` OR bearer `<token>` (prefer bearer when `token` set) | `list_repos(workspace)`, `list_pullrequests(workspace, repo)`, `get_pullrequest(workspace, repo, id)`.
- **Jira MCP** | extra `host` (e.g. `https://x.atlassian.net`) | basic `<email>:<api_token>` | `search(jql, limit=20)`, `get_issue(key)`, `create_issue(project_key, summary, description?, issuetype=Task)`, `add_comment(key, body)`.
- **Trello MCP** | `https://api.trello.com/1` | queryKey `key`+`token` (secret `api_token`, non-secret `api_key`) | `list_boards()`, `list_lists(board_id)`, `list_cards(list_id)`, `create_card(list_id, name, desc?)`.
- **Linear Sync** | `https://api.linear.app/graphql` | header `Authorization: <api_key>` (secret) | `list_issues(limit=20)`, `create_issue(team_id, title, description?)`, `list_teams()`. POST GraphQL via jsonBody.
- **Figma Bridge** | `https://api.figma.com/v1` | header `X-Figma-Token: <token>` (secret) | `get_file(file_key)`, `get_comments(file_key)`, `post_comment(file_key, message)`.
- **Sentry Watch** | `https://sentry.io/api/0` | bearer `<auth_token>` (secret) | `list_issues(org, project?, limit=20)`, `get_issue(id)`, `latest_event(issue_id)`.
- **Exa Search MCP** | `https://api.exa.ai` | header `x-api-key: <api_key>` (secret) | `search(query, num_results=5)`, `contents(ids, text=true)`.

### 4.3 Backend & data (`registerBackend()`)

- **Firebase MCP** | `https://firestore.googleapis.com/v1` | queryKey `key` (`api_key` secret) + extras `project_id` | `get_document(path)`, `list_documents(collection)`, `create_document(collection, fields_json)`, `patch_document(path, fields_json)`, `delete_document(path)`. Scope note: Firestore only.
- **Supabase MCP** | extra `base_url` | headers `apikey` + `Authorization: Bearer` (same secret `service_key`) | `select(table, query?)` (query map → params), `insert(table, row_json)`, `update(table, query, patch_json)`, `delete(table, query)`.
- **Airtable MCP** | `https://api.airtable.com/v0` | bearer `<token>` (secret) + per-call `base_id` | `list_records(base_id, table)`, `create_record(base_id, table, fields_json)`, `update_record(base_id, table, record_id, fields_json)`, `delete_record(base_id, table, record_id)`.
- **Appwrite MCP** | extra `endpoint` | headers `X-Appwrite-Project` (non-secret `project_id`) + `X-Appwrite-Key` (secret) | `list_documents(db_id, collection_id)`, `create_document(db_id, collection_id, data_json)`, `list_users()`.
- **PocketBase MCP** | extra `base_url` | bearer static `token` (secret, user-pasted admin/user token) | `list_records(collection, page=1)`, `create_record(collection, data_json)`.
- **Vector DB MCP** | extra `index_host` | header `Api-Key: <api_key>` (secret) | `query(vector_json, top_k=5)`, `fetch(ids)`, `stats()`.
- **MongoDB MCP** | extra `data_api_base` + `api_key` (secret) + `data_source` | `find(db, coll, filter_json?, limit=20)`, `find_one(...)`, `insert_one(db, coll, doc_json)`. Honest scope: Atlas Data API only (self-hosted wire protocol unsupported — description says so).
- **S3 MCP** | SigV4 engine, extras `region` + `bucket`, secrets `access_key_id` + `secret_access_key` | `list_objects(prefix?)`, `get_object(key)` (UTF-8 text under cap else metadata), `put_object(key, text)`, `delete_object(key)`, `presign_get(key, expires=3600)` (pure signing, no network).
- **Redis MCP** | RESP engine, extras `host` (default 127.0.0.1?) — default `localhost`, `port` default 6379, `password` secret optional | `get(key)`, `set(key, value, ex_seconds?)`, `del(keys)`, `keys(pattern)`, `incr(key)`, `expire(key, seconds)`. Unreachable → honest message.
- **Obsidian MCP** | file engine, extra `vault_root` (non-secret dir path) | `list_notes()`, `read_note(path)`, `write_note(path, text)`, `append_note(path, text)`, `search_notes(query)`. Root-injectable for tests; refuses paths escaping root.

### 4.4 Deploy & infra (`registerInfra()`)

- **Vercel MCP** | `https://api.vercel.com` | bearer `<token>` (secret) | `list_projects()`, `list_deployments(project_id?, limit=20)`, `get_deployment(id)`, `list_domains()`.
- **Vercel Deploy** | same | + `create_deployment(project, git_repo, branch=main)`, `cancel_deployment(id)`.
- **Railway MCP** | `https://backboard.railway.app/graphql/v2` | bearer `<token>` | `list_projects()`, `list_services(project_id)`, `list_deployments(service_id, limit=20)`.
- **Heroku MCP** | `https://api.heroku.com` | bearer + `Accept: application/vnd.heroku+json; version=3` | `list_apps()`, `get_app(id)`, `list_dynos(app_id)`, `restart_dynos(app_id)`, `get_config(app_id)`.
- **DigitalOcean MCP** | `https://api.digitalocean.com/v2` | bearer `<token>` | `list_droplets()`, `get_droplet(id)`, `list_domains()`, `list_domain_records(domain)`.
- **Cloudflare MCP** | `https://api.cloudflare.com/client/v4` | bearer `<token>` | `list_zones()`, `list_dns(zone_id)`, `create_dns(zone_id, type, name, content)`, `delete_dns(zone_id, record_id)`.
- **Docker MCP** | extra `docker_host` (default `tcp://localhost:2375`) | none (optional `api_version` path prefix `v1.43`) | `list_containers(all=true)`, `list_images()`, `inspect_container(id)`. Unreachable daemon → honest message (no daemon invented).
- **Kubernetes MCP** | extras `api_server` + `namespace` (default `default`), secret `bearer_token` | `list_pods()`, `list_deployments()`, `list_services()`, `get_pod(name)`, `pod_logs(name, tail=100)`. Honest scope: bearer-token clusters only (client-cert clusters unsupported — message says so).
- **Terraform MCP** | `https://app.terraform.io/api/v2` | bearer `<token>` (secret) | `list_workspaces(org)`, `list_runs(workspace_id)`, `create_run(workspace_id, message?, auto_apply=false)`. Honest scope: Terraform Cloud API (local CLI not driven).
- **Zapier MCP** | webhook engine, secret `webhook_url` | `trigger(payload_json)` (POST), `trigger_with_url(url, payload_json)`.
- **Make.com MCP** | extra `zone_base` (default `https://eu1.make.com/api/v2`) | header `Authorization: Token <token>` (secret) | `list_scenarios()`, `run_scenario(id, payload_json?)`.

### 4.5 AI, media & productivity (`registerAiMedia()`)

- **OpenAI DALL·E MCP** | `https://api.openai.com/v1` | bearer `<openai_api_key>` | `generate_image(prompt, size=1024x1024)` → returns image URL (no binary handling); `list_models()`? (skip — keep image-only + honest scope).
- **ElevenLabs MCP** | `https://api.elevenlabs.io/v1` | header `xi-api-key: <api_key>` | `list_voices()`, `speak(text, voice_id?)` (input capped 2000 chars; returns base64 mp3 + byte count, honest about size).
- **Notion Sync** | `https://api.notion.com/v1` | bearer + `Notion-Version: 2022-06-28` | `search(query)`, `query_database(db_id, filter_json?)`, `create_page(parent_id, title, text?)`, `get_page(id)`.
- **Google Drive MCP** | `https://www.googleapis.com/drive/v3` | bearer user OAuth `<access_token>` (secret; description explains pasting a token) | `search(query, limit=20)`, `get_file(id)`, `download_text(id)` (text-capped, honest on binary), `upload_text(name, text, folder_id?)` (multipart).
- **Stripe MCP** | `https://api.stripe.com/v1` | bearer `<secret_key>` (form-encoded bodies!) | `list_customers(limit=10)`, `list_invoices(limit=10)`, `list_charges(limit=10)`, `create_invoice(customer_id, description?, amount_cents?, currency=usd)`. NOTE: Stripe needs `application/x-www-form-urlencoded` — engine supports `formBodyArg` variant.
- **YouTube Summarizer** | oEmbed `https://www.youtube.com/oembed` (no auth) + page fetch | `get_details(url)` → title/author/description text (honest: no captions track — model summarizes from metadata+description; message says so when thin).
- **LangChain MCP** | prompt capability: `chain_design(task)` → LCEL blueprint; `agent_plan(goal)` → agent+tools plan. No creds.
- **AutoGPT Bridge** | prompt capability: `decompose(goal)` → structured sub-agent delegation plan (outer model executes via subagents).

---

## 5. Verification Plan

- `test/native_plugins_rest_test.dart` (framework TDD): descriptor→tools, path substitution, auth injection per kind, missing-cred message (assert secret value absent from message), non-2xx verbatim, timeout default/override, truncation, form-body variant, SigV4 Authorization header shape (fixed test vector), RESP encode/decode round-trip against loopback fake server, Obsidian root-escape refusal.
- Per-batch tests (`rest_comms_test`, `rest_dev_test`, `rest_backend_test`, `rest_infra_test`, `rest_aimedia_test`, `misc_utilities_test`): MockClient canned responses per tool (status/headers/body assertions on the REQUEST side — assert URL, method, auth header present, secret correct); honest-message tests for missing creds; error passthrough.
- Roster halves for 2+ services per batch (installed+enabled ↔ `plugin__slack_notify__send_message` etc.).
- Gates: `dart analyze lib test` 0 issues; full `flutter test` green (only known pre-existing PR13 excepted).
