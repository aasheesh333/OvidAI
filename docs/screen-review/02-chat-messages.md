# 02 — Chat screen part 2 (messages, composer, sheets, artifacts)

## Scope
- `lib/ui/chat_screen.dart` L4500–8970 (message bubbles + actions, markdown, image messages + full-screen viewer, attach sheet, image-prompt dialog, `_InputBar` composer, @-mentions, goal editor, working-folder sheet, inline approval/question cards, control-mode consent dialogs)
- `lib/ui/html_artifact_view.dart` (artifact view)
- Calls followed into `lib/core/` where needed to confirm a bug.

## Goal
Actionable fix plan for a ~10M DAU Android app: bugs, missing states, UX/a11y/perf, security, missing must-have features vs ChatGPT/Claude mobile, and Claude Code MCP/plugin parity gaps visible here. Known context not re-reported: per-token streaming rebuild storm (branch `perf/streaming-rebuilds`).

## Status
in progress

