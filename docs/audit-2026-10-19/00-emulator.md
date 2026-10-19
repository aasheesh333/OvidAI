# Emulator walkthrough findings (CI release APK fdf2c5f, emulator API 34, production backend)

| ID | Sev | Screen | Finding | Evidence |
|---|---|---|---|---|
| EM-001 | P0 | Build | targetSdk=28 in release APK; Play requires current target (35). Old target only existed for removed Termux exec. | dumpsys package |
| EM-002 | P2 | Login | Copy "Sign in with a configured social provider" is developer wording | shots/01-launch.png |
| EM-003 | P1 | First run | "Import your chats" sheet shown on fresh install with 0 chats / 0 messages | shots/10.png |
| EM-004 | P1 | First run | Import sheet copy "there is no server endpoint for them yet" — developer copy shipped to users | shots/10.png |
| EM-005 | P1 | First run | Dialog stacking: import sheet opens over "Help improve Ovid AI?" consent dialog over another red card; multiple first-run prompts at once | shots/10.png |
| EM-006 | P2 | Branding | "Ovid AI" in consent dialog vs "Ovid Si" brand elsewhere | shots/10.png |
| EM-007 | P0 | Studio | Studio button is a stub: chat_screen.dart:1594 onPressed only shows SnackBar 'Studio moves to the cloud in this build.' (snackbar not even visible). StudioScreen never instantiated anywhere. | shots/13-studio, 14-studio |
| EM-008 | P2 | Chat header | Studio tooltip "Studio — code & terminal" — terminal removed | ui dump |
| EM-009 | P2 | Chat empty | "the agent runs tools right here" — misleading, tools run in cloud | shots/12.png |
| EM-010 | P0 | Chat | Fresh account lands on chat home with a composer but no session; Send is disabled with no explanation until user finds "New session" in the sidebar | shots/16-chat, 18-newsession |
| EM-011 | P0 | Chat/All cloud | Send fails silently: App Check getToken throws AppCheckUnavailable → "Unhandled Exception" in logcat; UI shows nothing, draft stays, no error | logcat 06:17:39, shots/23 |
| EM-012 | P0 | Cloud auth | Gateway enforces App Check on every request (auth.ts:91); release build uses Play Integrity only → emulator (and likely sideloaded GitHub APKs on real phones, suspected) can never reach the cloud. No debug-provider path for internal testing. | logcat "ticket mint failed: App Check could not verify this app" |
| EM-013 | P2 | Sidebar | "Trajectory — event ledger" developer jargon in primary nav | shots/17-sidebar |
| EM-014 | P1 | Health | No Scaffold/Material: black background, yellow-underlined debug text, no app bar/back | shots/32-health |
| EM-015 | P1 | Billing | Plan "UNKNOWN / Plan unavailable", raw "(401)" shown; paid plans all "Coming soon" — no way to upgrade | shots/33-billing |
| EM-016 | P1 | Notifications | Settings says notifications "blocked by Android"; app never requested POST_NOTIFICATIONS on first run | shots/31-settings-2 |
| EM-017 | P2 | Settings | "Usage: Per-client spend · OvidAI, OpenCode, [CC], Z Code" placeholder copy; "Device health" titled "Ovid Cloud service status"; About says "Ovid AI"; Providers vs Bring-your-own-keys duplicates | shots/30-31 |
| EM-018 | P2 | Settings | Device integrity says "OK — no root…debugger detected" on an emulator | shots/31-settings-2 |
| EM-019 | P1 | Browser | "Agent is driving — Take over" shown while "No page loaded" | shots/34-browser |
| EM-020 | P1 | Schedule | Green "Cloud scheduling active" banner above "Could not load schedules"; no create action; title "Schedule · New chat" | shots/35-schedule |
