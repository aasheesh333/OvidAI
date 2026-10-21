# Ovid Si — complete product spec (v2)

Status: binding for the rebuild. The implementation plan argues from this file.
Anything not listed here is out of scope for v2.

## 1. Product

**Ovid Si — Your always-on personal Si agent. Chat. Code. Create.**

A thin Android client over a cloud agent runtime. The agent keeps working when
the phone is asleep; push notifications wake the client to show results. There
is no on-device model and no on-device workspace.

Pillars:

1. **One place to ask** — chat is the home screen, not a feature tab.
2. **Work continues** — runs are detached, queued, scheduled and observable.
3. **Nothing leaks** — every session is isolated; the user never sees a
   provider key or a cloud base URL.
4. **Plain language** — an educated user and a first-time smartphone user can
   both finish every flow without jargon.

## 2. Personas and accessibility

- **Aarav, 24, developer** — Studio, GitHub, diffs, preview.
- **Meera, 38, small-business owner** — schedules, artifacts, sharing; never
  opens Studio.
- **First-time smartphone user** — voice-first, large text, Hindi/Punjabi/Tamil.
- **Low-end device** — 2 GB RAM, 60 Hz; motion must stay under 16 ms/frame.

Requirements: 48 dp targets, WCAG AA body contrast, TalkBack labels on every
icon-only control, system text scaling to 200 % without clipping, reduced-motion
support, high-contrast mode, light/dark/system theme (system default, light
fallback).

## 3. Information architecture

```
Home / Chat
├── Sidebar drawer
│   ├── Profile + plan
│   ├── New chat
│   ├── Search
│   ├── Pinned
│   ├── Projects
│   ├── Sessions (Today / Yesterday / Earlier)
│   └── Footer: Schedule · Artifacts · Settings
├── Studio (repo-bound workspace)
├── Browser (agent-owned tabs)
└── Overflow: rename, share, export, delete, report
```

## 4. Chat

### 4.1 Top bar

`☰` · model chip (`Auto ⌄`) · `Ovid Si` · spacer · Studio · Browser · `⋮`.

- The model chip is immediately after the hamburger (founder decision D2).
- The chip opens a compact menu; the sheet version is used from Settings.
- Studio/Browser are icon buttons with labels for TalkBack.

### 4.2 Composer

`+` attach · permission chip (`General`, `Read only`, `Auto`) · Studio chip when
bound · spacer · mic · send (stop while running).

- Send is disabled on empty input, while offline, and when the plan window is
  exhausted; the reason is always visible as helper text.
- Enter inserts a newline; the send button submits.
- Drafts survive process death (existing `ComposerDraftStore`).
- Attachments: camera, gallery, file; 50 files/day free, 80 files/3 h paid.
- Voice: Hindi, Hinglish, Punjabi, Tamil; the locale follows the app language
  and can be overridden per message.

### 4.3 Message stream

- User bubble right, assistant left, markdown with code fences, copy per block.
- Tool cards show a human label ("Browsing the web"), progress and a stop.
- Thinking is collapsed by default; "Show reasoning" in Settings expands it.
- Artifacts render as cards with preview, download and open.
- Errors are plain: "Ovid could not finish this run" + Try again.
- A run shows: queued → working → done/failed/stopped, with elapsed time.

### 4.4 Queue and stop

- A message sent while a run is active is **queued**, shown above the composer.
- The queue runs automatically when the active run finishes.
- **Stop** cancels the active run and immediately sends the queued message.
- Multiple queued messages preserve order; the user can edit or remove them.

### 4.5 Empty state

Headline "What should we build today?", subtitle, three suggestion cards, a voice
CTA and the remaining allowance line. Never a blank screen.

## 5. Sessions, projects, memory

- **100 % isolation.** A session may read only its own workspace, files,
  transcript and memory unless the user explicitly `@`-mentions another session
  or enables share-session-memory.
- `@` mention autocomplete lists sessions and projects; the referenced
  transcript is injected read-only for that turn and is visible in the composer
  as a chip.
- **Per-session memory**: `/workspace/.ovid/memory/{sessionId}.md`, written
  automatically after each turn, capped at 32 KB; the user can view and edit it.
- **Project memory**: shared by sessions in the same project; merged after
  global, before session.
