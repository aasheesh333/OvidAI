# Browser Desktop Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Desktop browsing renders readable content (no ~28% auto-shrink), visual zoom is separate and user-controlled, each tab keeps its own mode, and per-tab mode/zoom persist.

**Architecture:** Decouple desktop UA/layout from visual scale; add `BrowserTab.userZoom`; apply native viewport settings per tab; persist per-tab mode/zoom.

**Spec:** `docs/superpowers/specs/2026-09-10-browser-desktop-design.md`

## Global Constraints

- Desktop mode = desktop UA + `useWideViewPort(true)`, NO `loadWithOverviewMode(true)` auto-fit and NO `devW/1280` root CSS zoom.
- Visual scale = `userZoom` only; separate user control.
- Per-tab native settings; toggling one tab never changes another.
- Per-tab `desktopMode` + `userZoom` persist across restart.
- Preserve all green tests (full `flutter test` 955/955 at baseline `99f2dda`).
- Flutter binary `/home/ubuntu/sdk/flutter/bin/flutter`.

---

### Task 1: Readable scale and separate user zoom

**Files:**
- Modify: `lib/core/agent_service.dart`
- Create: `test/browser_desktop_scale_test.dart`

**Interfaces:**
- `BrowserTab.userZoom` (default 1.0, clamped e.g. 0.5-2.0); injected CSS scale = `userZoom`; desktop mode no longer sets zoom from `devW/1280`.

- [ ] **Step 1: Write failing tests** — desktop mode does not derive zoom from device width; injected scale equals `userZoom`; `userZoom` clamps.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement** — add `userZoom`; change `setTabDesktopMode` and controller init to use `userZoom`; remove `devW/1280` scale injection.
- [ ] **Step 4: Run GREEN + existing desktop tests, analyze.**
- [ ] **Step 5: Commit** `feat: readable browser desktop scale`

---

### Task 2: Per-tab native viewport settings

**Files:**
- Modify: `lib/core/agent_service.dart`
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt`
- Create: `test/browser_desktop_per_tab_test.dart`

**Interfaces:**
- `applyDesktopViewport` targets a specific tab/WebView; remove the global companion static and decor-view traversal; toggling one tab leaves others unchanged.

- [ ] **Step 1: Write failing tests** — toggling tab A does not change tab B's mode/settings.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement per-tab settings** (controller recreation per tab; drop traversal).
- [ ] **Step 4: Run GREEN + desktop tests, analyze.**
- [ ] **Step 5: Commit** `feat: per-tab browser viewport settings`

---

### Task 3: Persist per-tab mode and zoom

**Files:**
- Modify: `lib/core/agent_service.dart`
- Modify: `test/core_regression_test.dart` (desktop persistence)
- Create: `test/browser_desktop_persistence_test.dart`

**Interfaces:**
- `_persistBrowserTabs` includes `desktopMode` + `userZoom`; restore applies them (fallback to global default).

- [ ] **Step 1: Write failing tests** — round-trip per-tab mode/zoom; restore applies; missing values fall back.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement persistence.**
- [ ] **Step 4: Run GREEN + desktop tests, analyze.**
- [ ] **Step 5: Commit** `feat: persist per-tab browser mode and zoom`

---

### Task 4: Verification, audit, README

**Files:**
- Create: `test/browser_desktop_parity_test.dart`
- Create: `docs/superpowers/audits/2026-09-10-browser-desktop.md`
- Modify: `README.md`

- [ ] **Step 1: Add end-to-end test** (readable scale, per-tab independence, persistence).
- [ ] **Step 2: Run full verification** (`flutter test`, analyze, `build apk --debug`, `git diff --check`).
- [ ] **Step 3: Write audit + README; mark device checks NOT EXECUTED.**
- [ ] **Step 4: Commit** `docs: verify browser desktop compatibility`

---

## Execution Order

```text
1 scale -> 2 per-tab native -> 3 persistence -> 4 verification
```
