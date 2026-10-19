# Emulator verification log — production backend (api.ovidsi.com)

Build: CI release APK from `bda7740a` (Waves 0, 1a, 2, 5), emulator API 34, account signed in with Google.
Production: gateway rebuilt with OVID_APPCHECK_MODE=optional, migration 0016 applied, worker restarted (2026-10-19 08:06 UTC); Python mint APPCHECK_ENABLED=false.

| Check | Finding(s) | Result | Evidence |
|---|---|---|---|
| targetSdk | EM-001 | PASS — targetSdk=36 | dumpsys package |
| Notification permission asked | EM-016 | PASS — system prompt "Allow Ovid Si to send you notifications?" on launch | shots/40-launch |
| Empty-state copy | EM-009 | PASS — "Ovid works on it in the cloud." | shots/41 |
| Chat send → reply (no App Check) | EM-010, EM-011, EM-012 | PASS — "hello from ovid" in 4 s | shots/42-reply |
| Draft survives app upgrade | CH-023 | PASS | shots/41 |
| Studio opens | EM-007, ST-001 | PASS | shots/43-studio |
| Studio tree after agent writes a file | ST-002, ST-003, ST-006 | FAIL first (503: UFW blocked gateway → host :8093), PASS after narrow UFW rule (172.19.0.0/16 → 8093); `notes/hello.md` opens with "Hello Studio" | shots/44, 46-50 |
| Studio tooltip | EM-008 | PASS — "Studio — your cloud files" | ui dump |
| Live browser view | R3, FE-010, EM-019 | PASS — agent's Wikipedia page streamed live with title, URL, "Agent is driving · Take control" | shots/54-browser-live |
| Browser after tier-1 research | — | Shows "The agent isn't using the browser right now" (tier-1 Lightpanda has no live view — by design; copy could say so) | shots/53-browser |
| Screencast stops when screen closes | R3 | Covered by unit tests; not observable — no viewer lifecycle logging (add in Wave 7) | — |
| Schedules screen | EM-020, FE-012, FE-018 | PASS — truthful status, filters, New schedule | shots/56 |
| Create schedule | FE-012 | PASS — "Daily quote · every 1 h" active | shots/59 |
| Run now + history | FE-012 | PASS — Running → "Last run: succeeded" | shots/61-62 |
| Cancel schedule | — | PASS; P2 bug: confirm dialog said "The task is running now" after the run had succeeded (stale state) | shots/63-64 |
| Tool cards in chat | CT-002, CH-004 | Not yet — Wave 1b in progress | shots/45-tool |

## Recovery review — checks not covered by the emulator smoke pass

- **ST-007 remains open for concurrent saves.** The integrated file service
  checks a SHA-256 baseline, then renames the new file in a separate filesystem
  operation. A disposable local reproduction against the built storage module
  issued 12 conditional saves using the same baseline; all 12 succeeded in each
  of three rounds and only the last content survived. The replacement Studio
  agent reproduced this for both one session and distinct sessions sharing the
  same user workspace. A fix and regression tests are in progress; no fix is
  merged or verified here yet. Serial mismatch tests do not establish an atomic
  compare-and-swap guarantee, especially against raw agent or other-process writes.
- **Capacity above 1,800 active users is not established.** The capacity recovery
  agent found the inherited runs contained timeouts, HTTP 503s, and excessive CPU;
  fresh isolated measurements are pending. Connected WebSockets alone are not
  evidence of successful concurrent model/tool/browser workloads.
- **The emulator is now closed** at the owner's direction to leave resources for
  capacity work. The working inference proxy is outside this task and untouched.
- This log records the specific smoke checks above, not full product acceptance.
  Artifact inventory, complete cloud sharing/search, image tool wiring, MCP/plugin
  execution/management, collaboration inference, and durable asynchronous
  subagents still need end-to-end verification and completion. Live subagent
  cards alone do not prove durable background orchestration.
