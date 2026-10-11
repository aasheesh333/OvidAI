# Lossless compaction

Owner requirement: *"Compaction must not forget the session's context — what
the user gave and what the agent did."*

## Behaviour before this change

- **Where it lives.** `AgentService` (`lib/core/agent_service.dart`):
  `_maybeCompact` / `_maybeCompactLocked` (auto), `compactNow` (`/compact`),
  `forceCompact` (when the provider rejects a request as too long),
  `_summarizeCompactSpan` (the LLM call), `_applyCompaction` (writes state plus a
  visible row). State is `ChatSession.compactedSummary` and
  `ChatSession.compactedAtCount` (`lib/core/state.dart`). The row is
  `_CompactionRow` in `lib/ui/chat_screen.dart` (collapsed, "View summary").
- **Trigger.** Before each run, and every 12 turns inside the loop (the budget
  boundary), it compacts when measured tokens (the last billed `promptTokens`,
  or chars/4) reach `min(80% of window, 100k)`. It first spills oversized tool
  output. It keeps the newest ~16% of the window verbatim (`/compact`: the
  newest 24 messages or 8k tokens).
- **Summary.** One LLM call condenses the span into 8 markdown sections. The
  model is told to "merge, don't copy forward" the prior checkpoint, and that
  prior checkpoint is the previous *LLM output*.
- **Request assembly.** `buildRequestMessages` sends the system prompt (plan
  mode, working folder, AGENTS.md), then the checkpoint as a user message, then
  the replay after the checkpoint, then memory, then the volatile block (goal
  and todos). This is rebuilt for every request.
- **Visible transcript.** Folded messages stay in `s.messages`. Only the request
  skips them, so the visible history is already kept.

## Gaps

1. **User context depended entirely on the LLM.** The original goal, the
   user's constraints and corrections, attachments and pasted references
   survived only if the summariser chose to keep them.
2. **The agent's work was only in prose.** Files created, edited or deleted,
   commands with their exit codes, errors, subagent and MCP use: nothing was
   derived deterministically. A file path the model left out was gone.
3. **Repeated compactions got worse each time.** Each run summarised a
   summary, so detail drained away with every compaction.
4. **A summariser failure kept nothing.** The span was not folded, so the
   next request overflowed again. On the overflow path, `forceCompact`
   recovered nothing.
5. **`/compact <focus>` was ignored.** The args were never read.
6. **The cut point ignored turn structure.** It could split a user turn from
   its tool and answer run.
7. **Volatile state went stale after a rebuild.** A rebuild mid-run reused the
   todo and goal block captured when the run started.
8. **The row showed only LLM prose.** It said nothing about what was
   guaranteed to be kept.

## New design (`lib/core/compaction/`)

- `compaction_ledger.dart` holds `CompactionLedger`, a cumulative,
  JSON-persisted record (`ChatSession.compactionState`):
  - every user message verbatim, plus its attachments
  - the original goal, which is the first user message
  - a chronological work log built from the tool cards: tool name, input
    (`Message.toolInput`, recorded at dispatch), outcome or exit code,
    error line
  - file operations (created, edited, deleted, read)
  - errors and what fixed them
  - `/compact` focus texts
  - the latest LLM narrative

  Each compaction folds only the new span into the stored ledger, so the
  ledger only grows. The deterministic sections are never re-summarised.
- `compaction_renderer.dart` renders the checkpoint as these sections: Goal ·
  User instructions & constraints (verbatim) · Facts/data the user provided ·
  Files & artifacts · Actions taken · Decisions · Errors & fixes · Current
  state/todos · Next steps · Narrative. It works inside a token budget scaled
  to the window:
  - all user messages stay verbatim when they fit
  - otherwise the goal plus the newest messages stay verbatim, and older ones
    become a faithful digest. Short messages and every
    constraint/correction sentence are kept verbatim, and long pastes become
    references.
  - the full file list always fits; older read-only actions collapse into
    counts first
- `compaction_policy.dart` picks the cut point so the retained tail starts at
  a user-turn boundary. It never cuts before a tool card or a running tool, so
  a call and its result are never separated.
- The LLM now writes **only the narrative** (Decisions / Current work / Next
  steps / Key context). It is given the prior narrative to merge, plus the
  user's focus text. If it fails or returns nothing, the checkpoint keeps the
  deterministic sections and carries the previous narrative forward.
- Persistent context (memory, AGENTS.md, plan mode, working folder, goal,
  todos) is still re-attached live on every request. The volatile block is
  now rebuilt whenever the request is rebuilt after compaction. A snapshot of
  that state also goes into the checkpoint's "Current state" section.

## Limits

- The digest of older user messages uses a heuristic. It keeps sentences
  containing directive or correction cues (must, never, always, don't, only,
  prefer, instead, actually, wrong, use, avoid, …) plus paths and URLs. Other
  prose in *long* old messages is shortened to its first sentence. This only
  happens after the user-message budget is exhausted.
- Tool cards written before this change have no `toolInput`. For those, the
  inputs come from `toolSummary` and the diff header.
- Sessions that are loaded only as a tail (bootstrap) compact only what is in
  memory. The ledger carried forward keeps everything that earlier compactions
  saw.
- When the user section exceeds twice its budget, older messages outside the
  recent window are shown as digest rows. A digest row keeps the first
  sentence, every directive sentence and every fact-like sentence (digits or
  `key: value`), plus paths and URLs. Messages of 160 chars or fewer stay
  verbatim either way. The checkpoint can therefore grow beyond its nominal
  budget on very long sessions, because instructions are never dropped. On
  tiny windows (below ~16k tokens) this can trigger another compaction sooner.
- The action log collapses entries by priority: replies first, then reads,
  then successful shell/other actions, then successful writes. Every touched
  path stays in "Files & artifacts". Failures, subagent and MCP calls, and VCS
  actions are never collapsed.
