# 06 — Studio (code workspace)

## Scope
`lib/ui/studio_screen.dart`, `studio_editor.dart`, `studio_file_tree.dart`,
`studio_terminal_tabs.dart`, `studio_layout.dart`, `studio_errors.dart`,
`sandbox_setup.dart` (SandboxSetupScreen, `openStudio`), `github_login_sheet.dart`.
Related core followed for confirmation: `lib/core/sandbox_service.dart`,
`lib/core/github_service.dart`, `lib/core/pty_service.dart`,
`lib/core/studio_terminal.dart`, `lib/core/studio_setup_coordinator.dart`.

## Goal
Read every Studio screen, sheet and dialog in full and produce a ranked, actionable
fix list (see README). Focus: sync IO on UI isolate, unsaved-changes loss,
large-file handling, terminal lifecycle, credential handling, mobile ergonomics.

## Status
in progress

