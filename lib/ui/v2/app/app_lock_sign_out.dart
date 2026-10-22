/// Web-safe fallback for the sign-out that completes an app-lock re-auth.
///
/// Signing out needs `FirebaseService`, which reaches `core/state.dart` and
/// therefore `sqlite3` → `dart:ffi`. That cannot compile for web, so the page
/// imports this file and [app_lock_sign_out_io.dart] conditionally.
library;

/// Signs the account out. On web there is no account session to end.
Future<void> defaultSignOut() async {
  throw UnsupportedError('Signing out is only available in the app.');
}
