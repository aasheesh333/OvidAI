# Personal and session memory

Settings → **Memory files** opens the plain-text Markdown editor. It supports
view/edit/save, adding files, and importing `.md`. The scope selector uses the
chat that was active when the screen opened. Global personal memory is local to
this app installation and intentionally shared across the user's chats; it is
not cloud/account synchronization.

## Canonical storage and ownership

- `<application documents>/personal-memory/global/MEMORY.md`
- `<application documents>/personal-memory/session-<SHA256(root chat ID)>/MEMORY.md`
- Related Markdown files live beside each entrypoint. An absent entrypoint reads
  as empty and is materialized on first save.
- The persisted `ChatSession.parentId` chain determines the root owner. A root
  and its descendant agents share one session-memory scope. Other roots cannot
  read or write it. Missing parents and cycles fail closed.
- Neither **Share session memory** (transcript search) nor P2's explicit
  `@session` transcript grants grant access to another root's Markdown memory.
  The `wt-agents` P2 lineage changes were inspected; this work uses the existing
  parent chain and does not require copying those changes.
- Deleting a root schedules removal of its memory alongside descendant cleanup;
  deleting a child preserves the owning root's shared memory. Delete all data
  removes all personal-memory scopes.

The previous `ovid_memories` snippets are migrated into deterministic, packed
`legacy-<content digest>.md` files. Migration never replaces `MEMORY.md` or an
existing edited file. The legacy key is removed only after every chunk is saved;
conflicts or capacity failures preserve the original data and report an error.
Native MCP Memory remains the existing independent **per-server knowledge graph**
(`mcp-memory/*.json`); it is not a second copy of personal Markdown memory.

## Agent interface

All calls use the running session, not the foreground tab.

```json
{"tool":"memory_read","scope":"global","file":"MEMORY.md"}
{"tool":"memory_save","scope":"session","content":"Project fact","mode":"append"}
{"tool":"memory_save","scope":"global","file":"preferences.md","content":"...","mode":"create"}
{"tool":"memory_save","scope":"global","file":"MEMORY.md","content":"...","mode":"replace","revision":"<from memory_read>"}
```

`scope` is mandatory (`global` or `session`). `file` defaults to `MEMORY.md`;
save mode defaults to `append`. `create` refuses filename collisions, including
case-only collisions. `replace` requires the SHA-256 content revision returned
by `memory_read`. Stale UI saves and stale agent replacements fail visibly.
`memory_read` includes the file index and pages at most 8,000 characters using
`offset`/`limit` and `next_offset`. Arbitrary session IDs and paths are rejected.
`memory_search` searches the canonical global + owning-chat files, then retains
the existing transcript search behavior governed by the sharing toggle.

The shared request builder supplies global + owning-chat entrypoints and a file
index as **user-role background data**, before current conversation history.
The total memory context is capped at 16,000 characters, with independent
entrypoint budgets; extra files are read on demand. It explicitly defers to
system/developer instructions and the current user request. Main agents and
children use the same builder, including compaction/overflow rebuilds.

The Memory toggle controls automatic context and all three personal-memory tools.
Read-only/plan policy permits reads and blocks saves according to the existing
policy. The editor remains available when agent memory is disabled.

## Bounds and save behavior

- 32 files per scope, including `MEMORY.md`; 32 KiB UTF-8 per file.
- ASCII plain `.md` names, at most 80 characters; no separators, absolute paths,
  dotfiles, traversal, or symlinked roots/scopes/files.
- App-isolate saves perform revision checking and a same-filesystem atomic
  rename synchronously, with a flushed staged file in an exclusive temporary
  directory. Failed validation leaves the old file intact.
- Imports are bounded reads and always create a file. Importing `MEMORY.md`
  suggests `imported-memory.md` so it cannot silently replace the entrypoint.
- Imported HTML/script text is displayed in a `TextField`, never a WebView or
  executable HTML renderer. Leaving or switching away from dirty text asks
  whether to discard it.

Tests: `memory_store_test.dart`, `memory_agent_test.dart`, and
`memory_screen_test.dart`; existing MCP isolation, plan-policy and session
persistence suites cover adjacent integration.