- **Global memory**: user-level facts; toggled in Settings → Memory.
- **Share session memory** toggle: off by default; when on, the session's memory
  is readable by project sessions.
- **Share chat** creates a read-only link; recipients can fork it into their own
  account. Shared chats never include files, connectors or memory unless the
  creator explicitly includes them.
- Pinning, renaming, moving to project, duplicating, exporting markdown and
  deleting are available from the session row and the chat overflow.
- Deletion removes messages, workspace files, memory and artifacts; the UI says
  so before confirming.

## 6. Sidebar

Order is fixed: profile/name/plan → New chat → Search → Pinned → Projects →
Sessions (Today / Yesterday / Earlier) → footer Schedule · Artifacts · Settings.
It is a drawer below 900 dp and a rail at or above it. Search filters locally
first, then server-side.

## 7. Studio

- Connect GitHub with OAuth (preferred) or a personal access token (advanced).
- Pick a repository, then a branch; the default branch is preselected.
- Clone into the session's cloud workspace. **The user must pick a folder
  before the composer allows a Studio message.**
- Repo and branch can be changed later; uncommitted work is stashed with a
  clear notice.
- `git fetch && git status` runs on open and on focus; if the remote moved, a
  one-click **Sync latest changes** banner appears before any write.
- Git credentials are ephemeral: `GIT_ASKPASS` + env injection, mode 0700,
  deleted after the command. The token is **never** written to `.git/config`.
- File tree, editor, changes/diff, commit & push, and **Live Preview**.
- Live Preview is served through the gateway proxy to a port inside the
  session's sandbox. No tunnel. The preview URL is short-lived and scoped to
  the session.
- If the repo is private and the token lacks scope, the error names the missing
  permission in plain language.

## 8. Browser

- The agent opens the first tab; **the user cannot open tabs** (the plus is
  disabled with "Ovid opens tabs").
- The viewer streams at 3–5 fps with a "watching live · 4 fps" indicator.
- **Take control** pauses the agent for 5 minutes; keyboard and trackpad are
  available; a countdown is always visible.
- Closing the viewer for 45 seconds puts the browser in headless mode; the run
  continues and the user is notified.
- Downloads and uploads are supported; a download appears in Artifacts.
- The agent drives like a human: scroll, hover, type with delays, no parallel
  clicks. Destructive actions require approval.
- Per-host consent on first navigation; cookies are names-only unless approved.

## 9. Agents and subagents

- Up to **50 concurrent subagents per session**.
- **Subagents cannot dispatch subagents.** Enforced in the runtime, shown in UI.
- Each subagent writes its full log to
  `/workspace/.ovid/logs/subagent_{id}.log` and returns only a strict
  ≤300-token JSON summary:
  `{status, files_modified, artifacts_created, key_findings, error_if_any}`.
- A subagent may be active for at most **8 hours**; at the cap it is stopped and
  reports `status: "timeout"`.
- The parent sees a card per subagent: name, task, progress, files, elapsed,
  log preview, stop. Subagent output never floods the main transcript.
- The main agent may cancel, retry or reassign a subagent.

## 10. Settings (exact order)

**Account:** Account · Plan & billing · Usage · Credentials.

**Chat:** Appearance · Memory · Shared memory · Memory files · Show reasoning.

**Models (card before Data control):** Connectors (`+`) · Agent presets ·
Response wait limit.

**Data control:** Export or import · Permissions · Crash reports · Storage ·
Delete data · Reset memory.

**Advanced:** Notifications · Account health · About.

- Appearance: System (default) / Light / Dark, accent, text size, reduce motion,
  high contrast, live preview.
- Export/import caps: 64 MB, 1,000 sessions, 20,000 messages; a pre-flight check
  explains what will be dropped.
- Crash reports: opt-out, anonymous, no transcripts.
- Delete data and Reset memory are destructive, confirmed with the consequence
  spelled out.
- Account health: system status, last security check, devices, revoke.

## 11. Plans and billing

| Plan | USD | INR | Storage | Models |
|---|---|---|---|---|
| Free | $0 | — | 3 GB | Auto only |
| Ovid Go | $5 | ₹499 | 5 GB | Auto only |
| Ovid Plus | $18 | ₹1,799 | 15 GB | Auto + manual |
| Ovid Pro | $99 | ₹9,999 | 75 GB | Auto + manual |

