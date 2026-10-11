# 07 — Shell, navigation and tool screens

**Scope:** `lib/main.dart` (app root, deep links), `lib/ui/shell.dart` (OvidShell, consent dialog),
`lib/ui/sidebar.dart` (SessionsSidebar: list, search, chat actions, delete confirm),
`lib/ui/startup_progress_panel.dart`, `lib/ui/browser_screen.dart` (tabs / WebViews),
`lib/ui/schedule_screen.dart` (+ edit sheet), `lib/ui/trajectory_screen.dart`, `lib/ui/subagent_screen.dart`.
Supporting `lib/core/` code was followed where a finding depends on it.

**Goal:** see `README.md` — production-readiness fix plan for ~10M DAU Android; navigation architecture
(no router, back handling, deep links, state restoration), tablet/foldable layouts, chat list scale,
search, offline indicator, WebView memory, timers.

**Status:** in progress

Known context: the per-token streaming rebuild storm is being fixed on `perf/streaming-rebuilds`;
referenced, not re-derived, here.

---
