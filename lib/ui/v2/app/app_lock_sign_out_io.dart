/// Native half of the app-lock sign-out fallback. Only compiled when
/// `dart:library.io` exists.
library;

import '../../../core/firebase_service.dart';

/// Ends the account session so the person can sign in again and prove it is
/// them.
Future<void> defaultSignOut() => FirebaseService.I.signOut();