- Free: **50,000,000 tokens per 24 h**, hard ceiling **1,500,000,000 per 30
  days**, per user, no pool. Auto only.
- Go: auto only, 1.5× auto allowance.
- Plus: manual + 5× auto. Pro: manual + 20× auto.
- Manual models are **greyed out** on Free and Go with "Plus plan" and an
  upgrade CTA; the server also rejects them.
- RevenueCat is the entitlement source; Google Play Billing is the purchase
  path. Restore purchases is always visible.
- At a limit: "Daily limit reached · Resets in 6h 12m" + See plans. Never a raw
  429.
- Custom connectors: Free 0, Go 5, Plus 20, Pro 20.

## 12. Security and trust

- Cloudflare at the edge, R2 for objects, FCM for push.
- The user never sees their provider key or the LiteLLM base URL.
- Session isolation, Postgres RLS, per-uid/per-IP rate limits, revocation
  checks on every request.
- IP hopping across accounts triggers a block and an email; two dashboards
  (LiteLLM + admin) can block/unblock and inspect usage.
- Sandbox: bwrap + uid + cgroups, seccomp, egress allowlist, no tunnels.
- TLS pinning when configured; App Check on.
- App lock (biometric) is available in Settings → Account; default off.
- Logs never contain tokens, prompts or file contents.

## 13. Collaboration

- Max **50 members** per shared session (DB constraint raised from 10).
- **One message at a time**: while any turn is in flight every other send is
  disabled with "Wait for the turn"; drafts are never dropped.
- The creator pays storage; members see the creator's plan and storage.
- Read-only links can be forked into the recipient's account.
- Roles: Owner, Can chat, View only.
- Members can leave; the owner can remove; the owner cannot leave without
  transferring ownership.

## 14. Library, schedules, runs

- **Artifacts**: images, documents, code, data; grid, filters, search, download,
  share, open in Studio. Missing files show a recoverable error.
- **Schedules**: once/daily/weekly/custom, timezone-aware, notify on finish,
  run history, retry failed runs, pause/resume. Human-readable rule and next run.
- **Run trajectory**: step timeline with sources, files, previews, durations,
  model, tokens; expandable detail; raw JSON only behind "Show raw".
- **Subagent monitor**: per-subagent card and detail as in §9.

## 15. Notifications, deep links, offline

- FCM for run finished, schedule result, share/collab invites, security alerts.
- Notification taps deep-link to the exact chat/run/schedule; if signed out,
  they queue until the account is ready.
- Offline: messages are queued with "Messages will send when you reconnect";
  cached transcripts remain readable; a retry is always available.
- The app never blocks on the network for navigation.

## 16. Motion system

- Tokens: 90/140/200/260/360 ms; standard `Cubic(0.2,0.8,0.2,1)`; spring
  `Cubic(0.34,1.56,0.64,1)`.
- Page push: fade + 3.5 % lift; sheet: fade + 8 % rise.
- Lists: stagger 32 ms, capped at 400 ms.
- Press: scale 0.97 for 90 ms.
- Running indicator: 1.2 s pulse; skeleton 1.1 s shimmer.
- Reduced motion disables all of the above, never blocks content.
- No animation may delay input or exceed 400 ms on entrance.

## 17. Telemetry and quality

- Anonymous crash reports (opt-out), performance traces for cold start, first
  token and frame build; no prompt or file contents.
- Client error budget: crash-free sessions ≥ 99.5 %, ANR ≤ 0.5 %.
- Every screen has loading, empty, error, offline and permission-denied states.
- Accessibility: TalkBack pass, 200 % text, reduced motion, high contrast.

## 18. Out of scope for v2

Web, macOS, Windows, Linux clients; on-device inference; plugin marketplace
payments; voice output (TTS); video generation.

## 19. Acceptance

A release candidate is accepted when:

1. All 45 v2 screens render in light and dark with no overflow at 320 dp width
   and 200 % text.
2. Every destructive action names its consequence and is confirmed.
3. Free and Go cannot select a manual model, client or server.
4. A second session cannot read the first session's files or memory.
5. Studio cannot send before a folder is bound; a moved remote always surfaces
   Sync latest changes first.
6. A 50-member collab session allows exactly one sender at a time.
7. Reduced motion removes entrance animation without hiding content.
8. `flutter analyze` is clean and the full test suite is green.
