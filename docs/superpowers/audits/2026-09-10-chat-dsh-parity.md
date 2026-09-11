# Chat Shell, DSH Parity, and Large-History Reliability — Task 8 Release Gate Audit

Date: 2026-09-11 · Branch `hoplite/gortyn-77773150` · Baseline `fab2987` · Task 8 verification commit (this commit)

This audit is the release gate for the Chat Shell / DSH Parity / Large-History
Reliability project (spec
`docs/superpowers/specs/2026-09-10-chat-dsh-parity-design.md`). It records the
automated verification matrix, the layout axis, the compact disclosure
geometry, the large-history budgets, the persistence coalescing contract, the
composer mode/Plan-preset behavior, the structural (non-copied) DSH parity
notes, and the device-only checklist with its execution status.

**Device checks were NOT executed.** No Android device or emulator is attached
to this environment. Every on-device row in §8 is marked `NOT EXECUTED`, not
`passed`. Nothing on-device was run and nothing on-device is claimed.

This is a test/docs-only task. No production behavior was changed. The one new
test surfaced no defect, so no RED-first fix was required.

## 1. Verification matrix (exact counts)

All commands run with `/home/ubuntu/sdk/flutter/bin/flutter` on 2026-09-11,
working tree at baseline `fab2987` plus the Task 8 test/docs changes.

| Command | Result |
|---|---|
| `flutter test test/chat_layout_test.dart` | 5/5 passed |
| `flutter test test/chat_layout_widget_test.dart` | 2/2 passed |
| `flutter test test/chat_disclosure_widget_test.dart` | 5/5 passed |
| `flutter test test/chat_large_history_test.dart` | 11/11 passed |
| `flutter test test/transcript_model_test.dart` | 14/14 passed |
| `flutter test test/session_persistence_test.dart` | 16/16 passed |
| `flutter test test/composer_modes_test.dart` | 18/18 passed |
| `flutter test test/chat_scroll_anchor_test.dart` | 5/5 passed |
| `flutter test test/chat_dsh_parity_test.dart` | 1/1 passed (new) |
| `flutter test` (all files) | 876/876 passed (875 baseline + 1 new) |
| `flutter analyze --no-pub` | No issues found (ran in 5.6 s) |
| `flutter build apk --debug` | Built `build/app/outputs/flutter-apk/app-debug.apk` (150.1 s) |
| `git diff --check` | clean |

The build emits non-fatal toolchain warnings (Kotlin Gradle Plugin applied by
`firebase_analytics`/`shared_preferences_android`; minimum Android SDK 23 will
soon be dropped). The APK still builds and is produced; these are pre-existing
toolchain warnings, not gate failures. They are recorded here rather than
hidden.

## 2. Layout axis (spec §5.1)

`lib/ui/chat_layout.dart` is a pure model:

- `contentWidth = clamp(pane * 0.64, 680, 920)` then clamped to the pane.
- `composerWidth = clamp(contentWidth + 32, 0, viewportWidth)`.
- `userBubbleMaxWidth = clamp(contentWidth * 0.75, 0, contentWidth)`.
- Zero/negative viewports collapse to `0` (`chat_layout_test.dart` pins this).

Consumers:

- The transcript is wrapped in `Center` + `ConstrainedBox(maxWidth:
  layout.contentWidth)` with key `chat-transcript-column`
  (`lib/ui/chat_screen.dart:1346`).
- The docks (`_GoalBar`, `_TodoDock`, `_StatsLine`, `_QueueDock`,
  `_ApprovalDock`) share the same centered `contentWidth` column
  (`lib/ui/chat_screen.dart:1399`).
- The composer card (`chat-composer-card`) is inset by
  `(viewportWidth - composerWidth) / 2` on both sides, so it is the column plus
  32 px and never exceeds the viewport (`lib/ui/chat_screen.dart:4405`).
- User bubbles are capped at `layout.userBubbleMaxWidth`
  (`lib/ui/chat_screen.dart:3211`).

