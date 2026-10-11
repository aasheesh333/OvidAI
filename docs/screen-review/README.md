# Ovid Screen-by-Screen Review (temporary working docs)

> **Removable:** this whole folder is planning/review material only. It is not
> referenced by `pubspec.yaml`, not bundled in the app, and not read by any test
> or CI step. Delete it any time with `git rm -r docs/screen-review`.
> It lives on branch `review/screen-audit`. That branch does not trigger the
> Android build workflow (only `main`, `ci/verified-android-build-20260827`
> and `hoplite/**` do), and every commit here is also marked `[skip ci]`.

## Goal
Read every user-facing screen, bottom sheet and dialog in `lib/ui/` **in full**
(not excerpts) at HEAD `2ac8936` (`hoplite/gortyn-77773150`), and produce an
actionable fix plan for a production app targeting ~10M DAU on Android:
- functional bugs and broken or dead flows
- missing loading, empty, error and offline states; raw exception text shown to users
- UI/UX defects: layout overflow, small-screen and tablet behaviour, consistency, copy
- accessibility: Semantics, 48dp tap targets, contrast, text scaling
- performance: rebuild scope, lazy lists, sync IO in build, memory
- security issues visible from the UI layer
- must-have UX features that are missing, compared with the ChatGPT and Claude mobile apps
- Claude Code MCP/plugin parity gaps that surface in the UI, including usage tracking

## Scope (8 review groups, one file each)
| File | Group | Source files |
|---|---|---|
| 01-chat-core.md | Chat screen part 1 | `chat_screen.dart` L1–4500, `transcript_model.dart`, `chat_layout.dart` |
| 02-chat-messages.md | Chat screen part 2 | `chat_screen.dart` L4500–end, `html_artifact_view.dart` |
| 03-plugins-mcp.md | Plugins & MCP | `plugins_screen.dart`, `plugin_*.dart`, `mcp_oauth_sheet.dart` |
| 04-settings.md | Settings | `settings_*.dart`, `health_screen.dart`, `permissions_screen.dart`, `memory_screen.dart` |
| 05-account-billing.md | Login, account, models, billing | `login_gate.dart`, `auth_*.dart`, `account_deletion_panel.dart`, `billing_screen.dart`, `usage_screen.dart`, `cloud_usage_status.dart`, `image_receipt_panel.dart`, `providers_screen.dart`, `profile_avatar.dart` |
| 06-studio.md | Studio / code | `studio_*.dart`, `sandbox_setup.dart`, `github_login_sheet.dart` |
| 07-shell-nav-tools.md | Shell, sidebar, tools | `shell.dart`, `sidebar.dart`, `startup_progress_panel.dart`, `browser_screen.dart`, `schedule_screen.dart`, `trajectory_screen.dart`, `subagent_screen.dart` |
| 08-sharing-sync-design.md | Sharing, sync, design system | `shared_conversation_screen.dart`, `share_actions.dart`, `conversation_share_sheet.dart`, `private_*.dart`, `collaboration_screen.dart`, `widgets/*`, `lib/core/theme.dart` |

## Per-screen entry format
Each group file starts with Scope / Goal / Status, then one section per screen, sheet or dialog:
- **What it is / how reached**
- **Findings** — `P0/P1/P2 · category · file:line · problem · user impact · concrete fix`
- **Missing features**
- **Test to add**

It ends with a group summary: the top fixes, the order to do them in, and rough effort.
