# Prompt caching

Long agent sessions resend system prompt, tool schemas and history every turn.
Prompt caching makes the unchanged prefix cheap (reads cost about 0.1x input)
and faster (lower time to first token).

## What the app does (`lib/core/prompt_cache.dart`)

Stable prefix, for every provider unless caching is switched off:
- Tools are sorted by name and serialised with sorted keys, so plugin or MCP
  load order never changes the bytes.
- Volatile content (memory, todos, goal, clock, reminders) is tagged and sits
  after the history, never in the system prefix. On Anthropic-native requests
  such rows are sent as a user turn instead of being merged into `system`.
- After a compaction the checkpoint block sits right after the system prompt
  and is deterministic, so the next turn's prefix is stable again. The
  compaction itself rewrites the prefix once (one cache write).

Markers (`cache_control: {type: "ephemeral"}`), at most 4 per request:
1. last tool definition (Anthropic native, Ovid Cloud; not OpenRouter)
2. end of the system prompt (also covers the tools before it)
3. last message of the request (extends the cached prefix each turn)
4. end of stable history, before memory/volatile rows (next run still hits)

| Provider / model | Behaviour |
| --- | --- |
| Anthropic native (`/v1/messages`, API format Anthropic) | markers on tools, system, rolling messages |
| Ovid Cloud, Claude models | content-block markers via LiteLLM, tools included |
| OpenRouter, Claude models | content-block markers on system and messages |
| Ovid Cloud / others: GPT, Gemini, DeepSeek, Kimi, GLM, Grok | no markers, provider caches the stable prefix itself |
| BYOK custom OpenAI-compatible endpoint | no markers by default; stable ordering only |

Subagents run the same loop: they share the stable ordering and breakpoint
logic, but their system prompt and tool roster differ from the parent's
(spawn tools are removed), so they do not read the parent's cache.

## Settings

- Settings > Prompt caching > Cache the prompt prefix (default ON). Off sends
  the legacy request: no sorting, no markers.
- Settings > Prompt caching > Extended 1-hour cache (default OFF). Adds
  `ttl: "1h"` to every marker. Cache writes cost 2x base input instead of
  1.25x; reads stay 0.1x. Use it when pauses between turns exceed 5 minutes
  (24/7 sessions); otherwise the default 5 minutes is cheaper.
- Provider settings > Prompt caching: Auto / On / Off per provider. Auto only
  enables markers where the endpoint is known to accept them. On forces
  Claude-style markers for a custom proxy; Off never sends them.

## Reading hit rates

- Session analytics sheet: "Cached: X% of input tokens" and the status line
  "cached X%". X = cache-read tokens / total input tokens, accumulated over
  the session.
- Usage fields recognised: Anthropic `cache_read_input_tokens` /
  `cache_creation_input_tokens`; OpenAI `usage.prompt_tokens_details.cached_tokens`;
  LiteLLM and OpenRouter variants (`cache_creation_tokens`, `cache_write_tokens`);
  DeepSeek `prompt_cache_hit_tokens`.
- Local cost is an estimate: Claude reads 0.1x, writes 1.25x (5m) or 2x (1h);
  DeepSeek reads 0.1x; Gemini and GPT-4.1/5 reads 0.25x; others 0.5x. The
  server (LiteLLM spend) stays authoritative.
- Expect 0% on the first turn, and one cache write after each compaction or
  system prompt change. A healthy long session sits at 80-95%.
- Anthropic only caches prefixes above 1024-4096 tokens (model dependent).

## Server side (not applied)

- `ops/prompt-caching/litellm-cache-injection.yaml`: `cache_control_injection_points`
  for the Claude models, so clients without markers also benefit. Models live
  in the gateway database, so apply it through the LiteLLM admin UI or
  `/model/update`. The Redis exact-match response cache does not help growing
  conversations.
- `ops/prompt-caching/verify_cache.py`: sends one >4k-token prefix twice and
  prints cache_creation / cache_read tokens and the cost delta.

```
OVID_BASE_URL=https://<gateway>/v1 OVID_API_KEY=<key> \
  python3 ops/prompt-caching/verify_cache.py --model claude-sonnet-4.6 [--ttl 1h]
```