The new end-to-end test measures the real rects at 1400 px (column 896 px,
centered at 700; composer 928 px) and 400 px (column and composer 400 px,
centered at 200).

**Honest note (deferred Task 2 minors):** the transcript list keeps a
hardcoded `EdgeInsets.fromLTRB(16, 8, 16, 16)` rather than deriving the inset
from `ChatLayout`, and the composer cap is applied via symmetric padding rather
than a `ConstrainedBox`. The visible axis (measured above) is correct; these are
structural tidy-ups, not behavior gaps.

## 3. Compact disclosure geometry (spec §5.2)

- Reasoning (`_ReasoningCard`): a 28 px summary row (leading glyph or streaming
  chase dot, truncating title, rotating chevron) that is collapsed by default;
  the body is rendered only when expanded, at full column width, muted, with a
  single hairline separator and no heavy border
  (`lib/ui/chat_screen.dart:2246`).
- Tool (`_ToolCard`): a 30 px collapsed summary row (state dot / icon,
  truncating title, `·` + truncating summary, rotating chevron, optional
  diff badge and subagent "Open" link). The running glare sweep paints over the
  row via a `Stack` and adds no layout height
  (`lib/ui/chat_screen.dart:2363`).
- Both start collapsed (`_override ?? false` / `_open = false`) and toggle in
  place on tap.

The end-to-end test asserts the summaries exist, both bodies are absent, the
reasoning summary is 28 px tall, and a tap expands the reasoning body. The
dedicated `chat_disclosure_widget_test.dart` (5/5) pins no-border/no-background,
one-line truncation, and expand/collapse for both cards.

## 4. Large-history budgets (spec §5.3, §7)

- `foldMessages` is a pure function (`lib/ui/transcript_model.dart`); the
  production surface uses `windowForBounded`, which folds only a doubling tail
  until the newest `visibleCount` folded items are available, snapping to a
  foldable-run boundary only for a run that would actually fold.
- The chat transcript renders the last `_pageSize = 40` folded items; the
  subagent `ChatTranscript` uses a 200-item page
  (`lib/ui/chat_screen.dart:46`, `:684`).
- The folded window is cached and recomputed only when the session, message
  count, the identity/kind/thinking of the last message, `showReasoning`, or
  the pager window changes (`lib/ui/chat_screen.dart:707`). Streaming tokens
  mutate the live message content in place and repaint only the live tail row
  via its own `AnimatedBuilder`, so they do not re-fold the history.
- The `ListView` is intentionally not memoized by widget identity: a like/
  dislike tap mutates `m.feedback` and must repaint its row (Task 4 review
  Important fix).

Measured by the new end-to-end test on a 5,000-message session whose tail
carries lone reasoning/tool disclosures: `_foldedMessages < 1000` and
`_foldInvocations < 10` (page 40). `chat_large_history_test.dart` additionally
pins `< 1000` folded and `< 10` invocations, the tail slice equality with a
full fold, no splitting of a straddling run, a bounded fold for a 1,000-tool
in-progress run (`< 200` folded), the subagent "Older messages not shown"
affordance, and that 60 streaming tokens add **zero** additional folds.

**Honest note:** the 5,000-message fixture is constructed in memory, so this
gate measures UI fold work, not the cold-start decode of a large *persisted*
session. The persisted-load path is covered separately by
`startup_performance_test.dart` (active session with 5,000 messages, first
frame under the 3 s budget).

## 5. Persistence coalescing (spec §5.4)

`AppState.persistSessions()` (`lib/core/state.dart:2980`) coalesces rapid
writes:

- A trailing debounce; the production window is **200 ms**, enabled from
  `lib/main.dart:12` via `AppState.enableSessionPersistDebounce()`. Tests keep a
  zero-window microtask default so no wall-clock `Timer` is left pending in a
  widget test (`lib/core/state.dart:1256`, `:1851`, `:2994`).
