# Ovid Si — production-grade remediation plan (2026-10-19)

Source of truth for findings: the files in this folder.
`00-emulator.md` comes from the emulator walkthrough (CI release APK `fdf2c5f`, API 34, production backend).
`01`–`06` come from code audits of client and server.
About 200 findings in all: ~30 P0, ~100 P1, the rest P2.

Product target: the owner's Ovid Si spec. It is a cloud thin client with orchestrator chat, background subagents, Studio, a Cloud Browser, a Scheduler and an Artifact Vault.
The rules below apply to every wave:

- **R1 Session isolation.** Context never crosses sessions unless the user @-tags a session by name, or turns on "Share session memory".
- **R2 Shared per user.** Studio workspace and cloud browser are one per user, shared across that user's sessions.
- **R3 Screencast only while viewing.** Opening the Browser screen attaches to the agent's live browser and streams at 3–5 fps. Closing it stops the screencast, and the browser stays headless.
- **R4 Truthful UI.** Every control either works end to end against the cloud, or is hidden. No "coming soon", no developer copy, no silent failures.
- **R5 Test before fix.** Reproduce user-visible failures on the emulator and prove fixes there. Use deterministic local regression tests for server races. Owner decision: App Check is not required for the current sideload release; Firebase sign-in stays mandatory. While the emulator is closed for capacity work, mark runtime checks pending rather than claiming unit tests establish end-to-end acceptance.

## Wave 0 — make the app testable end to end (blocker for everything)
| Item | Findings |
|---|---|
| App Check off by default in the current sideload client (`OVID_APPCHECK=false`); gateway mode `optional`, Python consumers `APPCHECK_ENABLED=false`. Firebase ID-token verification remains required. Enabling Play Integrity later is a separate release decision, not an emulator-testing prerequisite. | SH-001, EM-012 |
| App Check / mint failures become a typed error with a visible banner and retry. No unhandled exceptions. | EM-011, CT-011, CH-012, SH-009 |
| Release build: targetSdk to current; archive Dart symbols and the R8 mapping. | EM-001, CT-017, CT-021 |

## Wave 1 — core chat flow works and is honest
| Item | Findings |
|---|---|
| Fresh account: chat home auto-creates a session, so the first message sends | EM-010 |
| Model / mode / plan / preset reach the server (shared send schema + worker honours them); Read-Only really asks | CT-001, CH-001, CH-007, CH-008, CH-025 |
| Event projection renders tool, artifact, todo, subagent, compaction and plan events; turn separation | CT-002, CH-004, CH-005, CH-018 |
| Replay cursor and history: resume mid-run, no replay pile-up on first open, rich history | CH-002, CH-003, CH-006, CH-015, CH-021, CT-003 |
| Data loss: outbox, attachments in a new chat, idempotent clientMsgId, queue persistence | CH-009, CH-033, CH-010, CH-011, CH-023 |
| Server-side edit/delete/regenerate (or hide the actions on cloud chats) | CT-004, CH-024 — **GATED safely; not released** |
| Titles sync, unsubscribe on leave, run_merged, approval card fidelity, error copy | CH-013, CH-014, CH-016, CH-017, CH-019, CH-020, CH-031, CH-044 |
| Session isolation (R1): memory toggles enforced server-side; @session tag pulls context only on request | SE-005, R1 |
| Offline: probe Ovid not gstatic; one consistent offline model | SH-011, CH-035 |

## Wave 2 — Studio (R2)
In order: restore navigation, bind to the server session, empty tree for a new workspace, inline errors, remove the GitHub prompt, refresh from the server and on agent edits, save precondition (`ifMatchSha256`), rename/delete/new folder, hydrate on cold workspace, copy, and a navigation test.
The read-only agent execution log replaces any terminal; there is no user PTY.
Findings: ST-001…ST-021, CT-008, CH-026, CH-027, CT-019, EM-007, EM-008.

## Wave 3 — Account, privacy, billing
| Item | Findings |
|---|---|
| Sign-out / switch / reset: unregister FCM, reset the route stack, re-auth the WS, clear billing state, sign out of Firebase | SH-003, SE-002, CT-006, SH-007, SH-008, SH-013, SE-001, SH-018 |
| Billing: route `/billing/verify` at the edge, plan table from the server, purchase flow end to end, deletion handles subscriptions | SH-002, CT-005, SH-005, SH-006, SH-012, SH-014, SH-021, SH-035, EM-015 |
| Login latent 400; first-run prompt sequencing; import sheet only when there are chats | SH-004, SH-010, SE-015, SH-031, EM-003…EM-006 |
| Detailed usage screen (per run / model / day, tokens and cost, resets) from server data | SH-016, SE-020, owner ask |
| Deep links and notification taps | SH-019, SH-020, CT-009, FE-011 |

## Wave 4 — Settings truthfulness
Wire or remove each setting: memory, presets, BYOK attach to runs, wait limit, context window, notifications.
Also: Health screen scaffold plus real worker/model health, reset copy that covers cloud data, Permissions/Memory placeholders, export/restore through the import endpoint, inline workspace images, and tree reorganisation.
Findings: SE-001…SE-033, EM-014, EM-016…EM-018.

## Wave 5 — Browser, Schedules, Artifacts, Sharing (R2, R3)
| Item | Findings |
|---|---|
| Browser: attach to the live per-user browser, 3–5 fps, stop the screencast on close, keyboard, scroll direction, takeover states | FE-008, FE-009, FE-010, FE-020, FE-026, EM-019, R3 |
| Schedules: create, run-now, history, all schedules, failed-state recovery, live updates, time zone | FE-012, FE-013, FE-017…FE-019, CT-014, EM-020 |
| Artifact Vault: server list (created vs uploaded), preview, download, re-mint with the server id | FE-004, FE-005, FE-022, CH-041, CT-015 |
| Sharing: continue-in-Ovid imports server-side, full history, single share store | FE-003, FE-014, FE-016, FE-024, CT-016 |
| Content reports routed and working (Play policy) | FE-001, CT-007 |
| Search over cloud chats | FE-015 |

## Wave 6 — Subagents, image generation, MCP/plugins, collab
These follow the spec. Until each one works end to end it stays hidden (R4).
Covers live subagent activity cards and the Jobs list (FE-007, CH-028), image tools in the worker (FE-006, CH-034), MCP/plugins with free/paid gating (SE-016, CT-013), and collab (FE-002, FE-025).

## Wave 7 — Polish, leftovers, accessibility, performance
All remaining P2s: on-device leftovers and dead code (CT-018, CT-020, SH-029, FE-023, ST-018, CH-047), copy and branding ("Ovid Si" everywhere), accessibility, large text, and chat_screen rebuild cost (CH-036).

## Wave 8 — Release verification
- A scripted emulator pass over every screen, using the QA build against production.
- Full Dart and TypeScript test suites, plus CI green.
- The signed release APK/AAB installed and smoke-tested.
- An evidence report in this folder.

## Process
- Each wave lands as reviewed commits on `feat/ovid-cloud`, with tests, and is verified on the emulator before the next wave starts.
- Server changes deploy to production only after their tests pass. Edge (Caddy) changes are backed up first.
- `chat_screen.dart` is a hotspot, so only one worker edits it at a time.
