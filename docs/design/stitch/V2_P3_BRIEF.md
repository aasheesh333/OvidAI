# P3 one-shot brief (read before touching code)

Worktree: `/root/.local/share/opencode/worktree/d5f2a3/ovid-si-rebuild`.
The rebuilt **UI v2 is now the default** in `lib/main.dart`; the legacy shell is
only reachable with `--dart-define=OVID_UI_V1=true`. Do **not** add new legacy
screens or route the v2 shell back to Aether screens.

## Product truth

- Ovid Si = always-on personal SI agent + coding specialist, with a main agent
  and up to **50** subagents per session. Subagents never dispatch subagents.
- Each session is 100% isolated. `@` mentions another session to read/continue
  it; sharing is opt-in. Every session has an auto-maintained `.md` memory, and
  there is a global memory plus one per project.
- Studio: connect GitHub (PAT or OAuth) → pick repo → pick branch → clone to the
  cloud workspace. Messaging in Studio is blocked until a folder is picked.
  Token never lands in `.git/config`; ephemeral credential helper only.
  `git fetch && git status` before a task; "Sync latest changes" chip when
  behind.
- Browser: only the agent opens the first tab; the user cannot add tabs. Live
  view 3–5 fps; after 45 s closed it goes headless; "Take control" for
  human-like input (mouse/typing), plus upload/download.
- Subagent contract: full log at `/workspace/.ovid/logs/subagent_{id}.log`;
  main agent receives only a strict 300-token JSON
  (`status, files_modified, artifacts_created, key_findings, error_if_any`);
  the main agent may `@subagent_id` to read the log. Max 8 h per subagent.
- Queue: while the main agent works, new messages queue; Stop sends the queued
  message immediately. Dispatched subagents keep running.
- Plans: Free $0/3 GB/Auto only/50M tokens per 24 h/1.5B per 30 d; Go $5 or
  ₹499/5 GB/Auto only; Plus $18 or ₹1,799/15 GB/manual models; Pro $99 or
  ₹9,999/75 GB/manual models. Manual models are greyed out on Free/Go.
- Free/Go auto-only; Plus/Pro manual. Custom connectors: Free none, Go 5,
  Plus/Pro 20. Ovid never installs plugins/MCP from chat.
- Share: Collab (max 50, one sender at a time, creator pays storage) or
  Read only (viewer can fork into their own account).
- Account: Google or phone sign-in only; delete account has a 24 h grace period
  and cancelling means signing in again and restoring.
- Theme follows the device (light fallback); both themes first-class.

## Hard rules

1. **Only touch the files listed in your task.** No shared files, no
   `lib/main.dart`, no `lib/ui/design/*`, no `pubspec.yaml`, no routes unless
   your task says so. No commits.
2. Screens stay **presentational**: inject immutable data + callbacks. No
   `AppState`/network/Firebase imports inside `lib/ui/v2/<screen>` pages (the
   live adapters in `lib/ui/v2/app/` own that).
3. Light + dark, 320 dp at 200 % text, 48 dp targets, semantic labels, disabled
   states announced, `TODO(l10n)` on new copy, motion via `OFadeSlide`/
   `OStagger`.
4. Every list gets loading / empty (with next action) / error (with retry) /
   content.
5. Keep existing tests green. Add tests for what you add.

## Commands

```bash
export PATH=/root/flutter/bin:$PATH
flutter test <your tests>
flutter analyze <your files>
```

Server/cloud work: run the package tests shown in your task.

## Report

`.superpowers/sdd/2026-10-21-ovid-si-rebuild/reports/p3/<slug>.md` with status,
files, test/analyze output, and concerns. Return the same in your final message.
