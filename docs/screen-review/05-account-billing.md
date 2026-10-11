# 05 — Login, account, model providers, billing, usage

## Scope
`lib/ui/login_gate.dart`, `lib/ui/auth_methods.dart`, `lib/ui/auth_screen.dart`,
`lib/ui/account_deletion_panel.dart`, `lib/ui/billing_screen.dart`,
`lib/ui/usage_screen.dart`, `lib/ui/cloud_usage_status.dart`,
`lib/ui/image_receipt_panel.dart`, `lib/ui/providers_screen.dart`,
`lib/ui/profile_avatar.dart`; core follow-through into
`lib/core/ovid_cloud_service.dart`, `lib/core/account_service.dart`,
`lib/core/firebase_service.dart` (and `lib/core/state.dart` where the flow lands).
Reviewed at HEAD `2ac8936`, cross-checked against `fix/model-catalog-recovery` (`8921228`).

## Goal
Full read of every screen/sheet/dialog in the group; verify the
login → token mint → model catalog → model selection path end to end (P0
"Ovid Cloud Auto and manual models not loading"), and verify Google Play
in-app account deletion works in release builds.

## Status
in progress

