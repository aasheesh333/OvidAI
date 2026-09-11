# Browser Desktop Compatibility Design

**Date:** 2026-09-10
**Status:** Approved by product direction (desktop sites must work at a readable scale; per-tab mode; engineering-best defaults).

## 1. Goal

Fix desktop browsing so pages render at a readable size while desktop-only websites still work. Today desktop mode combines a desktop User-Agent with an aggressive CSS `zoom = deviceWidth/1280` (~0.28 on a phone), producing tiny content, and the native viewport flags are global across tabs.

## 2. User Outcomes

1. Desktop mode sends a desktop UA and gets desktop layouts, but text is readable — no ~28% auto-shrink.
2. Visual zoom is a separate, user-controlled value; "fit whole desktop page" is not the definition of desktop mode.
3. Each browser tab keeps its own desktop/mobile setting; toggling one tab does not change another.
4. Per-tab desktop mode and user zoom survive app restart.

## 3. Non-Goals

- A full browser engine change.
- Copying any third-party assets.
- Desktop-mode UI redesign beyond the zoom/mode controls.

## 4. Current Failure Model (evidence)

- `setTabDesktopMode` sets `tab.zoom = (devW/1280)` (`agent_service.dart:1513-1531`); `_applyTabZoom` injects `document.documentElement.style.zoom` (`:1479-1491`), re-applied on every `onPageFinished` (`:1585-1588`).
- Initial controller creation also sets `zoom = devW/1280` and desktop UA before load (`:1723-1744`).
- Native `setDesktopViewport` stores a companion static and traverses every WebView (`OvidWebViewHandler.kt:39-63`), and `applyDesktopViewport(bool)` has no tab argument (`agent_service.dart:1462-1477`).
- `_persistBrowserTabs` persists only URL list + active index (`:1242-1261`); per-tab `desktopMode`/`zoom` are lost on restart.

## 5. Architecture

### 5.1 Readable scale, separate visual zoom
- Desktop mode applies the desktop UA and `useWideViewPort(true)` for layout/breakpoints, but does NOT enable `loadWithOverviewMode(true)` (the auto-fit mechanism) and does NOT set root CSS zoom from `devW/1280`.
- Add `BrowserTab.userZoom` (default 1.0). The injected CSS scale = `userZoom` only (not viewport-derived). A user who wants a wider desktop canvas can zoom out explicitly.
- `browser_resize` sets a logical viewport width for media queries via the native viewport API (per tab), not by shrinking the visual scale.

### 5.2 Per-tab native settings
- `applyDesktopViewport` takes a tab/controller identity and applies settings to that WebView only; remove the global companion static and decor-view traversal.
- Because WebView viewport flags take effect at init, a mode change recreates the controller (existing pattern) for that tab only.

### 5.3 Persistence
- Persist per-tab `desktopMode` and `userZoom` alongside URLs/active index; restore on startup (falling back to the global default when absent).

### 5.4 UI
- Keep the desktop/mobile toggle per tab; add a separate user-zoom control (fit/percentage) independent of the mode.

## 6. Error Handling

- Unknown/missing persisted zoom clamps to a safe range.
- Controller recreation failure surfaces the existing error path; the tab remains usable in the other mode.
- No native WebView (desktop platform) falls back to Dart-only behavior.

## 7. Testing

- Unit: `userZoom` clamp; injected scale equals `userZoom` (not `devW/1280`); per-tab mode independence; persistence round-trip.
- Widget/source: desktop toggle affects only the target tab; zoom control changes scale; restore preserves per-tab mode/zoom.
- Regression: existing desktop-mode tests updated deliberately.

## 8. Decisions

- Desktop compatibility = desktop UA + wide viewport; readable scale by default; no automatic tiny fit.
- Visual zoom is separate and user-controlled.
- Per-tab native settings; per-tab mode/zoom persisted.
