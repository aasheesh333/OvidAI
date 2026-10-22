/// Who the signed-in account is, for billing.
///
/// `core/play_billing.dart` used to import `core/firebase_service.dart` just to
/// read the uid, and that file reaches `core/state.dart` → sqlite3 →
/// `dart:ffi`, which cannot compile for the web gallery. The app sets this
/// provider once at startup; the default answers null, which billing already
/// treats as "no account yet".
library;

String? Function()? ovidBillingUidProvider;

/// The current account id, or null when nobody is signed in.
String? ovidBillingUid() => ovidBillingUidProvider?.call();
