# 01 — Chat screen part 1 (chat core)

## Scope
- `lib/ui/chat_screen.dart` L1–4500 (ChatTranscript, ChatScreen state/build, app bar, model picker sheet, session stats / context meter sheets, background jobs sheet, mode/preset sheets, tool cards, diff viewer, produced files sheet)
- `lib/ui/transcript_model.dart`
- `lib/ui/chat_layout.dart`

## Goal
Read every line of the above in full, find functional bugs, missing states, UX/a11y/perf defects, UI-visible security issues, and gaps versus ChatGPT / Claude mobile and Claude Code MCP/plugin parity. Each finding cites file:line and gives a concrete fix.

Known context (not re-reported): per-token streaming rebuild storm and `_ChatTextScaler` equality (branch `perf/streaming-rebuilds`); model catalog 503 recovery (branch `fix/model-catalog-recovery`).

## Status
in progress