- A per-session content signature covers message count, message content/kind/
  tool/feedback/attachments, title, model, provider, mode, preset,
  workspace folder, repo, parent/agent fields, compaction, `planMode`,
  `planPreMode`, sandbox id, goal, todos, and schedules; only changed sessions
  are re-encoded (`lib/core/state.dart:2950`).
- A write-success guard re-arms a coalesced write only when unpersisted changes
  remain, so the dirty tracker settles instead of writing forever.
- `flushSessionPersistence()` runs a pending write immediately and is called on
  session switch and on lifecycle pause (`lib/ui/shell.dart:80`,
  `lib/core/state.dart:1905`).

`session_persistence_test.dart` (16/16) pins: N rapid calls coalesce to one
encode; unchanged sessions are not re-encoded; message append/edit and in-place
`toolDetail`/`elapsedMs`/`attachments`/`toolSessionId` mutations are detected;
a debounced write does not fire before the window and `await`-separated calls
within the window collapse; a non-active deferred session keeps its original
history and quiesces; the final flush writes the last state; switch and
lifecycle pause flush; and the `ovid_session_bootstrap_v1` tail-50 envelope plus
`sourceFingerprint` are unchanged.

## 6. Composer modes, Plan preset, and folder (spec §5.5)

- `modeOptionsForPicker()` returns `AgentMode.values` minus `safe`
  (`lib/core/agent_service.dart:128`); the mode chip sheet, `/permission` sheet,
  and command help all use it, so Read-Only is never a direct pick.
- `/preset plan` adds the `plan` preset, which sets `planMode = true` and
  applies the read-only (`safe`) tool gate (`lib/core/presets.dart:141`,
  `lib/core/agent_service.dart:2410`). Any other preset clears the coupling.
- Plan mode owns the read-only mode it introduced via `planPreMode`, and every
  exit path releases it: approval of `exit_plan_mode`, `/plan off`, the composer
  Plan chip, and a direct mode pick. The ownership guard is independent of
  `planMode` so the `/plan` → `/preset plan` entry order and legacy
  `planMode=true, mode=safe, planPreMode=null` rows both release correctly
  (`lib/core/agent_service.dart:721`, `:746`, `:2405`).
- The composer workspace chip no longer opens an in-chat folder picker; it opens
  Studio (or shows the pinned folder read-only). Folder change/clear lives only
  in Studio (`lib/ui/chat_screen.dart:5770`, `lib/ui/studio_screen.dart`).
- Read-Only remains reachable internally: existing `safe` sessions keep working
  and `/permission read-only` stays functional but unadvertised.

`composer_modes_test.dart` (18/18) pins the picker exclusion, functional
unadvertised `/permission read-only`, `/preset plan` read-only + mutating-tool
denial, plan release on approval / `/plan off` / Plan chip / direct mode pick,
entry-order and legacy release, an independent read-only session staying
untouched, and Studio folder change/clear. The new end-to-end test asserts the
same `/preset plan` → mutating-tool denial → `exit_plan_mode` approval →
`mode == 'auto'` release, plus the folder chip opening Studio.

## 7. Structural DSH parity (no copied assets)

Parity is structural and behavioral only, per spec §3 and §10. No DSH branding,
icons, product copy, CSS token names, or other assets were copied or imported.
The reimplementation independently mirrors:

- the single centered readable column (`clamp(680, 64%, 920)` semantics) and a
  composer 32 px wider than it;
- compact, default-collapsed reasoning/tool disclosure rows with a rotating
  chevron and a hairline-separated muted body;
- a user bubble at 75% of the column;
- windowed folding plus streaming isolation plus coalesced persistence instead
  of a storage-engine swap.

The `ChatLayout` docstring states the mirror explicitly; no DSH file, asset, or
stylesheet is referenced by the code or tests.

## 8. Device-only checks (spec §8)

