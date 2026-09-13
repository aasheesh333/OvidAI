# Token Efficiency (No-Folder) — Design

**Date:** 2026-09-13
**Status:** Approved for implementation.

## 1. Goal

Cut the fixed per-request token cost so sending a message with **no workspace
folder selected** does not consume disproportionately many tokens.

## 2. Outcomes

1. The per-request payload (system prompt + tool schemas + skills catalog) is
   materially smaller, especially with no folder.
2. Read-only/simple modes do not carry tools they cannot use.
3. Measured before/after token counts are recorded.

## 3. Non-Goals

- Changing provider pricing or model routing.
- Removing capabilities the user relies on.

## 4. Current Failure Model (evidence)

- `_tools` (`agent_service.dart:2985-3190`) always builds the full roster
  (core + plugin + canonical + memory + repo + MCP + stubs); `_coreTools`
  (`:3193-5018`) holds ~87 definitions sent on **every** request
  (`_callLlm` `:6956-6957`). No mode gate.
- `estimateMessageTokens` is `length ~/ 4 + 4` (`:5310`); the fallback usage
  path counts only messages, not tool schemas (`:6336-6341`).
- With no folder, the system prompt is only ~2 lines different
  (`:6129-6135`); the cost is the fixed roster + catalog.

## 5. Design

- Add a mode/preset-aware tool gate so read-only and simple sessions send only
  the tools they can use (device tools only in control, browser tools only when
  the browser is relevant, etc.).
- Trim redundant/legacy tool schemas and duplicated definitions.
- Measure the token delta with a scripted payload dump; record it in the audit.
- Keep behavior identical for tools that are exposed.

## 6. Testing

- Unit: tool-roster gate returns the expected set per mode.
- Measurement: payload token estimate before/after (recorded).
- Full `flutter test` + `flutter analyze` green.

## 7. Decisions

- Gate tools by mode/relevance rather than always sending all.
- No capability is removed for modes that legitimately use it.
- Honest measurement, not estimates presented as exact.