Status legend: `PASSED` = executed on a physical Android device/emulator;
`FAILED` = executed and failed; `NOT EXECUTED` = no device/emulator attached.

Environment: `flutter devices` → only the Linux desktop target; `adb devices`
→ no devices attached. Therefore **every row below is `NOT EXECUTED`**.

| # | Check | Status | Evidence / notes |
|---|---|---|---|
| 1 | Column + composer read as one centered axis on a phone (portrait and landscape) | NOT EXECUTED | No device. Automated wide/narrow rect pins in `chat_dsh_parity_test.dart` and `chat_layout_widget_test.dart`. |
| 2 | Reasoning/tool disclosures collapse by default and expand on tap; tap targets usable | NOT EXECUTED | No device. Automated geometry + expand/collapse pins in `chat_disclosure_widget_test.dart`. |
| 3 | Opening a very large real session does not freeze the UI; scroll-up reveals earlier history | NOT EXECUTED | No device. Automated bounded-fold pin in `chat_dsh_parity_test.dart` / `chat_large_history_test.dart`; persisted-load budget in `startup_performance_test.dart`. |
| 4 | Streaming a long response keeps the view anchored and does not re-fold history | NOT EXECUTED | No device. Automated zero-extra-fold streaming pin in `chat_large_history_test.dart`; anchor pins in `chat_scroll_anchor_test.dart`. |
| 5 | `/preset plan` is read-only; approving the plan restores execution | NOT EXECUTED | No device. Automated dispatch/approval pin in `chat_dsh_parity_test.dart` / `composer_modes_test.dart`. |
| 6 | Folder chip opens Studio; folder change/clear works from Studio | NOT EXECUTED | No device. Automated widget pins in `composer_modes_test.dart` / `chat_dsh_parity_test.dart`. |
| 7 | APK installs and launches on-device | NOT EXECUTED | No device; APK built and SHA-pinned in §9. |

## 9. Debug APK artifact

| Field | Value |
|---|---|
| Path | `build/app/outputs/flutter-apk/app-debug.apk` |
| Size (bytes) | 238,041,177 |
| Size (human) | 228 MiB |
| SHA-256 | `782df3ff05c4629080d8c195d3e1882cbd3a5907cdc1927d9a71c3297c98c821` |
| Build command | `flutter build apk --debug` |
| Build time | 150.1 s |
| Built from | baseline `fab2987` working tree + Task 8 test/docs changes |

This is a debug build; it is an artifact-integrity and buildability gate, not a
release-signed artifact. The APK is **workspace-bound and gitignored** (it lives
under `/build/`, which `.gitignore` excludes): a debug build is not
byte-reproducible across machines, and the SHA-256 above pins this specific
workspace artifact only.

## 10. Concerns and limitations

1. **No on-device verification.** Touch behavior, real large-session open
   latency, disclosure tap-target comfort, and Studio navigation remain
   unverified until a release owner runs §8 on a physical device.
2. **In-memory large-history fixture.** The 5,000-message UI test constructs the
   session in memory; cold-start decode of a huge persisted session is covered
   by a separate startup performance suite, not by this gate.
3. **Deferred Task 2 minors.** The transcript list inset is still a hardcoded
   16 px and the composer cap is applied via padding rather than a
   `ConstrainedBox`; the measured axis is correct.
4. **Coalescing timing.** The production 200 ms debounce is opt-in from `main`;
   tests pin its semantics with short explicit windows. No wall-clock production
   debounce timing is asserted.
5. **Debug APK size.** 228 MiB is a debug artifact; not representative of a
   release build.

## 11. Gate decision

Automated gates are green: all focused suites (5 + 2 + 5 + 11 + 14 + 16 + 18 +
5 + 1), the full Flutter suite (876/876), `flutter analyze` (no issues), the
debug APK build, and `git diff --check`. The on-device checklist (§8) is
`NOT EXECUTED` because no Android device/emulator is attached; on-device release
sign-off must therefore remain open until a release owner completes it.
